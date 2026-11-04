import Foundation

public enum CodexCredentials {
    public struct Tokens: Sendable {
        public var accessToken: String
        public var accountID: String?
        public var email: String?
    }

    public static func load(home: String) -> Tokens? {
        let url = URL(fileURLWithPath: Paths.expand(home)).appendingPathComponent("auth.json")
        guard let auth = J.object(file: url),
              let tokens = J.dict(auth["tokens"]),
              let access = J.string(tokens["access_token"]), !access.isEmpty else { return nil }
        let email = J.string(tokens["id_token"]).flatMap(JWT.payload).flatMap { J.string($0["email"]) }
        return Tokens(accessToken: access, accountID: J.string(tokens["account_id"]), email: email)
    }

    public static func usesAPIKeyOnly(home: String) -> Bool {
        let url = URL(fileURLWithPath: Paths.expand(home)).appendingPathComponent("auth.json")
        guard let auth = J.object(file: url) else { return false }
        return J.string(auth["OPENAI_API_KEY"]) != nil && J.dict(auth["tokens"]) == nil
    }
}

/// Credit expiries change rarely and take a request of their own, unlike the count in the usage
/// response, so each account asks at most once an hour.
private actor ResetExpiries {
    static let shared = ResetExpiries()
    private var known: [UUID: (fetched: Date, expiry: Date?)] = [:]

    func next(account: UUID, fetch: @Sendable () async -> Date?) async -> Date? {
        if let k = known[account], Date().timeIntervalSince(k.fetched) < 3_600 { return k.expiry }
        let expiry = await fetch()
        known[account] = (Date(), expiry)
        return expiry
    }
}

public struct CodexProvider: UsageProvider {
    /// Read only. Its `/consume` sibling spends a credit and is never called.
    static let resetCreditsEndpoint = URL(string: "https://chatgpt.com/backend-api/wham/rate-limit-reset-credits")!

    static let endpoint = URL(string: "https://chatgpt.com/backend-api/wham/usage")!

    public init() {}

    public func fetch(account: Account, session: URLSession) async throws -> UsageSnapshot {
        guard let tokens = CodexCredentials.load(home: account.homePath) else {
            if CodexCredentials.usesAPIKeyOnly(home: account.homePath) {
                throw UsageError.notSignedIn("API-key login has no plan limits. Sign in with ChatGPT.")
            }
            throw UsageError.notSignedIn("Not signed in. Run `codex login` with CODEX_HOME set to this home.")
        }
        var req = URLRequest(url: Self.endpoint)
        req.setValue("Bearer \(tokens.accessToken)", forHTTPHeaderField: "Authorization")
        if let id = tokens.accountID { req.setValue(id, forHTTPHeaderField: "ChatGPT-Account-Id") }
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("Agentilo/1.0", forHTTPHeaderField: "User-Agent")

        let json = try await HTTP.getJSON(req, session: session) {
            .tokenExpired("Sign-in expired. Run Codex in this home to refresh it.")
        }
        var snap = Self.parse(json)
        if snap.email == nil { snap.email = tokens.email }
        if snap.resetGrants != nil {
            var list = req
            list.url = Self.resetCreditsEndpoint
            let listRequest = list
            snap.resetGrants?.nextExpiry = await ResetExpiries.shared.next(account: account.id) {
                let body = try? await HTTP.getJSON(listRequest, session: session) { .tokenExpired("") }
                return body.flatMap(Self.nextResetExpiry)
            }
        }
        return snap
    }

    static func parse(_ json: [String: Any], now: Date = Date()) -> UsageSnapshot {
        var windows: [UsageWindow] = []
        let rate = J.dict(json["rate_limit"])
        for key in ["primary_window", "secondary_window"] {
            guard let w = J.dict(rate?[key]), let pct = J.double(w["used_percent"]) else { continue }
            let length = J.double(w["limit_window_seconds"])
            var reset = J.double(w["reset_at"]).map { Date(timeIntervalSince1970: $0) }
            if reset == nil, let after = J.double(w["reset_after_seconds"]) { reset = now.addingTimeInterval(after) }
            // The primary window is not always the 5-hour one, so classify by length.
            let isSession = (length ?? 0) > 0 && (length ?? 0) <= 86_400
            windows.append(UsageWindow(
                id: key,
                kind: isSession ? .session : .weekly,
                title: isSession ? "Session" : "Weekly",
                usedPercent: pct,
                resetsAt: reset,
                windowLength: length
            ))
        }
        windows.sort { ($0.windowLength ?? .infinity) < ($1.windowLength ?? .infinity) }
        if windows.isEmpty, rate?["limit_reached"] as? Bool == true {
            windows.append(UsageWindow(id: "limit", kind: .other, title: "Limit", usedPercent: 100, resetsAt: nil, windowLength: nil))
        }
        let plan = J.string(json["plan_type"]).map(planName)
        let resets = J.double(J.dict(json["rate_limit_reset_credits"])?["available_count"]).map { Int($0) } ?? 0
        return UsageSnapshot(
            windows: windows, plan: plan, email: J.string(json["email"]), fetchedAt: now,
            resetGrants: resets > 0 ? ResetGrants(available: resets) : nil
        )
    }

    /// The soonest expiry among credits that can still be used.
    static func nextResetExpiry(_ json: [String: Any]) -> Date? {
        let credits = (json["credits"] as? [[String: Any]]) ?? []
        return credits
            .filter { (J.string($0["status"]) ?? "available") == "available" }
            .compactMap { c -> Date? in
                DateParsing.iso(J.string(c["expires_at"])) ?? J.double(c["expires_at"]).map { Date(timeIntervalSince1970: $0) }
            }
            .min()
    }

    static func planName(_ raw: String) -> String {
        switch raw {
        case "prolite": "Pro Lite"
        default: raw.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }
}
