import Foundation
import Network

/// Builds and caches one URLSession per effective proxy configuration.
public final class SessionFactory: @unchecked Sendable {
    public static let shared = SessionFactory()

    private let lock = NSLock()
    private var sessions: [EffectiveProxy: URLSession] = [:]

    public func session(for proxy: EffectiveProxy) -> URLSession {
        lock.lock()
        defer { lock.unlock() }
        if let s = sessions[proxy] { return s }
        let s = URLSession(configuration: Self.configuration(for: proxy))
        sessions[proxy] = s
        return s
    }

    /// Drop cached sessions after proxy settings change.
    public func reset() {
        lock.lock()
        let old = sessions.values
        sessions.removeAll()
        lock.unlock()
        old.forEach { $0.finishTasksAndInvalidate() }
    }

    public static func configuration(for proxy: EffectiveProxy) -> URLSessionConfiguration {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 20
        c.timeoutIntervalForResource = 40
        c.waitsForConnectivity = false
        c.httpCookieStorage = nil
        c.urlCache = nil

        let cfg = proxy.config
        switch cfg.kind {
        case .system:
            break
        case .direct:
            c.connectionProxyDictionary = [
                kCFNetworkProxiesHTTPEnable as String: false,
                kCFNetworkProxiesHTTPSEnable as String: false,
                kCFNetworkProxiesSOCKSEnable as String: false,
                kCFNetworkProxiesProxyAutoConfigEnable as String: false,
            ]
        case .http, .https, .socks5:
            guard cfg.isValid, let port = NWEndpoint.Port(rawValue: UInt16(cfg.port)) else { break }
            let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(cfg.host), port: port)
            var pc: ProxyConfiguration
            switch cfg.kind {
            case .socks5: pc = ProxyConfiguration(socksv5Proxy: endpoint)
            case .https: pc = ProxyConfiguration(httpCONNECTProxy: endpoint, tlsOptions: NWProtocolTLS.Options())
            default: pc = ProxyConfiguration(httpCONNECTProxy: endpoint)
            }
            if !cfg.username.isEmpty {
                pc.applyCredential(username: cfg.username, password: proxy.password)
            }
            pc.allowFailover = false
            c.proxyConfigurations = [pc]
        }
        return c
    }
}

public struct ProxyTestResult: Sendable {
    public var ok: Bool
    public var message: String
}

public enum ProxyTester {
    /// Any HTTP response (even 401/403) proves the path through the proxy works.
    public static func test(_ proxy: EffectiveProxy, url: URL) async -> ProxyTestResult {
        guard proxy.config.isValid else { return .init(ok: false, message: "Host and port required") }
        let session = URLSession(configuration: SessionFactory.configuration(for: proxy))
        defer { session.finishTasksAndInvalidate() }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.timeoutInterval = 12
        let start = Date()
        do {
            let (_, resp) = try await session.data(for: req)
            let ms = Int(Date().timeIntervalSince(start) * 1000)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            return .init(ok: true, message: "Reached \(url.host ?? "") · HTTP \(code) · \(ms) ms")
        } catch {
            return .init(ok: false, message: error.localizedDescription)
        }
    }
}
