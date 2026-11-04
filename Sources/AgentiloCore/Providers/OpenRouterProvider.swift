import Foundation

/// OpenRouter credit balance and key limit. Unlike the other providers this is a documented API,
/// and the key is one the user pastes into Settings, kept in the Keychain.
public struct OpenRouterProvider: UsageProvider {
    static let keyEndpoint = URL(string: "https://openrouter.ai/api/v1/key")!
    static let creditsEndpoint = URL(string: "https://openrouter.ai/api/v1/credits")!

    public init() {}

    public func fetch(account: Account, session: URLSession) async throws -> UsageSnapshot {
        guard let key = KeychainStore.apiKey(for: account.id), !key.isEmpty else {
            throw UsageError.notSignedIn("Add your OpenRouter key in Settings → Accounts.")
        }
        func request(_ url: URL) -> URLRequest {
            var req = URLRequest(url: url)
            req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            req.setValue("application/json", forHTTPHeaderField: "Accept")
            req.setValue("Agentilo/1.0", forHTTPHeaderField: "User-Agent")
            return req
        }
        let info = try await HTTP.getJSON(request(Self.keyEndpoint), session: session) {
            .tokenExpired("OpenRouter rejected the key. Replace it in Settings → Accounts.")
        }
        var credits: [String: Any]?
        do {
            credits = try await HTTP.getJSON(request(Self.creditsEndpoint), session: session) { .notSignedIn("") }
        } catch UsageError.notSignedIn {
            // Only a management key may read the account's credits.
        }
        let snap = Self.parse(key: info, credits: credits)
        guard !snap.windows.isEmpty else {
            throw UsageError.notSignedIn("This key has no limit. Use a management key to see the credit balance.")
        }
        return snap
    }

    static func parse(key: [String: Any], credits: [String: Any]?, now: Date = Date()) -> UsageSnapshot {
        var windows: [UsageWindow] = []
        if let data = J.dict(credits?["data"]), let total = J.double(data["total_credits"]), total > 0,
           let used = J.double(data["total_usage"]) {
            windows.append(UsageWindow(
                id: "credits", kind: .billing, title: "Credits",
                usedPercent: used / total * 100, resetsAt: nil, windowLength: nil,
                detail: String(format: "$%.2f left", max(0, total - used))
            ))
        }
        let data = J.dict(key["data"])
        if let limit = J.double(data?["limit"]), limit > 0, let left = J.double(data?["limit_remaining"]) {
            let used = max(0, limit - left)
            windows.append(UsageWindow(
                id: "key_limit", kind: .billing, title: "Key limit",
                usedPercent: used / limit * 100, resetsAt: nil, windowLength: nil,
                detail: String(format: "$%.2f of $%.2f", used, limit)
            ))
        }
        let free = data?["is_free_tier"] as? Bool
        return UsageSnapshot(windows: windows, plan: free.map { $0 ? "Free" : "Pay-as-you-go" }, fetchedAt: now)
    }
}
