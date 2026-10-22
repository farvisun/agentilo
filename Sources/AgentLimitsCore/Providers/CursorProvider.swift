import Foundation
import SQLite3

public enum CursorCredentials {
    public static var defaultHome: String {
        Paths.home + "/Library/Application Support/Cursor/User/globalStorage"
    }

    public static func databaseURL(home: String) -> URL {
        URL(fileURLWithPath: Paths.expand(home)).appendingPathComponent("state.vscdb")
    }

    public static func exists(home: String) -> Bool {
        FileManager.default.fileExists(atPath: databaseURL(home: home).path)
    }

    /// Reads one value from Cursor's VS Code style key/value store, read-only.
    public static func value(forKey key: String, home: String) -> String? {
        let url = databaseURL(home: home)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        var db: OpaquePointer?
        let uri = "file:\(url.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? url.path)?mode=ro"
        guard sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return nil
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 500)
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT value FROM ItemTable WHERE key = ? LIMIT 1", -1, &stmt, nil) == SQLITE_OK else {
            return nil
        }
        defer { sqlite3_finalize(stmt) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(stmt, 1, key, -1, transient)
        guard sqlite3_step(stmt) == SQLITE_ROW, let c = sqlite3_column_text(stmt, 0) else { return nil }
        return String(cString: c)
    }
}

public struct CursorProvider: UsageProvider {
    static let endpoint = URL(string: "https://cursor.com/api/usage-summary")!

    public init() {}

    public func fetch(account: Account, session: URLSession) async throws -> UsageSnapshot {
        guard let token = CursorCredentials.value(forKey: "cursorAuth/accessToken", home: account.homePath),
              !token.isEmpty else {
            throw UsageError.notSignedIn("Not signed in to Cursor.")
        }
        guard let sub = JWT.payload(token).flatMap({ J.string($0["sub"]) }) else {
            throw UsageError.badResponse("unreadable Cursor token")
        }
        let userID = sub.split(separator: "|").last.map(String.init) ?? sub
        var req = URLRequest(url: Self.endpoint)
        req.setValue("WorkosCursorSessionToken=\(userID)%3A%3A\(token)", forHTTPHeaderField: "Cookie")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("AgentLimits/1.0", forHTTPHeaderField: "User-Agent")

        let json = try await HTTP.getJSON(req, session: session) {
            .tokenExpired("Cursor sign-in expired. Open Cursor to refresh it.")
        }
        var snap = Self.parse(json)
        snap.email = CursorCredentials.value(forKey: "cursorAuth/cachedEmail", home: account.homePath)
        return snap
    }

    /// Amounts are in cents.
    static func parse(_ json: [String: Any], now: Date = Date()) -> UsageSnapshot {
        let start = DateParsing.iso(J.string(json["billingCycleStart"]))
        let end = DateParsing.iso(J.string(json["billingCycleEnd"]))
        let length = (start != nil && end != nil) ? end!.timeIntervalSince(start!) : nil
        let usage = J.dict(json["individualUsage"])
        var windows: [UsageWindow] = []

        if let plan = J.dict(usage?["plan"]), let used = J.double(plan["used"]),
           let limit = J.double(plan["limit"]), limit > 0 {
            windows.append(UsageWindow(
                id: "plan", kind: .billing, title: "Billing cycle",
                usedPercent: used / limit * 100, resetsAt: end, windowLength: length,
                detail: String(format: "$%.2f of $%.2f", used / 100, limit / 100)
            ))
        }
        if let od = J.dict(usage?["onDemand"]), od["enabled"] as? Bool == true {
            let used = J.double(od["used"]) ?? 0
            let limit = J.double(od["limit"])
            let pct = (limit ?? 0) > 0 ? used / limit! * 100 : 0
            let detail = (limit ?? 0) > 0
                ? String(format: "$%.2f of $%.2f", used / 100, limit! / 100)
                : String(format: "$%.2f spent", used / 100)
            windows.append(UsageWindow(
                id: "on_demand", kind: .billing, title: "On-demand",
                usedPercent: pct, resetsAt: end, windowLength: nil, detail: detail
            ))
        }
        let plan = J.string(json["membershipType"])?.capitalized
        return UsageSnapshot(windows: windows, plan: plan, fetchedAt: now)
    }
}
