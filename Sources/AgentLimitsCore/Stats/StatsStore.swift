import Foundation

public struct DayTotal: Hashable, Sendable, Identifiable {
    public var day: Date
    public var byProvider: [Provider: Int]
    public var id: Date { day }
    public var total: Int { byProvider.values.reduce(0, +) }
}

public struct ModelTotal: Hashable, Sendable, Identifiable {
    public var model: String
    public var tokens: Int
    public var id: String { model }
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

    public init(cacheURL: URL = Paths.appSupport.appendingPathComponent("stats-cache-v3.json")) {
        self.cacheURL = cacheURL
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
            let root = acct.provider == .claude ? home + "/projects" : home + "/sessions"
            for (url, mtime, size) in Self.logFiles(under: root, since: cutoff) {
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
        return Self.summarize(perFile, now: now)
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
            let consumed = provider == .claude
                ? ClaudeLogParser.parse(data, into: &agg)
                : CodexLogParser.parse(data, into: &agg)
            agg.parsedBytes = offset + Int64(consumed)
        } catch {
            return nil
        }
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
        var modelMap: [String: Int] = [:]
        var seen = Set<UInt64>()

        // Oldest file first so a copied message counts once, in its original session.
        let ordered = files.sorted { ($0.agg.firstTimestamp ?? .distantFuture) < ($1.agg.firstTimestamp ?? .distantFuture) }
        for f in ordered {
            for e in f.agg.entries {
                if e.k != 0 { guard seen.insert(e.k).inserted else { continue } }
                dayMap[e.d, default: [:]][f.provider, default: 0] += e.t
                if keys30.contains(e.d) { modelMap[f.agg.models[Int(e.m)], default: 0] += e.t }
            }
            if let last = f.agg.lastTimestamp, now.timeIntervalSince(last) < liveWindow {
                stats.live.append(LiveSession(
                    id: f.key, provider: f.provider, project: f.agg.project ?? "session",
                    start: f.agg.firstTimestamp ?? last, last: last, tokens: f.agg.totalTokens
                ))
            }
        }

        stats.todayByProvider = dayMap[todayKey] ?? [:]
        stats.today = stats.todayByProvider.values.reduce(0, +)
        stats.days = days7.map { DayTotal(day: $0.1, byProvider: dayMap[$0.0] ?? [:]) }
        stats.models = modelMap.map { ModelTotal(model: $0.key, tokens: $0.value) }.sorted { $0.tokens > $1.tokens }
        stats.live.sort { $0.last > $1.last }
        stats.computedAt = now
        return stats
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
