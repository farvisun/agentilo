import Foundation

/// GitHub Copilot quotas, read with the GitHub CLI's login. The token is asked for on each fetch,
/// kept in memory for that request and sent only to api.github.com.
public struct CopilotProvider: UsageProvider {
    static let endpoint = URL(string: "https://api.github.com/copilot_internal/user")!

    public init() {}

    public func fetch(account: Account, session: URLSession) async throws -> UsageSnapshot {
        guard let cli = GitHubCLI.executable() else {
            throw UsageError.notSignedIn("Install the GitHub CLI and run `gh auth login`.")
        }
        guard let token = GitHubCLI.token(cli: cli, configDir: account.homePath) else {
            throw UsageError.notSignedIn("Not signed in. Run `gh auth login`.")
        }
        var req = URLRequest(url: Self.endpoint)
        req.setValue("token \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("Agentilo/1.0", forHTTPHeaderField: "User-Agent")

        let json = try await HTTP.getJSON(req, session: session) {
            .tokenExpired("GitHub rejected the sign-in. Run `gh auth login`.")
        }
        return Self.parse(json)
    }

    static func parse(_ json: [String: Any], now: Date = Date()) -> UsageSnapshot {
        let quotas = J.dict(json["quota_snapshots"])
        let reset = DateParsing.iso(J.string(json["quota_reset_date_utc"]))
        var windows: [UsageWindow] = []
        for (key, title) in [("premium_interactions", "Premium requests"), ("chat", "Chat"), ("completions", "Completions")] {
            guard let q = J.dict(quotas?[key]), q["unlimited"] as? Bool != true,
                  let entitlement = J.double(q["entitlement"]), entitlement > 0,
                  let left = J.double(q["percent_remaining"]) else { continue }
            let remaining = J.double(q["remaining"]) ?? entitlement * left / 100
            windows.append(UsageWindow(
                id: key, kind: .billing, title: title,
                usedPercent: max(0, 100 - left), resetsAt: reset, windowLength: reset.flatMap(monthLength),
                detail: "\(Int(max(0, entitlement - remaining))) of \(Int(entitlement))"
            ))
        }
        return UsageSnapshot(
            windows: windows,
            plan: J.string(json["copilot_plan"])?.capitalized,
            email: J.string(json["login"]),
            fetchedAt: now
        )
    }

    /// Quotas reset monthly, so a window is the calendar month before the reset.
    private static func monthLength(endingAt reset: Date) -> TimeInterval? {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        return utc.date(byAdding: .month, value: -1, to: reset).map { reset.timeIntervalSince($0) }
    }
}

enum GitHubCLI {
    /// Apps opened from Finder do not get the shell's PATH.
    static func executable(fileManager fm: FileManager = .default) -> String? {
        ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/usr/bin/gh"].first { fm.isExecutableFile(atPath: $0) }
    }

    static func token(cli: String, configDir: String) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: cli)
        p.arguments = ["auth", "token", "--hostname", "github.com"]
        var env = ProcessInfo.processInfo.environment
        env["GH_CONFIG_DIR"] = Paths.expand(configDir)
        p.environment = env
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        let s = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? nil : s
    }
}
