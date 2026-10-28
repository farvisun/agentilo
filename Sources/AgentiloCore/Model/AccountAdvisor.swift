import Foundation

/// Another account of the same provider with room to spare, when the busiest one is running low.
public struct AccountSuggestion: Equatable, Sendable {
    public var from: Account
    public var to: Account
    /// The fullest window of each account, in percent.
    public var fromUsed: Double
    public var toUsed: Double
    /// Shell command that starts the agent on `to`; nil when the agent has no home switch (Cursor).
    public var command: String?

    /// "Work has 88% left".
    public var reason: String { "\(to.label) has \(Int((100 - toUsed).rounded()))% left" }
}

public enum AccountAdvisor {
    /// Suggest a switch once the busiest account's fullest window reaches this.
    public static let trigger: Double = 85
    /// ...and only to an account at least this many points emptier.
    public static let minGap: Double = 30

    /// One suggestion per provider at most, for providers with two or more accounts.
    public static func suggest(accounts: [Account], snapshots: [UUID: UsageSnapshot], now: Date = Date()) -> [AccountSuggestion] {
        let byProvider = Dictionary(grouping: accounts.filter { $0.enabled && $0.trackLimits }, by: \.provider)
        return Provider.allCases.compactMap { provider in
            let rated = (byProvider[provider] ?? []).compactMap { acct in
                snapshots[acct.id].flatMap { rate($0, now: now) }.map { (acct, $0) }
            }
            guard rated.count >= 2,
                  let busiest = rated.max(by: { ($0.1.severity, $0.1.used) < ($1.1.severity, $1.1.used) }),
                  busiest.1.used >= trigger || busiest.1.severity >= Pace.runsOut(now).severity,
                  let best = rated.filter({ $0.0.id != busiest.0.id && $0.1.severity < Pace.runsOut(now).severity })
                      .min(by: { $0.1.used < $1.1.used }),
                  busiest.1.used - best.1.used >= minGap
            else { return nil }
            return AccountSuggestion(
                from: busiest.0, to: best.0, fromUsed: busiest.1.used, toUsed: best.1.used, command: command(for: best.0)
            )
        }
    }

    /// The fullest window and the worst pace across an account's windows.
    private static func rate(_ snap: UsageSnapshot, now: Date) -> (used: Double, severity: Int)? {
        guard !snap.windows.isEmpty else { return nil }
        return (snap.windows.map(\.usedPercent).max() ?? 0, snap.windows.map { $0.pace(now: now).severity }.max() ?? 0)
    }

    /// `claude` for the default home, `CLAUDE_CONFIG_DIR=~/.claude_work claude` for another.
    public static func command(for account: Account) -> String? {
        let home = Paths.expand(account.homePath)
        switch account.provider {
        case .claude:
            return home == Paths.expand("~/.claude") ? "claude" : "CLAUDE_CONFIG_DIR=\(shellPath(home)) claude"
        case .codex:
            return home == Paths.expand("~/.codex") ? "codex" : "CODEX_HOME=\(shellPath(home)) codex"
        case .cursor:
            return nil
        }
    }

    /// `~/x` when it is safe to leave unquoted (the shell expands `~` after `=`), else single-quoted.
    static func shellPath(_ path: String) -> String {
        let safe = path.allSatisfy { $0.isLetter || $0.isNumber || "/._-+@".contains($0) }
        let home = Paths.home
        if safe, path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return safe ? path : "'" + path.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }
}
