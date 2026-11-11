import Foundation

public enum UsageError: LocalizedError, Equatable {
    case notSignedIn(String)
    case tokenExpired(String)
    case http(Int)
    /// `retryAfter` is the wait the provider asked for, in seconds, when it said.
    case rateLimited(retryAfter: TimeInterval? = nil)
    case badResponse(String)
    case timedOut(TimeInterval)

    public var errorDescription: String? {
        switch self {
        case .notSignedIn(let hint): hint
        case .tokenExpired(let hint): hint
        case .http(let code): "Server returned HTTP \(code)"
        case .rateLimited(let after):
            if let after { "Rate limited by provider, retrying in \(Formatters.duration(after))" } else { "Rate limited by provider, retrying later" }
        case .badResponse(let what): "Unexpected response: \(what)"
        case .timedOut(let s): "Refresh timed out after \(Int(s))s"
        }
    }

    /// Errors worth backing off on rather than retrying on the normal cadence.
    public var isTransient: Bool {
        switch self {
        case .rateLimited, .timedOut: true
        case .http(let code): code >= 500
        default: false
        }
    }
}

public protocol UsageProvider: Sendable {
    func fetch(account: Account, session: URLSession) async throws -> UsageSnapshot
}

public enum UsageProviders {
    public static func provider(for p: Provider) -> UsageProvider {
        switch p {
        case .claude: ClaudeProvider()
        case .codex: CodexProvider()
        case .cursor: CursorProvider()
        case .gemini: GeminiProvider()
        case .copilot: CopilotProvider()
        case .openRouter: OpenRouterProvider()
        case .opencode: OpenCodeProvider()
        }
    }
}

enum HTTP {
    static func getJSON(
        _ request: URLRequest,
        session: URLSession,
        onUnauthorized: () -> UsageError
    ) async throws -> [String: Any] {
        let (data, resp) = try await session.data(for: request)
        let http = resp as? HTTPURLResponse
        let code = http?.statusCode ?? 0
        let wait = retryAfter(http?.value(forHTTPHeaderField: "Retry-After"))
        switch code {
        case 200..<300: break
        case 429: throw UsageError.rateLimited(retryAfter: wait)
        case 403 where http?.value(forHTTPHeaderField: "x-ratelimit-remaining") == "0" || wait != nil:
            // GitHub answers a rate limit with 403 and these headers, not 429.
            let reset = http?.value(forHTTPHeaderField: "x-ratelimit-reset").flatMap(Double.init)
                .map { min(maxRetryAfter, max(0, $0 - Date().timeIntervalSince1970)) }
            throw UsageError.rateLimited(retryAfter: wait ?? reset)
        case 401, 403: throw onUnauthorized()
        default: throw UsageError.http(code)
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw UsageError.badResponse("not a JSON object")
        }
        return obj
    }
}

extension HTTP {
    /// A provider never holds Agentilo off longer than this.
    static let maxRetryAfter: TimeInterval = 3_600

    private static let httpDate: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "GMT")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return f
    }()

    /// `Retry-After` as seconds ("120") or an HTTP date, capped at an hour.
    static func retryAfter(_ value: String?, now: Date = Date()) -> TimeInterval? {
        guard let v = value?.trimmingCharacters(in: .whitespaces), !v.isEmpty else { return nil }
        let seconds = Double(v) ?? httpDate.date(from: v).map { $0.timeIntervalSince(now) }
        return seconds.map { min(maxRetryAfter, max(0, $0)) }
    }
}

/// Gives up on work that takes longer than `seconds`. The work is cancelled, though a blocking
/// call inside it (a child process) may finish on its own later; its result is dropped.
public func withDeadline<T: Sendable>(
    _ seconds: TimeInterval, _ work: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await work() }
        group.addTask {
            try await Task.sleep(for: .seconds(seconds))
            throw UsageError.timedOut(seconds)
        }
        defer { group.cancelAll() }
        return try await group.next()!
    }
}

