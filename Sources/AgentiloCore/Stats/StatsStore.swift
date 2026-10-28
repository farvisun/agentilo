import Foundation

public struct DayTotal: Hashable, Sendable, Identifiable {
    public var day: Date
    public var byProvider: [Provider: Int]
    /// API-price estimate in USD for the models with a known price.
    public var cost: Double = 0
    public var id: Date { day }
    public var total: Int { byProvider.values.reduce(0, +) }
}

public struct ModelTotal: Hashable, Sendable, Identifiable {
    public var model: String
    public var tokens: Int
    public var id: String { model }
}

public struct ProjectTotal: Hashable, Sendable, Identifiable {
    public var name: String
    public var tokens: Int
    public var id: String { name }
}

/// Tokens, cost and prompts of one project, model or provider on one day.
public struct DayUsage: Codable, Hashable, Sendable {
    public var tokens: Int = 0
    public var cost: Double = 0
    public var prompts: Int = 0

    public init(tokens: Int = 0, cost: Double = 0, prompts: Int = 0) {
        self.tokens = tokens
        self.cost = cost
        self.prompts = prompts
    }

    public static func + (a: DayUsage, b: DayUsage) -> DayUsage {
        DayUsage(tokens: a.tokens + b.tokens, cost: a.cost + b.cost, prompts: a.prompts + b.prompts)
    }
}

/// One day of activity across all agents, persisted in `daily-history.json`.
public struct DayRecord: Codable, Hashable, Sendable, Identifiable {
    /// yyyymmdd.
    public var day: Int32
    public var tokens: Int = 0
    public var cost: Double = 0
    public var prompts: Int = 0
    public var tools: Int = 0
    /// Breakdowns for reports; nil on days recorded before 0.4. Models carry no prompts,
    /// since a prompt can be answered by several models.
    public var projects: [String: DayUsage]?
    public var models: [String: DayUsage]?
    public var providers: [String: DayUsage]?
    public var id: Int32 { day }

    public var active: Bool { tokens > 0 || prompts > 0 }
}

extension DayRecord {
    mutating func add(_ u: DayUsage, project: String, model: String?, provider: Provider) {
        projects = projects ?? [:]
        providers = providers ?? [:]
        models = models ?? [:]
        projects![project] = (projects![project] ?? DayUsage()) + u
        providers![provider.rawValue] = (providers![provider.rawValue] ?? DayUsage()) + u
        if let model { models![model] = (models![model] ?? DayUsage()) + u }
    }
}

public struct LiveSession: Hashable, Sendable, Identifiable {
    public var id: String
    public var provider: Provider
    public var project: String
    public var start: Date
    public var last: Date
    public var tokens: Int
}

public struct TokenStats: Sendable, Equatable {
    public var today: Int = 0
    public var todayByProvider: [Provider: Int] = [:]
    /// Last 7 days, oldest first.
    public var days: [DayTotal] = []
    /// Last 30 days, largest first.
    public var models: [ModelTotal] = []
    public var live: [LiveSession] = []
    /// API-price estimate for today; `todayUnpriced` counts tokens of models without a price.
    public var todayCost: Double = 0
    public var todayUnpriced = 0
    public var todayPrompts = 0
    public var todayToolCalls = 0
    /// Session logs with activity today.
    public var todaySessions = 0
    /// Today's projects by tokens, largest first.
    public var todayProjects: [ProjectTotal] = []
    /// Daily activity, oldest first, ending today; kept beyond the agents' own log retention.
    public var history: [DayRecord] = []
    public var currentStreak = 0
    public var longestStreak = 0
    public var computedAt = Date.distantPast

    public init() {}
}

/// Scans session logs of every enabled home, caching per-file aggregates by mtime and size.
public final class StatsEngine: @unchecked Sendable {
    private let cacheURL: URL
    private var cache: [String: FileAggregate]
    private let lock = NSLock()

    public static let lookbackDays = 30
    public static let liveWindow: TimeInterval = 15 * 60
    /// Days of history the heatmap shows.
    public static let historyDays = 26 * 7

    private let historyURL: URL

