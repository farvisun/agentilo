import Foundation

public enum ProxyKind: String, Codable, CaseIterable, Sendable, Identifiable {
    /// Follow macOS network settings.
    case system
    /// Connect directly, ignoring system proxies.
    case direct
    /// HTTP CONNECT proxy over plain TCP.
    case http
    /// HTTP CONNECT proxy reached over TLS.
    case https
    case socks5

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .system: "System"
        case .direct: "None (direct)"
        case .http: "HTTP"
        case .https: "HTTPS"
        case .socks5: "SOCKS5"
        }
    }

    public var needsServer: Bool { self == .http || self == .https || self == .socks5 }

    public var defaultPort: Int {
        switch self {
        case .socks5: 1080
        case .https: 443
        default: 8080
        }
    }
}

public struct ProxyConfig: Codable, Hashable, Sendable {
    public var kind: ProxyKind
    public var host: String
    public var port: Int
    /// Optional username; the password lives in the Keychain under `credentialKey`.
    public var username: String

    public init(kind: ProxyKind = .system, host: String = "", port: Int = 8080, username: String = "") {
        self.kind = kind
        self.host = host
        self.port = port
        self.username = username
    }

    public var isValid: Bool {
        !kind.needsServer || (!host.trimmingCharacters(in: .whitespaces).isEmpty && (1...65_535).contains(port))
    }

    public var summary: String {
        kind.needsServer ? "\(kind.displayName) \(host):\(port)" : kind.displayName
    }
}

/// Per-provider proxy: inherit the global one or use its own.
public struct ProviderProxy: Codable, Hashable, Sendable {
    public var useGlobal: Bool
    public var config: ProxyConfig

    public init(useGlobal: Bool = true, config: ProxyConfig = ProxyConfig()) {
        self.useGlobal = useGlobal
        self.config = config
    }
}

/// Fully resolved proxy for one request, including the password from the Keychain.
public struct EffectiveProxy: Hashable, Sendable {
    public var config: ProxyConfig
    public var password: String

    public init(config: ProxyConfig, password: String = "") {
        self.config = config
        self.password = password
    }
}

public enum ProxyCredentialKey {
    public static let global = "global"
    public static func provider(_ p: Provider) -> String { "provider.\(p.rawValue)" }
}