/// When to ask a provider again after failures. Waits double from a minute up to an hour, and a
/// wait the provider asked for (`Retry-After`) also holds against a manual refresh.
public struct RefreshBackoff: Codable, Equatable, Sendable {
    public static let cap: TimeInterval = 3_600
    public var failures: Int
    public var retryAt: Date
    public var providerAsked: Bool

    public init(failures: Int, retryAt: Date, providerAsked: Bool) {
        self.failures = failures
        self.retryAt = retryAt
        self.providerAsked = providerAsked
    }

    public static func delay(failures n: Int) -> TimeInterval {
        min(cap, 30 * pow(2, Double(min(max(n, 1), 16))))
    }

    /// The backoff after `error`, or nil when the error is not worth backing off on.
    public static func after(_ error: Error, previous: RefreshBackoff?, now: Date = Date()) -> RefreshBackoff? {
        let e = error as? UsageError
        guard e?.isTransient ?? true else { return nil }
        let n = (previous?.failures ?? 0) + 1
        var wait = delay(failures: n), asked = false
        if case .rateLimited(let after?) = e {
            wait = max(wait, min(after, cap))
            asked = true
        }
        return RefreshBackoff(failures: n, retryAt: now.addingTimeInterval(wait), providerAsked: asked)
    }

    /// Whether to skip a fetch now. A manual refresh skips our own wait, not the provider's.
    public func holds(now: Date = Date(), forced: Bool) -> Bool {
        now < retryAt && (providerAsked || !forced)
    }
}

/// Provider-requested waits, kept so a relaunch does not walk straight back into a 429.
public enum BackoffStore {
    static var fileURL: URL { Paths.appSupport.appendingPathComponent("backoff.json") }

    public static func load(now: Date = Date()) -> [UUID: RefreshBackoff] {
        guard let data = try? Data(contentsOf: fileURL),
              let all = try? JSONDecoder().decode([UUID: RefreshBackoff].self, from: data) else { return [:] }
        return all.filter { $0.value.providerAsked && $0.value.retryAt > now }
    }

    public static func save(_ backoffs: [UUID: RefreshBackoff]) {
        let asked = backoffs.filter(\.value.providerAsked)
        guard let data = try? JSONEncoder().encode(asked) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}

/// Small helpers for walking loosely-typed JSON from undocumented endpoints.
enum J {
    static func dict(_ v: Any?) -> [String: Any]? { v as? [String: Any] }
    static func array(_ v: Any?) -> [Any]? { v as? [Any] }
    static func string(_ v: Any?) -> String? { v as? String }

    static func double(_ v: Any?) -> Double? {
        switch v {
        case let n as NSNumber: n.doubleValue
        case let s as String: Double(s)
        default: nil
        }
    }

    static func object(file url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    static func object(string: String) -> [String: Any]? {
        try? JSONSerialization.jsonObject(with: Data(string.utf8)) as? [String: Any]
    }
}

public enum DateParsing {
    private static let plain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// Parses ISO-8601 with any number of fractional digits (Foundation only accepts three).
    public static func iso(_ s: String?) -> Date? {
        guard var s else { return nil }
        var fraction = 0.0
        if let dot = s.firstIndex(of: ".") {
            var end = s.index(after: dot)
            while end < s.endIndex, s[end].isNumber { end = s.index(after: end) }
            fraction = Double("0" + s[dot..<end]) ?? 0
            s.removeSubrange(dot..<end)
        }
        return plain.date(from: s)?.addingTimeInterval(fraction)
    }

    /// "2026-12-01" as midnight UTC.
    public static func day(_ s: String?) -> Date? {
        guard let s, s.count == 10 else { return nil }
        return iso(s + "T00:00:00Z")
    }
}

enum JWT {
    static func payload(_ token: String) -> [String: Any]? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var b64 = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        guard let data = Data(base64Encoded: b64) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}

enum WindowLength {
    static let session: TimeInterval = 5 * 3_600
    static let week: TimeInterval = 7 * 86_400
}
