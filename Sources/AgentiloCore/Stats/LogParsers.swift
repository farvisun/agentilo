import Foundation

/// One billed model response found in a log.
public struct UsageEntry: Codable, Equatable, Sendable {
    /// Stable hash of the message id; 0 means "never dedupe".
    public var k: UInt64
    /// Local day as yyyymmdd.
    public var d: Int32
    /// Index into `FileAggregate.models`.
    public var m: Int32
    /// Total tokens.
    public var t: Int
    /// Unix seconds of the response.
    public var s: Int64
    /// Cost-weighted tokens (roughly what plan limits meter), used to estimate limits offline.
    public var w: Double
    /// API list price in USD; nil for models without a known price.
    public var c: Double?
}

/// A prompt or a tool call found in a log, for activity counts.
public struct ActivityEntry: Codable, Equatable, Sendable {
    public enum Kind: UInt8, Codable, Sendable {
        case prompt = 0
        case tool = 1
    }

    /// Stable hash of the prompt or tool call id; 0 means "never dedupe".
    public var k: UInt64
    /// Local day as yyyymmdd.
    public var d: Int32
    public var a: Kind
}

/// `rate_limits` as Codex writes them into `token_count` events.
public struct RateLimitSample: Codable, Equatable, Sendable {
    public struct Window: Codable, Equatable, Sendable {
        public var usedPercent: Double
        public var windowMinutes: Double?
        public var resetsAt: Date?
    }

    public var at: Date
    public var primary: Window?
    public var secondary: Window?
    public var planType: String?
}

/// Parsed state of one session log. Logs are append-only, so parsing resumes at `parsedBytes`.
public struct FileAggregate: Codable, Equatable, Sendable {
    public var mtime: Double = 0
    public var size: Int64 = 0
    public var parsedBytes: Int64 = 0
    public var entries: [UsageEntry] = []
    public var activity: [ActivityEntry] = []
    public var models: [String] = []
    public var firstTimestamp: Date?
    public var lastTimestamp: Date?
    public var project: String?
    /// Codex: running session total seen so far, to turn cumulative counts into deltas.
    public var codexLastTotal = 0
    /// Codex: the same running totals split by kind, to price each delta.
    public var codexLast = CodexTotals()
    public var codexModel: String?
    /// Codex: most recent rate-limit sample in this file.
    public var rateLimits: RateLimitSample?

    public init() {}

    public var totalTokens: Int { entries.reduce(0) { $0 + $1.t } }

    mutating func add(_ tokens: Int, weighted: Double, cost: Double? = nil, model: String, at date: Date, key: UInt64) {
        guard tokens > 0 else { return }
        let mi: Int
        if let i = models.firstIndex(of: model) { mi = i } else { models.append(model); mi = models.count - 1 }
        entries.append(UsageEntry(
            k: key, d: DayKey.int(date), m: Int32(mi), t: tokens,
            s: Int64(date.timeIntervalSince1970), w: weighted, c: cost
        ))
        if firstTimestamp == nil || date < firstTimestamp! { firstTimestamp = date }
        if lastTimestamp == nil || date > lastTimestamp! { lastTimestamp = date }
    }

    mutating func addActivity(_ kind: ActivityEntry.Kind, id: String?, at date: Date) {
        activity.append(ActivityEntry(k: id.map(FNV.hash) ?? 0, d: DayKey.int(date), a: kind))
        if firstTimestamp == nil || date < firstTimestamp! { firstTimestamp = date }
        if lastTimestamp == nil || date > lastTimestamp! { lastTimestamp = date }
    }
}

/// Cumulative Codex token counts by kind (`total_token_usage`).
public struct CodexTotals: Codable, Equatable, Sendable {
    public var input = 0.0
    public var cached = 0.0
    public var output = 0.0
}

