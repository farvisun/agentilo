import AgentiloCore
import Foundation

/// `agentilo limits [--json|--short] [--force]`: the limits the app knows, for scripts,
/// agents and status lines. Asks the running app; without it, falls back to the cached
/// snapshots on disk, so it never blocks on a provider.
enum LimitsCommand {
    static let usage = """
    usage: agentilo limits [--json | --short] [--force]

      --json    machine-readable output (stable, versioned)
      --short   one line for a status bar, e.g. "Claude S 16% W 7% · Codex S 12% W 61%"
      --force   ask the app to refetch from the providers first (waits up to 15s)
    """

    static func run(_ args: [String]) async -> Int32 {
        if args.contains("-h") || args.contains("--help") {
            print(usage)
            return 0
        }
        let settings = SettingsStore.load()
        let force = args.contains("--force")
        let payload = await fromApp(settings: settings, force: force) ?? fromCache(settings: settings)

        if args.contains("--json") {
            let data = (try? APIJSON.encoder.encode(payload)) ?? Data()
            print(String(decoding: data, as: UTF8.self))
        } else if args.contains("--short") {
            print(payload.shortLine())
        } else {
            printHuman(payload)
        }
        return 0
    }

    static func fromApp(settings: AppSettings, force: Bool) async -> LimitsPayload? {
        guard settings.apiEnabled,
              let url = URL(string: "http://127.0.0.1:\(settings.apiPort)/v1/limits\(force ? "?refresh=1" : "")")
        else { return nil }
        let config = URLSessionConfiguration.ephemeral
        config.connectionProxyDictionary = [:]
        config.timeoutIntervalForRequest = force ? 20 : 2
        do {
            let (data, resp) = try await URLSession(configuration: config).data(from: url)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            return try APIJSON.decoder.decode(LimitsPayload.self, from: data)
        } catch {
            return nil
        }
    }

    static func fromCache(settings: AppSettings) -> LimitsPayload {
        let now = Date()
        let accounts = settings.accounts.filter { $0.enabled && $0.trackLimits }
        let snaps = SnapshotStore.load().compactMapValues { stored -> UsageSnapshot? in
            var s = stored.snapshot.rolledOver(now: now)
            s.source = .cached
            return s
        }
        return LimitsPayload.build(
            accounts: accounts, snapshots: snaps, includeLabels: settings.apiIncludeLabels, origin: "cache", now: now
        )
    }

    static func printHuman(_ p: LimitsPayload) {
        let now = Date()
        if p.origin == "cache" { print("(Agentilo is not running; showing cached numbers)\n") }
        for a in p.accounts {
            var head = "\(a.provider.displayName)  \(a.label)"
            if let plan = a.plan { head += "  (\(plan))" }
            if let source = a.source, source != .live { head += "  [\(source.rawValue)]" }
            print(head)
            if a.windows.isEmpty { print("  \(a.error ?? "no limits known")") }
            for w in a.windows {
                var line = "  \(w.title.padding(toLength: 18, withPad: " ", startingAt: 0))"
                line += "\(String(format: "%5.1f", w.usedPercent))%"
                if let reset = w.resetsAt {
                    line += "  resets \(Formatters.resetTime(reset, now: now)) (\(Formatters.countdown(to: reset, now: now)))"
                }
                switch w.pace {
                case "runsOut": line += w.runsOutAt.map { "  runs out \(Formatters.resetTime($0, now: now))" } ?? ""
                case "limitReached": line += "  LIMIT REACHED"
                case "ahead": line += "  ahead of pace"
                default: break
                }
                print(line)
            }
        }
    }
}
