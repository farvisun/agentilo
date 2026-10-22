import Foundation
import Network

/// HTTP server bound to 127.0.0.1 only. Each connection carries one request.
/// Requests from browser pages (an `Origin` header) or a foreign `Host` are refused.
public final class LocalServer: @unchecked Sendable {
    public typealias Handler = @Sendable (HTTPRequest) async -> HTTPResponse

    public let port: UInt16
    private let handler: Handler
    private let queue = DispatchQueue(label: "AgentLimits.LocalServer")
    private var listener: NWListener?
    /// Time a client gets to send its request.
    static let readTimeout: TimeInterval = 10

    public init(port: UInt16, handler: @escaping Handler) {
        self.port = port
        self.handler = handler
    }

    public func start() throws {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { throw URLError(.badURL) }
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: nwPort)
        let l = try NWListener(using: params)
        l.newConnectionHandler = { [weak self] c in self?.accept(c) }
        l.start(queue: queue)
        listener = l
    }

    public func stop() {
        listener?.cancel()
        listener = nil
    }

    private func accept(_ c: NWConnection) {
        c.start(queue: queue)
        queue.asyncAfter(deadline: .now() + Self.readTimeout) { [weak c] in
            if let c, !self.answered.contains(ObjectIdentifier(c)) { c.cancel() }
        }
        receive(c, buffer: Data())
    }

    /// Connections whose request was read; they may wait on a slow handler past the read timeout.
    private var answered = Set<ObjectIdentifier>()

    private func receive(_ c: NWConnection, buffer: Data) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, done, error in
            guard let self else { return }
            var buf = buffer
            if let data { buf.append(data) }
            switch HTTPRequest.parse(buf) {
            case .incomplete:
                if done || error != nil { c.cancel() } else { self.receive(c, buffer: buf) }
            case .invalid:
                self.send(.error(400, "bad request"), on: c)
            case .complete(let req):
                self.answered.insert(ObjectIdentifier(c))
                guard req.isTrustedLocal(port: self.port) else {
                    self.send(.error(403, "forbidden"), on: c)
                    return
                }
                let handler = self.handler
                Task {
                    let resp = await handler(req)
                    self.queue.async { self.send(resp, on: c) }
                }
            }
        }
    }

    private func send(_ resp: HTTPResponse, on c: NWConnection) {
        c.send(content: resp.serialized, completion: .contentProcessed { [weak self] _ in
            c.cancel()
            self?.queue.async { self?.answered.remove(ObjectIdentifier(c)) }
        })
    }
}
