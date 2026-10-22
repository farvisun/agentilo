import CryptoKit
import Foundation

public enum ClaudeCredentials {
    public static let baseService = "Claude Code-credentials"

    public static var defaultHome: String { Paths.home + "/.claude" }

    /// Claude Code suffixes the Keychain service with the first 8 hex chars of
    /// sha256(CLAUDE_CONFIG_DIR) for any config dir other than the default.
    public static func keychainService(forHome home: String) -> String {
        let path = Paths.expand(home)
        if path == defaultHome { return baseService }
        let digest = SHA256.hash(data: Data(path.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "\(baseService)-\(hex.prefix(8))"
    }

    public struct OAuth: Sendable {
        public var accessToken: String
        public var expiresAt: Date?
        public var subscriptionType: String?
    }

    public static func load(home: String) -> OAuth? {
        let path = Paths.expand(home)
        let fileURL = URL(fileURLWithPath: path).appendingPathComponent(".credentials.json")
        let blob = J.object(file: fileURL)
            ?? ForeignKeychain.genericPassword(service: keychainService(forHome: path)).flatMap(J.object(string:))
        guard let oauth = J.dict(blob?["claudeAiOauth"]),
              let token = J.string(oauth["accessToken"]), !token.isEmpty else { return nil }
        let expires = J.double(oauth["expiresAt"]).map { Date(timeIntervalSince1970: $0 / 1000) }
        return OAuth(accessToken: token, expiresAt: expires, subscriptionType: J.string(oauth["subscriptionType"]))
    }

    /// Account email from the config file Claude Code keeps beside the home.
    public static func email(home: String) -> String? {
        let path = Paths.expand(home)
        let candidates = path == defaultHome
            ? [Paths.home + "/.claude.json", path + "/.claude.json"]
            : [path + "/.claude.json"]
        for c in candidates {
            if let acct = J.dict(J.object(file: URL(fileURLWithPath: c))?["oauthAccount"]),
               let email = J.string(acct["emailAddress"]) { return email }
        }
        return nil
    }
}

public struct ClaudeProvider: UsageProvider {
    static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    public init() {}

    public func fetch(account: Account, session: URLSession) async throws -> UsageSnapshot {
        guard let creds = ClaudeCredentials.load(home: account.homePath) else {
            throw UsageError.notSignedIn("Not signed in. Run `claude` and /login for this home.")
        }
        var req = URLRequest(url: Self.endpoint)
        req.setValue("Bearer \(creds.accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("AgentLimits/1.0", forHTTPHeaderField: "User-Agent")

        let json = try await HTTP.getJSON(req, session: session) {
            .tokenExpired("Sign-in expired. Open Claude Code in this home to refresh it.")
        }
        var snap = Self.parse(json)
        snap.plan = creds.subscriptionType?.capitalized
        snap.email = ClaudeCredentials.email(home: account.homePath)
        return snap
    }

    static func parse(_ json: [String: Any], now: Date = Date()) -> UsageSnapshot {
        var windows: [UsageWindow] = []

        if let limits = J.array(json["limits"]), !limits.isEmpty {
            for case let l as [String: Any] in limits {
                guard let kind = J.string(l["kind"]), let pct = J.double(l["percent"]) else { continue }
                let group = J.string(l["group"]) ?? ""
                let wk: WindowKind = group == "session" ? .session : group == "weekly" ? .weekly : .other
                windows.append(UsageWindow(
                    id: kind,
                    kind: wk,
                    title: title(forKind: kind, group: group, scope: J.dict(l["scope"])),
                    usedPercent: pct,
                    resetsAt: DateParsing.iso(J.string(l["resets_at"])),
                    windowLength: wk == .session ? WindowLength.session : wk == .weekly ? WindowLength.week : nil
                ))
            }
        } else {
            let legacy: [(String, WindowKind, String, TimeInterval)] = [
                ("five_hour", .session, "Session", WindowLength.session),
                ("seven_day", .weekly, "Weekly", WindowLength.week),
                ("seven_day_opus", .weekly, "Weekly · Opus", WindowLength.week),
                ("seven_day_sonnet", .weekly, "Weekly · Sonnet", WindowLength.week),
            ]
            for (key, kind, title, length) in legacy {
                guard let w = J.dict(json[key]), let pct = J.double(w["utilization"]) else { continue }
                windows.append(UsageWindow(
                    id: key, kind: kind, title: title, usedPercent: pct,
                    resetsAt: DateParsing.iso(J.string(w["resets_at"])), windowLength: length
                ))
            }
        }

        if let extra = J.dict(json["extra_usage"]), extra["is_enabled"] as? Bool == true,
           let pct = J.double(extra["utilization"]) {
            var detail: String?
            if let used = J.double(extra["used_credits"]), let limit = J.double(extra["monthly_limit"]) {
                let cur = J.string(extra["currency"]) ?? "USD"
                let places = Int(J.double(extra["decimal_places"]) ?? 2)
                let div = pow(10, Double(places))
                detail = String(format: "%.2f of %.2f %@", used / div, limit / div, cur)
            }
            windows.append(UsageWindow(
                id: "extra_usage", kind: .billing, title: "Extra usage",
                usedPercent: pct, resetsAt: nil, windowLength: nil, detail: detail
            ))
        }
        return UsageSnapshot(windows: windows, fetchedAt: now)
    }

    /// "session" -> "Session", "weekly_all" -> "Weekly", "weekly_opus" -> "Weekly · Opus".
    /// Scoped limits are named after their model or surface ("Weekly · Fable").
    static func title(forKind kind: String, group: String, scope: [String: Any]? = nil) -> String {
        if kind == "session" || group == "session" && kind.hasPrefix("session") { return "Session" }
        let scopeName = ["model", "surface"].lazy
            .compactMap { J.string(J.dict(scope?[$0])?["display_name"]) }
            .first
        if let scopeName, !group.isEmpty { return "\(group.capitalized) · \(scopeName)" }
        var parts = kind.split(separator: "_").map(String.init)
        guard let head = parts.first else { return kind }
        parts.removeFirst()
        parts.removeAll { $0 == "all" }
        let base = head.capitalized
        return parts.isEmpty ? base : "\(base) · \(parts.map(\.capitalized).joined(separator: " "))"
    }
}
