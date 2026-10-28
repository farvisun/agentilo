import Foundation

/// Last good server response for an account, plus what we learned to estimate from logs.
public struct StoredUsage: Codable, Equatable, Sendable {
    public var snapshot: UsageSnapshot
    /// Window id -> percent of the limit per cost-weighted token (Claude).
    public var calibration: [String: Double]

    public init(snapshot: UsageSnapshot, calibration: [String: Double] = [:]) {
        self.snapshot = snapshot
        self.calibration = calibration
    }
}

public enum SnapshotStore {
    static var fileURL: URL { Paths.appSupport.appendingPathComponent("snapshots.json") }

    public static func load() -> [UUID: StoredUsage] {
        guard let data = try? Data(contentsOf: fileURL),
              let s = try? JSONDecoder().decode([UUID: StoredUsage].self, from: data) else { return [:] }
        return s
    }

    public static func save(_ stored: [UUID: StoredUsage]) {
        guard let data = try? JSONEncoder().encode(stored) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}

/// Usage without the provider server: used when the API is rate limited, offline or the token expired.
public enum LocalUsage {
    /// Below this many weighted tokens inside a window, local logs say too little to calibrate.
    static let minCalibrationTokens = 20_000.0

    /// Learns percent-per-weighted-token for each window from logs inside the window up to the fetch.
    /// Usage from other devices or claude.ai makes the ratio higher, which errs on the safe side.
    public static func calibrate(
        _ snap: UsageSnapshot,
        account: Account,
        engine: StatsEngine,
        previous: [String: Double]
    ) -> [String: Double] {
        guard account.provider == .claude else { return [:] }
        var out = previous
        for w in snap.windows {
            guard let reset = w.resetsAt, let length = w.windowLength, w.usedPercent >= 1 else { continue }
            let tokens = engine.weightedTokens(
                provider: .claude, home: account.homePath,
                from: reset.addingTimeInterval(-length), to: snap.fetchedAt
            )
            guard tokens >= minCalibrationTokens else { continue }
            let ratio = w.usedPercent / tokens
            out[w.id] = previous[w.id].map { ($0 + ratio) / 2 } ?? ratio
        }
        return out
    }

    /// Claude: advance the last server response by tokens logged since, using the calibration.
    public static func estimate(
        _ stored: StoredUsage,
        account: Account,
        engine: StatsEngine,
        now: Date = Date()
    ) -> UsageSnapshot {
        let base = stored.snapshot
        let rolled = base.rolledOver(now: now)
        var estimated = false
        var snap = rolled
        snap.windows = zip(base.windows, rolled.windows).map { old, new in
            guard let ratio = stored.calibration[old.id] else { return new }
            let reset = old.resetsAt.flatMap { $0 <= now ? $0 : nil }
            let since = reset ?? base.fetchedAt
            let tokens = engine.weightedTokens(provider: account.provider, home: account.homePath, from: since, to: now)
            var w = new
            w.usedPercent = min(100, (reset == nil ? old.usedPercent : 0) + tokens * ratio)
            estimated = true
            return w
        }
        snap.source = estimated ? .estimated : .cached
        return snap
    }

    /// Codex writes the exact limits into every `token_count` event of its session logs.
    public static func codex(_ sample: RateLimitSample, base: UsageSnapshot?) -> UsageSnapshot {
        var windows: [UsageWindow] = []
        for (id, w) in [("primary_window", sample.primary), ("secondary_window", sample.secondary)] {
            guard let w else { continue }
            let length = w.windowMinutes.map { $0 * 60 }
            let isSession = (length ?? 0) > 0 && (length ?? 0) <= 86_400
            windows.append(UsageWindow(
                id: id, kind: isSession ? .session : .weekly, title: isSession ? "Session" : "Weekly",
                usedPercent: w.usedPercent, resetsAt: w.resetsAt, windowLength: length
            ))
        }
        windows.sort { ($0.windowLength ?? .infinity) < ($1.windowLength ?? .infinity) }
        return UsageSnapshot(
            windows: windows,
            plan: sample.planType.map(CodexProvider.planName) ?? base?.plan,
            email: base?.email,
            fetchedAt: sample.at,
            source: .localLog
        )
    }

    /// Best offline snapshot for an account, or nil when nothing is known.
    public static func fallback(
        for account: Account,
        stored: StoredUsage?,
        engine: StatsEngine,
        now: Date = Date()
    ) -> UsageSnapshot? {
        switch account.provider {
        case .codex:
            let fromLog = engine.latestRateLimits(home: account.homePath).map { codex($0, base: stored?.snapshot) }
            let candidates = [fromLog, stored.map { s -> UsageSnapshot in var c = s.snapshot; c.source = .cached; return c }]
                .compactMap { $0 }
            return candidates.max { $0.fetchedAt < $1.fetchedAt }?.rolledOver(now: now)
        case .claude:
            return stored.map { estimate($0, account: account, engine: engine, now: now) }
        case .cursor:
            return stored.map { s -> UsageSnapshot in
                var c = s.snapshot.rolledOver(now: now)
                c.source = .cached
                return c
            }
        }
    }
}