public enum DayKey {
    public static func string(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    public static func int(_ date: Date, calendar: Calendar = .current) -> Int32 {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return Int32((c.year ?? 0) * 10_000 + (c.month ?? 0) * 100 + (c.day ?? 0))
    }
}

enum FNV {
    static func hash(_ s: String) -> UInt64 {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for b in s.utf8 {
            h ^= UInt64(b)
            h = h &* 0x100_0000_01b3
        }
        return h == 0 ? 1 : h
    }
}

enum LogLines {
    /// Calls `body` for each complete line containing any marker, parsed as JSON.
    /// Returns the number of bytes consumed (up to and including the last newline).
    @discardableResult
    static func forEach(in data: Data, markers: [String], _ body: ([String: Any]) -> Void) -> Int {
        let needles = markers.map { Array($0.utf8) }
        return data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Int in
            guard let base = raw.baseAddress else { return 0 }
            let count = raw.count
            var start = 0
            while start < count {
                guard let nl = memchr(base + start, 0x0A, count - start) else { break }
                let end = base.distance(to: UnsafeRawPointer(nl))
                let len = end - start
                if len > 0, needles.contains(where: { n in
                    n.withUnsafeBytes { memmem(base + start, len, $0.baseAddress, n.count) != nil }
                }) {
                    let line = Data(bytesNoCopy: UnsafeMutableRawPointer(mutating: base + start), count: len, deallocator: .none)
                    if let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] { body(obj) }
                }
                start = end + 1
            }
            return start
        }
    }
}

/// Claude Code: `<home>/projects/<project>/<session>.jsonl`. Streaming writes a message several
/// times and resumed sessions copy history into new files, so entries carry a dedupe key.
public enum ClaudeLogParser {
    public static func parse(_ data: Data, into agg: inout FileAggregate) -> Int {
        var seen = Set(agg.entries.lazy.map(\.k).filter { $0 != 0 })
        var seenActivity = Set(agg.activity.lazy.map(\.k).filter { $0 != 0 })
        return LogLines.forEach(in: data, markers: ["\"usage\"", "\"promptId\""]) { obj in
            guard let msg = J.dict(obj["message"]), let date = DateParsing.iso(J.string(obj["timestamp"])) else { return }
            if agg.project == nil, let cwd = J.string(obj["cwd"]) {
                agg.project = (cwd as NSString).lastPathComponent
            }
            // Typed prompts carry a promptId; tool results and command output do not.
            if J.string(obj["type"]) == "user", let pid = J.string(obj["promptId"]),
               (obj["isSidechain"] as? Bool) != true, seenActivity.insert(FNV.hash(pid)).inserted {
                agg.addActivity(.prompt, id: pid, at: date)
            }
            // A response is written one content block per line, all lines sharing the message id.
            for block in (msg["content"] as? [[String: Any]]) ?? [] where J.string(block["type"]) == "tool_use" {
                guard let id = J.string(block["id"]), seenActivity.insert(FNV.hash(id)).inserted else { continue }
                agg.addActivity(.tool, id: id, at: date)
            }
            guard let usage = J.dict(msg["usage"]) else { return }
            let model = J.string(msg["model"]) ?? "unknown"
            guard model != "<synthetic>" else { return }
            var key: UInt64 = 0
            if let id = J.string(msg["id"]) {
                key = FNV.hash("\(id):\(J.string(obj["requestId"]) ?? "")")
                guard seen.insert(key).inserted else { return }
            }
            let input = J.double(usage["input_tokens"]) ?? 0
            let output = J.double(usage["output_tokens"]) ?? 0
            let write = J.double(usage["cache_creation_input_tokens"]) ?? 0
            let read = J.double(usage["cache_read_input_tokens"]) ?? 0
            let total = Int(input + output + write + read)
            agg.add(total, weighted: weight(model: model, input: input, output: output, cacheWrite: write, cacheRead: read),
                    cost: Pricing.cost(model: model, input: input, output: output, cacheWrite: write, cacheRead: read),
                    model: model, at: date, key: key)
        }
    }

    public static func parse(_ data: Data) -> FileAggregate {
        var agg = FileAggregate()
        _ = parse(data, into: &agg)
        return agg
    }

    /// Relative API price in input-token units; plan limits roughly track cost.
    static func weight(model: String, input: Double, output: Double, cacheWrite: Double, cacheRead: Double) -> Double {
        let m = model.lowercased()
        let tier = m.contains("haiku") ? 0.2 : m.contains("sonnet") ? 0.6 : 1.0
        return tier * (input + output * 5 + cacheWrite * 1.25 + cacheRead * 0.1)
    }
}

