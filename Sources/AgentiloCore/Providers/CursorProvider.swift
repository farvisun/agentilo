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
        req.setValue("Agentilo/1.0", forHTTPHeaderField: "User-Agent")

        let json = try await HTTP.getJSON(req, session: session) {
            .tokenExpired("Cursor sign-in expired. Open Cursor to refresh it.")
        }
        var snap = Self.parse(json)
        snap.email = CursorCredentials.value(forKey: "cursorAuth/cachedEmail", home: account.homePath)
        return snap
    }

    /// Amounts are in cents. Newer plans also report percentages: the whole plan, and its split
    /// between Cursor's own models (Auto) and other providers' models (API).
    static func parse(_ json: [String: Any], now: Date = Date()) -> UsageSnapshot {
        let start = DateParsing.iso(J.string(json["billingCycleStart"]))
        let end = DateParsing.iso(J.string(json["billingCycleEnd"]))
        let length = (start != nil && end != nil) ? end!.timeIntervalSince(start!) : nil
        let usage = J.dict(json["individualUsage"])
        var windows: [UsageWindow] = []

        let plan = J.dict(usage?["plan"])
        let used = J.double(plan?["used"]), limit = J.double(plan?["limit"])
        let dollars = (used != nil && (limit ?? 0) > 0)
            ? String(format: "$%.2f of $%.2f", used! / 100, limit! / 100) : nil
        if let pct = J.double(plan?["totalPercentUsed"]) ?? ((limit ?? 0) > 0 ? used.map { $0 / limit! * 100 } : nil) {
            windows.append(UsageWindow(
                id: "plan", kind: .billing, title: "Billing cycle",
                usedPercent: pct, resetsAt: end, windowLength: length, detail: dollars
            ))
        }
        for (key, id, title) in [("autoPercentUsed", "auto", "Cursor models"), ("apiPercentUsed", "api", "Other models")] {
            guard let pct = J.double(plan?[key]) else { continue }
            windows.append(UsageWindow(id: id, kind: .billing, title: title, usedPercent: pct,
                                       resetsAt: end, windowLength: length))
        }

        // On-demand spend: the user's own limit, else the team's shared pool.
        let team = J.dict(json["teamUsage"])
        let isTeam = J.string(json["limitType"]) == "team"
        let own = J.dict(usage?["onDemand"])
        let ownLimit = J.double(own?["limit"]) ?? 0
        if own?["enabled"] as? Bool == true, ownLimit > 0 || !isTeam {
            windows.append(spend(own!, id: "on_demand", title: "On-demand", end: end))
        } else if isTeam, let pool = [J.dict(team?["onDemand"]), J.dict(team?["pooled"])]
            .compactMap({ $0 }).first(where: { $0["enabled"] as? Bool != false && J.double($0["limit"]) ?? 0 > 0 }) {
            windows.append(spend(pool, id: "team_spend", title: "Team spend", end: end))
        }
        let planName = J.string(json["membershipType"])?.capitalized
        return UsageSnapshot(windows: windows, plan: planName, fetchedAt: now)
    }

    private static func spend(_ d: [String: Any], id: String, title: String, end: Date?) -> UsageWindow {
        let limit = J.double(d["limit"]) ?? 0
        let used = J.double(d["used"]) ?? (limit - (J.double(d["remaining"]) ?? limit))
        let detail = limit > 0
            ? String(format: "$%.2f of $%.2f", used / 100, limit / 100)
            : String(format: "$%.2f spent", used / 100)
        return UsageWindow(id: id, kind: .billing, title: title, usedPercent: limit > 0 ? used / limit * 100 : 0,
                           resetsAt: end, windowLength: nil, detail: detail)
    }
}