    /// v5 adds Codex prices and per-day breakdowns, so every log is read once more.
    public init(cacheURL: URL = Paths.appSupport.appendingPathComponent("stats-cache-v5.json")) {
        self.cacheURL = cacheURL
        for old in 2...4 {
            try? FileManager.default.removeItem(at: cacheURL.deletingLastPathComponent().appendingPathComponent("stats-cache-v\(old).json"))
        }
        historyURL = cacheURL.deletingLastPathComponent().appendingPathComponent("daily-history.json")
        if let data = try? Data(contentsOf: cacheURL),
           let c = try? JSONDecoder().decode([String: FileAggregate].self, from: data) {
            cache = c
        } else {
            cache = [:]
        }
    }

    public func compute(accounts: [Account], now: Date = Date()) -> TokenStats {
        lock.lock()
        defer { lock.unlock() }

        let cutoff = now.addingTimeInterval(-Double(Self.lookbackDays + 1) * 86_400)
        struct Job { var key: String; var provider: Provider; var url: URL; var mtime: Double; var size: Int64 }
        var jobs: [Job] = []
        var homes = Set<String>()
        for acct in accounts where acct.enabled && acct.provider != .cursor {
            let home = Paths.expand(acct.homePath)
            guard homes.insert("\(acct.provider.rawValue):\(home)").inserted else { continue }
            guard let root = Self.logRoot(acct.provider, home: home) else { continue }
            for (url, mtime, size) in Self.logFiles(under: root, since: cutoff)
            where acct.provider != .gemini || url.path.contains("/chats/") {
                jobs.append(Job(key: "\(acct.provider.rawValue):\(url.path)", provider: acct.provider, url: url, mtime: mtime, size: size))
            }
        }

        let previous = cache
        var results = [FileAggregate?](repeating: nil, count: jobs.count)
        let resultsLock = NSLock()
        DispatchQueue.concurrentPerform(iterations: jobs.count) { i in
            let job = jobs[i]
            let agg = Self.update(previous[job.key], provider: job.provider, url: job.url, mtime: job.mtime, size: job.size)
            resultsLock.lock()
            results[i] = agg
            resultsLock.unlock()
        }

        var used: [String: FileAggregate] = [:]
        var perFile: [(key: String, provider: Provider, agg: FileAggregate)] = []
        for (job, agg) in zip(jobs, results) {
            guard let agg else { continue }
            used[job.key] = agg
            perFile.append((job.key, job.provider, agg))
        }
        let changed = used != previous
        cache = used
        if changed { persist() }
        var stats = Self.summarize(perFile, now: now)
        let stored = loadHistory()
        let history = Self.mergeHistory(stored, recent: stats.history, now: now)
        if history != stored { saveHistory(history) }
        Self.applyHistory(history, to: &stats, now: now)
        return stats
    }

    // MARK: History

    /// Days inside the log lookback come from the fresh scan; older days are kept as recorded,
    /// since agents delete their own logs after a while.
    static func mergeHistory(_ old: [Int32: DayRecord], recent: [DayRecord], now: Date) -> [Int32: DayRecord] {
        let cal = Calendar.current
        let start = cal.startOfDay(for: now)
        let scanned = Set((0..<lookbackDays).map { DayKey.int(cal.date(byAdding: .day, value: -$0, to: start)!) })
        let oldest = DayKey.int(cal.date(byAdding: .day, value: -(historyDays + 7), to: start)!)
        var out = old.filter { !scanned.contains($0.key) && $0.key >= oldest }
        for r in recent where r.active { out[r.day] = r }
        return out
    }

    /// Fills the heatmap days and streaks. A streak still counts while today has no activity yet.
    static func applyHistory(_ history: [Int32: DayRecord], to stats: inout TokenStats, now: Date) {
        let cal = Calendar.current
        let start = cal.startOfDay(for: now)
        let days = (0..<historyDays).reversed().map { cal.date(byAdding: .day, value: -$0, to: start)! }
        stats.history = days.map { history[DayKey.int($0)] ?? DayRecord(day: DayKey.int($0)) }

        var current = 0
        for (i, d) in stats.history.reversed().enumerated() {
            if d.active { current += 1 } else if i > 0 { break }
        }
        var longest = 0, run = 0
        for d in stats.history {
            run = d.active ? run + 1 : 0
            longest = max(longest, run)
        }
        stats.currentStreak = current
        stats.longestStreak = max(longest, current)
    }

