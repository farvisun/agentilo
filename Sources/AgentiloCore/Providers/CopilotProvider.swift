import Foundation

/// GitHub Copilot quotas, read with the GitHub CLI's login. The token is asked for on each fetch,
/// kept in memory for that request and sent only to the API of the host it belongs to
/// (api.github.com, or api.<name>.ghe.com for GitHub Enterprise Cloud).
public struct CopilotProvider: UsageProvider {
    static let endpoint = URL(string: "https://api.github.com/copilot_internal/user")!

    static func endpoint(host: String?) -> URL {
        guard let host, host != GitHubHost.dotCom else { return endpoint }
        return URL(string: "https://api.\(host)/copilot_internal/user")!
    }

    public init() {}

    public func fetch(account: Account, session: URLSession) async throws -> UsageSnapshot {
        guard let cli = GitHubCLI.executable() else {
            throw UsageError.notSignedIn("Install the GitHub CLI and run `gh auth login`.")
        }
        let host = account.host ?? GitHubHost.dotCom
        guard GitHubHost.normalize(host) == host else {
            throw UsageError.notSignedIn("Only github.com and GHE.com domains are supported.")
        }
        guard let token = GitHubCLI.token(cli: cli, configDir: account.homePath, hostname: host) else {
            throw UsageError.notSignedIn(host == GitHubHost.dotCom
                ? "Not signed in. Run `gh auth login`."
                : "Not signed in to \(host). Run `gh auth login --hostname \(host)`.")
        }
        var req = URLRequest(url: Self.endpoint(host: host))
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
            ?? DateParsing.day(J.string(json["quota_reset_date"]))
            ?? DateParsing.day(J.string(json["limited_user_reset_date"]))
        // Free plans report remaining counts against monthly totals instead of snapshots.
        let limited = J.dict(json["limited_user_quotas"]), monthly = J.dict(json["monthly_quotas"])
        var windows: [UsageWindow] = []
        for (key, title) in [("premium_interactions", "Premium requests"), ("chat", "Chat"), ("completions", "Completions")] {
            let entitlement: Double, remaining: Double, left: Double
            if let q = J.dict(quotas?[key]) {
                guard q["unlimited"] as? Bool != true, let e = J.double(q["entitlement"]), e > 0 else { continue }
                let r = J.double(q["remaining"])
                guard r != -1 else { continue }
                guard let l = J.double(q["percent_remaining"]) ?? r.map({ $0 / e * 100 }) else { continue }
                (entitlement, left, remaining) = (e, l, r ?? e * l / 100)
            } else if let e = J.double(monthly?[key]), e > 0, let r = J.double(limited?[key]), r >= 0 {
                (entitlement, remaining, left) = (e, r, r / e * 100)
            } else {
                continue
            }
            windows.append(UsageWindow(
                id: key, kind: .billing, title: title,
                usedPercent: max(0, 100 - left), resetsAt: reset, windowLength: reset.flatMap(monthLength),
                detail: "\(Int(max(0, entitlement - remaining))) of \(Int(entitlement))"
            ))
        }
        // Premium requests past the allowance, billed when the plan allows them.
        if let premium = J.dict(quotas?["premium_interactions"]), premium["overage_permitted"] as? Bool == true {
            let n = Int(J.double(premium["overage_count"]) ?? 0)
            windows.append(UsageWindow(id: "overage", kind: .balance, title: "Extra usage", usedPercent: 0,
                                       resetsAt: reset, windowLength: nil,
                                       detail: "\(n) \(n == 1 ? "request" : "requests")"))
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

    static func token(cli: String, configDir: String, hostname: String = GitHubHost.dotCom) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: cli)
        p.arguments = ["auth", "token", "--hostname", hostname]
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

/// Where a Copilot seat lives: github.com, or a GitHub Enterprise Cloud domain on GHE.com.
/// Self-hosted GitHub Enterprise Server has no Copilot quota endpoint and is refused.
public enum GitHubHost {
    public static let dotCom = "github.com"

    /// "" and "github.com" give "github.com"; "octocorp", "octocorp.ghe.com" and
    /// "https://octocorp.ghe.com/settings" give "octocorp.ghe.com"; anything else gives nil.
    public static func normalize(_ input: String) -> String? {
        var s = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let url = URL(string: s), let host = url.host { s = host }
        if s.hasPrefix("api.") { s.removeFirst(4) }
        if s.isEmpty || s == dotCom || s == "www.github.com" { return dotCom }
        if !s.contains(".") { s += ".ghe.com" }
        let name = s.hasSuffix(".ghe.com") ? String(s.dropLast(8)) : ""
        let ok = !name.isEmpty && name.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" }
        return ok ? s : nil
    }
}
