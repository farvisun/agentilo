import Foundation

public enum UsageError: LocalizedError, Equatable {
    case notSignedIn(String)
    case tokenExpired(String)
    case http(Int)
    case rateLimited
    case badResponse(String)

    public var errorDescription: String? {
        switch self {
        case .notSignedIn(let hint): hint
        case .tokenExpired(let hint): hint
        case .http(let code): "Server returned HTTP \(code)"
        case .rateLimited: "Rate limited by provider, retrying later"
        case .badResponse(let what): "Unexpected response: \(what)"
        }
    }

    /// Errors worth backing off on rather than retrying on the normal cadence.
    public var isTransient: Bool {
        switch self {
        case .rateLimited: true
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
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        switch code {
        case 200..<300: break
        case 401, 403: throw onUnauthorized()
        case 429: throw UsageError.rateLimited
        default: throw UsageError.http(code)
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw UsageError.badResponse("not a JSON object")
        }
        return obj
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
