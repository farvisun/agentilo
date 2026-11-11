import Foundation

/// OpenCode Go caps, read with the API key the OpenCode CLI keeps in its `auth.json`
/// (`opencode auth login`, provider "OpenCode Go"). The key is read on each fetch, never written,
/// and sent only to opencode.ai. The plan name needs a Console sign-in, so it is not shown.
public struct OpenCodeProvider: UsageProvider {
    static let endpoint = URL(string: "https://opencode.ai/zen/go/v1/usage")!
    /// Where the CLI keeps its credentials (`$XDG_DATA_HOME/opencode`).
    public static let defaultHome = "~/.local/share/opencode"
    static let authKey = "opencode-go"
    /// A rolling window with no calls answers "now + 5h" on every request; within this much of a
    /// full period it is a placeholder, not a reset.
    static let placeholderTolerance: TimeInterval = 2

    public init() {}

    public static func key(home: String) -> String? {
        let url = URL(fileURLWithPath: Paths.expand(home)).appendingPathComponent("auth.json")
        guard let entry = J.dict(J.object(file: url)?[authKey]),
              let key = J.string(entry["key"]), !key.isEmpty else { return nil }
        return key
    }

    public func fetch(account: Account, session: URLSession) async throws -> UsageSnapshot {
        guard let key = Self.key(home: account.homePath) else {
            throw UsageError.notSignedIn("No OpenCode Go key. Run `opencode auth login` and pick OpenCode Go.")
        }
        var req = URLRequest(url: Self.endpoint)
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("Agentilo/1.0", forHTTPHeaderField: "User-Agent")
        let json = try await HTTP.getJSON(req, session: session) {
            .tokenExpired("OpenCode refused the key. Create a new one in OpenCode Console and run `opencode auth login`.")
        }
        return try Self.parse(json)
    }

    static func parse(_ json: [String: Any], now: Date = Date()) throws -> UsageSnapshot {
        guard let usage = J.dict(json["usage"]) else { throw UsageError.badResponse("no usage") }
        var windows: [UsageWindow] = []
        let spec: [(String, WindowKind, String, TimeInterval)] = [
            ("rolling", .session, "Session", 5 * 3_600),
            ("weekly", .weekly, "Weekly", 7 * 86_400),
            ("monthly", .billing, "Monthly", 30 * 86_400),
        ]
        for (key, kind, title, length) in spec {
            guard let w = J.dict(usage[key]), let pct = J.double(w["percent"]) else { continue }
            var reset = DateParsing.iso(J.string(w["resetsAt"]))
            if key == "rolling", pct == 0, let r = reset,
               abs(r.timeIntervalSince(now) - length) <= placeholderTolerance {
                reset = nil
            }
            windows.append(UsageWindow(id: key, kind: kind, title: title, usedPercent: min(max(pct, 0), 100),
                                       resetsAt: reset, windowLength: length))
        }
        guard !windows.isEmpty else { throw UsageError.badResponse("no windows") }
        return UsageSnapshot(windows: windows, fetchedAt: now)
    }
}
