import AgentLimitsCore
import Foundation

/// `AgentLimits --dump`: fetch every configured account once and print, for debugging
/// data sources and proxy settings without the UI.
enum DumpCommand {
    static func run() async {
        var settings = SettingsStore.load()
        if settings.accounts.isEmpty { settings.accounts = AccountDetector.detect() }

        let offline = CommandLine.arguments.contains("--offline")
        let engine = StatsEngine()
        if offline { _ = engine.compute(accounts: settings.accounts) }
        let stored = SnapshotStore.load()

        for acct in settings.accounts where acct.enabled && acct.trackLimits {
            if offline {
                print("[\(acct.provider.displayName)] \(acct.label)  (offline fallback)")
                guard let snap = LocalUsage.fallback(for: acct, stored: stored[acct.id], engine: engine) else {
                    print("  nothing known offline")
                    continue
                }
                print("  source: \(snap.source.rawValue)  as of \(Formatters.resetTime(snap.fetchedAt))")
                for w in snap.windows {
                    print("  \(w.title): \(Int(w.usedPercent.rounded()))%  \(w.pace().label())")
                }
                continue
            }
            let proxy = settings.effectiveProxy(for: acct.provider)
            print("[\(acct.provider.displayName)] \(acct.label)  \(acct.homePath)  via \(proxy.config.summary)")
            do {
                let session = SessionFactory.shared.session(for: proxy)
                let snap = try await UsageProviders.provider(for: acct.provider).fetch(account: acct, session: session)
                print("  plan: \(snap.plan ?? "-")  email: \(snap.email ?? "-")")
                for w in snap.windows {
                    let reset = w.resetsAt.map { Formatters.resetTime($0) } ?? "-"
                    print("  \(w.title): \(Int(w.usedPercent.rounded()))%  resets \(reset)  \(w.pace().label())  \(w.detail ?? "")")
                }
            } catch {
                print("  error: \(error.localizedDescription)")
            }
        }

        let start = Date()
        let stats = StatsEngine().compute(accounts: settings.accounts)
        print("\nTokens today: \(Formatters.compactTokens(stats.today))  (computed in \(String(format: "%.1f", Date().timeIntervalSince(start)))s)")
        for d in stats.days { print("  \(DayKey.string(d.day)): \(Formatters.compactTokens(d.total))") }
        for m in stats.models.prefix(5) { print("  \(m.model): \(Formatters.compactTokens(m.tokens))") }
        print("  today: \(stats.todayPrompts) prompts, \(stats.todayToolCalls) tool calls, \(stats.todaySessions) sessions, ≈ $\(String(format: "%.2f", stats.todayCost)) (+\(Formatters.compactTokens(stats.todayUnpriced)) unpriced)")
        print("  streak: \(stats.currentStreak) days, longest \(stats.longestStreak)")
        for p in stats.todayProjects.prefix(3) { print("  project: \(p.name) \(Formatters.compactTokens(p.tokens))") }
        for l in stats.live { print("  live: \(l.provider.displayName) \(l.project) \(Formatters.compactTokens(l.tokens))") }
    }
}