    private func loadHistory() -> [Int32: DayRecord] {
        guard let data = try? Data(contentsOf: historyURL),
              let list = try? JSONDecoder().decode([DayRecord].self, from: data) else { return [:] }
        return Dictionary(list.map { ($0.day, $0) }, uniquingKeysWith: { a, _ in a })
    }

    private func saveHistory(_ h: [Int32: DayRecord]) {
        guard let data = try? JSONEncoder().encode(h.values.sorted { $0.day < $1.day }) else { return }
        try? data.write(to: historyURL, options: .atomic)
    }

    /// Cost-weighted tokens logged in one home in `(from, to]`, deduplicated. Uses the last scan.
    public func weightedTokens(provider: Provider, home: String, from: Date, to: Date) -> Double {
        lock.lock()
        defer { lock.unlock() }
        let prefix = "\(provider.rawValue):\(Paths.expand(home))/"
        let lo = Int64(from.timeIntervalSince1970), hi = Int64(to.timeIntervalSince1970)
        var seen = Set<UInt64>()
        var sum = 0.0
        for (key, agg) in cache where key.hasPrefix(prefix) {
            guard let last = agg.lastTimestamp, Int64(last.timeIntervalSince1970) > lo else { continue }
            for e in agg.entries where e.s > lo && e.s <= hi {
                if e.k != 0 { guard seen.insert(e.k).inserted else { continue } }
                sum += e.w
            }
        }
        return sum
    }

    /// Newest `rate_limits` sample Codex wrote in any session log of this home.
    public func latestRateLimits(home: String) -> RateLimitSample? {
        lock.lock()
        defer { lock.unlock() }
        let prefix = "\(Provider.codex.rawValue):\(Paths.expand(home))/"
        return cache.lazy
            .filter { $0.key.hasPrefix(prefix) }
            .compactMap(\.value.rateLimits)
            .max { $0.at < $1.at }
    }

