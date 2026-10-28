import Foundation

/// Gemini CLI quota from the Code Assist API the CLI's `/stats` uses: `loadCodeAssist` for the
/// managed project and tier, then `retrieveUserQuota` for per-model daily buckets.
/// Shapes from google-gemini/gemini-cli `packages/core/src/code_assist/{server,setup,types}.ts`.
public struct GeminiProvider: UsageProvider {
    static let base = "https://cloudcode-pa.googleapis.com/v1internal"
    /// Gemini quotas reset daily.
    static let window: TimeInterval = 86_400

    public init() {}

    public func fetch(account: Account, session: URLSession) async throws -> UsageSnapshot {
        guard let creds = GeminiCredentials.load(home: account.homePath) else {
            throw UsageError.notSignedIn("Not signed in to Gemini CLI. Run `gemini` and sign in with Google.")
        }
        // Agentilo never refreshes Google tokens; the CLI does that whenever it runs.
        if creds.isExpired() { throw UsageError.tokenExpired("Gemini sign-in expired. Run `gemini` to refresh it.") }
        let expired = UsageError.tokenExpired("Gemini sign-in expired. Run `gemini` to refresh it.")

        let load = try await post("loadCodeAssist", [
            "metadata": ["ideType": "IDE_UNSPECIFIED", "platform": "PLATFORM_UNSPECIFIED", "pluginType": "GEMINI"],
        ], token: creds.accessToken, session: session, expired: expired)
        guard let project = J.string(load["cloudaicompanionProject"]) else {
            throw UsageError.notSignedIn("Gemini CLI is not set up for this account yet. Run `gemini` once.")
        }
        let quota = try await post("retrieveUserQuota", ["project": project], token: creds.accessToken, session: session, expired: expired)
        let tier = J.dict(load["paidTier"]) ?? J.dict(load["currentTier"])
        return UsageSnapshot(
            windows: Self.windows(quota),
            plan: J.string(tier?["name"]),
            email: GeminiCredentials.email(home: account.homePath)
        )
    }

    private func post(
        _ method: String, _ body: [String: Any], token: String, session: URLSession, expired: UsageError
    ) async throws -> [String: Any] {
        var req = URLRequest(url: URL(string: "\(Self.base):\(method)")!)
        req.httpMethod = "POST"
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Agentilo/1.0", forHTTPHeaderField: "User-Agent")
        return try await HTTP.getJSON(req, session: session) { expired }
    }

    /// One window per model family (Pro, Flash, ...), the fullest bucket of each.
    static func windows(_ quota: [String: Any]) -> [UsageWindow] {
        var byTitle: [String: UsageWindow] = [:]
        for case let b as [String: Any] in J.array(quota["buckets"]) ?? [] {
            guard let fraction = J.double(b["remainingFraction"]) else { continue }
            let model = J.string(b["modelId"]) ?? "gemini"
            let title = family(model)
            let w = UsageWindow(
                id: "gemini-\(title.lowercased().replacingOccurrences(of: " ", with: "-"))",
                kind: .other, title: title,
                usedPercent: min(100, max(0, (1 - fraction) * 100)),
                resetsAt: DateParsing.iso(J.string(b["resetTime"])), windowLength: window
            )
            if let have = byTitle[title], have.usedPercent >= w.usedPercent { continue }
            byTitle[title] = w
        }
        // Pro first: it runs out first.
        let order = ["Pro", "Flash", "Flash Lite"]
        return byTitle.values.sorted {
            (order.firstIndex(of: $0.title) ?? order.count, $0.title) < (order.firstIndex(of: $1.title) ?? order.count, $1.title)
        }
    }

    /// "gemini-2.5-pro" -> "Pro", "gemini-2.5-flash-lite" -> "Flash Lite".
    static func family(_ model: String) -> String {
        let m = model.lowercased()
        if m.contains("flash-lite") || m.contains("flash_lite") { return "Flash Lite" }
        if m.contains("flash") { return "Flash" }
        if m.contains("pro") { return "Pro" }
        return model
    }
}
