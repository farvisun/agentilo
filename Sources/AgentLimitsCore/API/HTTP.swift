import Foundation

/// Just enough HTTP/1.1 for the loopback API: one request per connection, no chunking.
public struct HTTPRequest: Sendable {
    public var method: String
    public var path: String
    public var query: [String: String]
    /// Lowercased names.
    public var headers: [String: String]
    public var body: Data

    public enum Parse {
        case incomplete
        case complete(HTTPRequest)
        case invalid
    }

    public static let maxSize = 1 << 20

    public static func parse(_ data: Data) -> Parse {
        guard let end = data.range(of: Data("\r\n\r\n".utf8)) else {
            return data.count > maxSize ? .invalid : .incomplete
        }
        guard let head = String(data: data[data.startIndex..<end.lowerBound], encoding: .utf8) else { return .invalid }
        var lines = head.components(separatedBy: "\r\n")
        let start = lines.removeFirst().split(separator: " ")
        guard start.count == 3 else { return .invalid }

        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { return .invalid }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let length = Int(headers["content-length"] ?? "0") ?? -1
        guard length >= 0, length <= maxSize else { return .invalid }
        let bodyStart = end.upperBound
        guard data.count - (bodyStart - data.startIndex) >= length else { return .incomplete }
        let body = data.subdata(in: bodyStart..<(bodyStart + length))

        let target = String(start[1])
        let comps = URLComponents(string: target)
        var query: [String: String] = [:]
        for item in comps?.queryItems ?? [] { query[item.name] = item.value ?? "" }
        return .complete(HTTPRequest(
            method: String(start[0]).uppercased(), path: comps?.path ?? target,
            query: query, headers: headers, body: body
        ))
    }

    /// Browser pages send `Origin`; DNS rebinding shows up as a foreign `Host`. Neither may talk to us.
    public func isTrustedLocal(port: UInt16) -> Bool {
        if headers["origin"] != nil { return false }
        guard let host = headers["host"] else { return false }
        return ["127.0.0.1:\(port)", "localhost:\(port)"].contains(host.lowercased())
    }
}

public struct HTTPResponse: Sendable {
    public var status: Int
    public var body: Data
    public var contentType: String

    public init(status: Int, body: Data = Data(), contentType: String = "application/json") {
        self.status = status
        self.body = body
        self.contentType = contentType
    }

    public static func json<T: Encodable>(_ value: T, status: Int = 200) -> HTTPResponse {
        HTTPResponse(status: status, body: (try? APIJSON.encoder.encode(value)) ?? Data("{}".utf8))
    }

    public static func error(_ status: Int, _ message: String) -> HTTPResponse {
        json(["error": message], status: status)
    }

    public var serialized: Data {
        let reason = [200: "OK", 204: "No Content", 400: "Bad Request", 401: "Unauthorized", 403: "Forbidden",
                      404: "Not Found", 405: "Method Not Allowed", 503: "Service Unavailable"][status] ?? "Status"
        var head = "HTTP/1.1 \(status) \(reason)\r\n"
        head += "Content-Type: \(contentType)\r\nContent-Length: \(body.count)\r\n"
        head += "Cache-Control: no-store\r\nConnection: close\r\n\r\n"
        return Data(head.utf8) + body
    }
}

public enum APIJSON {
    public static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .iso8601
        return e
    }

    public static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}