    /// Reuses a cached aggregate, parses only appended bytes, or parses the whole file.
    static func update(_ cached: FileAggregate?, provider: Provider, url: URL, mtime: Double, size: Int64) -> FileAggregate? {
        if let cached, cached.mtime == mtime, cached.size == size { return cached }
        var agg = FileAggregate()
        var offset: Int64 = 0
        if let cached, size >= cached.parsedBytes {
            agg = cached
            offset = cached.parsedBytes
        }
        guard let fh = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? fh.close() }
        do {
            try fh.seek(toOffset: UInt64(offset))
            let data = try fh.readToEnd() ?? Data()
            let consumed = switch provider {
            case .claude: ClaudeLogParser.parse(data, into: &agg)
            case .codex: CodexLogParser.parse(data, into: &agg)
            case .gemini: GeminiLogParser.parse(data, into: &agg)
            case .cursor: data.count
            }
            agg.parsedBytes = offset + Int64(consumed)
        } catch {
            return nil
        }
        if provider == .gemini, agg.project == nil { agg.project = GeminiLogParser.project(for: url) }
        agg.mtime = mtime
        agg.size = size
        return agg
    }

    static func summarize(_ files: [(key: String, provider: Provider, agg: FileAggregate)], now: Date) -> TokenStats {
        let cal = Calendar.current
        let todayStart = cal.startOfDay(for: now)
        let days7: [(Int32, Date)] = (0..<7).reversed().map { offset in
            let d = cal.date(byAdding: .day, value: -offset, to: todayStart)!
            return (DayKey.int(d), d)
        }
        let keys30 = Set((0..<StatsEngine.lookbackDays).map {
            DayKey.int(cal.date(byAdding: .day, value: -$0, to: todayStart)!)
        })
        let todayKey = DayKey.int(now)

        var stats = TokenStats()
        var dayMap: [Int32: [Provider: Int]] = [:]
        var costMap: [Int32: Double] = [:]
        var records: [Int32: DayRecord] = [:]
        var modelMap: [String: Int] = [:]
        var projectMap: [String: Int] = [:]
        var seen = Set<UInt64>()
        var seenActivity = Set<UInt64>()

        // Oldest file first so a copied message counts once, in its original session.
        let ordered = files.sorted { ($0.agg.firstTimestamp ?? .distantFuture) < ($1.agg.firstTimestamp ?? .distantFuture) }
        for f in ordered {
            var activeToday = false
            for e in f.agg.entries {
                if e.k != 0 { guard seen.insert(e.k).inserted else { continue } }
                dayMap[e.d, default: [:]][f.provider, default: 0] += e.t
                records[e.d, default: DayRecord(day: e.d)].tokens += e.t
                let usage = DayUsage(tokens: e.t, cost: e.c ?? 0)
                records[e.d]!.add(usage, project: f.agg.project ?? "session", model: f.agg.models[Int(e.m)], provider: f.provider)
                if let c = e.c {
                    costMap[e.d, default: 0] += c
                    records[e.d, default: DayRecord(day: e.d)].cost += c
                } else if e.d == todayKey {
                    stats.todayUnpriced += e.t
                }
                if keys30.contains(e.d) { modelMap[f.agg.models[Int(e.m)], default: 0] += e.t }
                if e.d == todayKey {
                    activeToday = true
                    projectMap[f.agg.project ?? "session", default: 0] += e.t
                }
            }
            for a in f.agg.activity {
                if a.k != 0 { guard seenActivity.insert(a.k).inserted else { continue } }
                switch a.a {
                case .prompt:
                    records[a.d, default: DayRecord(day: a.d)].prompts += 1
                    records[a.d]!.add(DayUsage(prompts: 1), project: f.agg.project ?? "session", model: nil, provider: f.provider)
                case .tool: records[a.d, default: DayRecord(day: a.d)].tools += 1
                }
                if a.d == todayKey { activeToday = true }
            }
            if activeToday { stats.todaySessions += 1 }
            if let last = f.agg.lastTimestamp, now.timeIntervalSince(last) < liveWindow {
                stats.live.append(LiveSession(
                    id: f.key, provider: f.provider, project: f.agg.project ?? "session",
                    start: f.agg.firstTimestamp ?? last, last: last, tokens: f.agg.totalTokens
                ))
            }
        }

        stats.todayByProvider = dayMap[todayKey] ?? [:]
        stats.today = stats.todayByProvider.values.reduce(0, +)
        stats.days = days7.map { DayTotal(day: $0.1, byProvider: dayMap[$0.0] ?? [:], cost: costMap[$0.0] ?? 0) }
        stats.todayCost = costMap[todayKey] ?? 0
        stats.todayPrompts = records[todayKey]?.prompts ?? 0
        stats.todayToolCalls = records[todayKey]?.tools ?? 0
        stats.todayProjects = projectMap.map { ProjectTotal(name: $0.key, tokens: $0.value) }.sorted { $0.tokens > $1.tokens }
        // The scanned days only; `compute` merges them into the long history.
        stats.history = records.values.filter { keys30.contains($0.day) }.sorted { $0.day < $1.day }
        stats.models = modelMap.map { ModelTotal(model: $0.key, tokens: $0.value) }.sorted { $0.tokens > $1.tokens }
        stats.live.sort { $0.last > $1.last }
        stats.computedAt = now
        return stats
    }

    /// Where an agent keeps its session logs; Cursor keeps none we read.
    static func logRoot(_ provider: Provider, home: String) -> String? {
        switch provider {
        case .claude: home + "/projects"
        case .codex: home + "/sessions"
        case .gemini: home + "/tmp"
        case .cursor: nil
        }
    }

    static func logFiles(under root: String, since cutoff: Date) -> [(URL, Double, Int64)] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: root),
              let e = fm.enumerator(
                  at: URL(fileURLWithPath: root),
                  includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey],
                  options: [.skipsHiddenFiles]
              ) else { return [] }
        var out: [(URL, Double, Int64)] = []
        let resolvedRoot = URL(fileURLWithPath: root).resolvingSymlinksInPath().path
        for case let url as URL in e where url.pathExtension == "jsonl" {
            guard let v = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]),
                  v.isRegularFile == true,
                  let m = v.contentModificationDate, m >= cutoff else { continue }
            // The enumerator may resolve symlinks (/var -> /private/var); keep paths under `root`
            // as given so cache keys match the configured home.
            var file = url
            if !url.path.hasPrefix(root + "/"), let range = url.path.range(of: resolvedRoot + "/") {
                file = URL(fileURLWithPath: root + "/" + url.path[range.upperBound...])
            }
            out.append((file, m.timeIntervalSince1970, Int64(v.fileSize ?? 0)))
        }
        return out
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(cache) else { return }
        try? data.write(to: cacheURL, options: .atomic)
    }
}