/// Codex: `<home>/sessions/YYYY/MM/DD/rollout-*.jsonl`. `token_count` events carry a running
/// session total, so each event contributes its delta (robust to repeated events).
public enum CodexLogParser {
    public static func parse(_ data: Data, into agg: inout FileAggregate) -> Int {
        LogLines.forEach(in: data, markers: [
            "\"token_count\"", "\"turn_context\"", "\"session_meta\"", "\"task_started\"", "_call\"",
        ]) { obj in
            let payload = J.dict(obj["payload"]) ?? [:]
            switch J.string(obj["type"]) {
            case "response_item" where ["function_call", "custom_tool_call", "local_shell_call"].contains(J.string(payload["type"]) ?? ""):
                if let date = DateParsing.iso(J.string(obj["timestamp"])) {
                    agg.addActivity(.tool, id: J.string(payload["call_id"]), at: date)
                }
            case "event_msg" where J.string(payload["type"]) == "task_started":
                if let date = DateParsing.iso(J.string(obj["timestamp"])) { agg.addActivity(.prompt, id: nil, at: date) }
            case "session_meta":
                if let cwd = J.string(payload["cwd"]) { agg.project = (cwd as NSString).lastPathComponent }
            case "turn_context":
                if let m = J.string(payload["model"]) { agg.codexModel = m }
            case "event_msg" where J.string(payload["type"]) == "token_count":
                if let sample = rateLimits(J.dict(payload["rate_limits"]), at: DateParsing.iso(J.string(obj["timestamp"]))) {
                    agg.rateLimits = sample
                }
                guard let info = J.dict(payload["info"]),
                      let usage = J.dict(info["total_token_usage"]),
                      let total = J.double(usage["total_tokens"]).map(Int.init),
                      let date = DateParsing.iso(J.string(obj["timestamp"])) else { return }
                // A smaller total means a new count started (e.g. a forked session).
                let restarted = total < agg.codexLastTotal
                let delta = restarted ? total : total - agg.codexLastTotal
                agg.codexLastTotal = total
                let now = CodexTotals(
                    input: J.double(usage["input_tokens"]) ?? 0,
                    cached: J.double(usage["cached_input_tokens"]) ?? 0,
                    output: J.double(usage["output_tokens"]) ?? 0
                )
                let before = restarted ? CodexTotals() : agg.codexLast
                agg.codexLast = now
                let model = agg.codexModel ?? "unknown"
                // Older logs carry only the total: count those as unpriced.
                let cost = usage["input_tokens"] == nil ? nil : Pricing.cachedInInputCost(
                    model: model, input: max(0, now.input - before.input),
                    cached: max(0, now.cached - before.cached), output: max(0, now.output - before.output)
                )
                agg.add(delta, weighted: Double(delta), cost: cost, model: model, at: date, key: 0)
            default:
                break
            }
        }
    }

    public static func parse(_ data: Data) -> FileAggregate {
        var agg = FileAggregate()
        _ = parse(data, into: &agg)
        return agg
    }

    static func rateLimits(_ rl: [String: Any]?, at date: Date?) -> RateLimitSample? {
        guard let rl, let date else { return nil }
        func window(_ v: Any?) -> RateLimitSample.Window? {
            guard let w = J.dict(v), let pct = J.double(w["used_percent"]) else { return nil }
            var reset = J.double(w["resets_at"]).map { Date(timeIntervalSince1970: $0) }
            if reset == nil, let after = J.double(w["resets_in_seconds"]) { reset = date.addingTimeInterval(after) }
            return .init(usedPercent: pct, windowMinutes: J.double(w["window_minutes"]), resetsAt: reset)
        }
        let primary = window(rl["primary"]), secondary = window(rl["secondary"])
        guard primary != nil || secondary != nil else { return nil }
        return RateLimitSample(at: date, primary: primary, secondary: secondary, planType: J.string(rl["plan_type"]))
    }
}
