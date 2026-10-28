import Foundation

/// Gemini CLI's sign-in: `<home>/oauth_creds.json` and `<home>/google_accounts.json`.
/// Read only; Agentilo never refreshes or rewrites the token.
public struct GeminiCredentials: Sendable {
    public var accessToken: String
    public var expiresAt: Date?

    public static func load(home: String) -> GeminiCredentials? {
        let url = URL(fileURLWithPath: Paths.expand(home)).appendingPathComponent("oauth_creds.json")
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = obj["access_token"] as? String, !token.isEmpty else { return nil }
        // Milliseconds since 1970.
        let expiry = (obj["expiry_date"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) }
        return GeminiCredentials(accessToken: token, expiresAt: expiry)
    }

    public static func exists(home: String) -> Bool {
        FileManager.default.fileExists(atPath: Paths.expand(home) + "/oauth_creds.json")
    }

    /// The signed-in Google account.
    public static func email(home: String) -> String? {
        let url = URL(fileURLWithPath: Paths.expand(home)).appendingPathComponent("google_accounts.json")
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let active = obj["active"] as? String, !active.isEmpty else { return nil }
        return active
    }

    public func isExpired(now: Date = Date()) -> Bool {
        expiresAt.map { $0 <= now.addingTimeInterval(60) } ?? false
    }
}
