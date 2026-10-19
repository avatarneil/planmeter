import Foundation
import PlanMeterRemote

/// One parsed HTTP/1.1 request. Both listeners (the Mac's Network.framework
/// server and the portable POSIX server) produce this, so request handling is
/// shared.
public struct HTTPRequest: Sendable {
    public var method: String
    /// The request target without its query string, still percent-encoded.
    public var path: String
    /// Lowercased header names.
    public var headers: [String: String]
    public var body: Data
    /// Numeric peer address for TCP, or "unix" for a Unix domain socket.
    public var remoteHost: String

    public init(method: String, path: String, headers: [String: String] = [:], body: Data = Data(), remoteHost: String) {
        self.method = method
        self.path = path
        self.headers = headers
        self.body = body
        self.remoteHost = remoteHost
    }
}

public struct HTTPResponse: Sendable {
    public var status: Int
    public var body: Data
    public var contentType = "application/json"
    public var headers: [String: String] = [:]

    public init(status: Int, body: Data, contentType: String = "application/json", headers: [String: String] = [:]) {
        self.status = status
        self.body = body
        self.contentType = contentType
        self.headers = headers
    }

    /// Default `JSONEncoder` output, as the remote API has always sent for its
    /// unsealed replies (`/v1/info`, errors, the web pairing offer).
    public static func json<T: Encodable>(_ value: T, status: Int = 200) -> HTTPResponse {
        let data = (try? JSONEncoder().encode(value)) ?? Data()
        return HTTPResponse(status: status, body: data)
    }

    /// `RemoteJSON` output (ISO-8601 dates, sorted keys), used by the local
    /// control API.
    public static func remoteJSON<T: Encodable>(_ value: T, status: Int = 200) -> HTTPResponse {
        do {
            return HTTPResponse(status: status, body: try RemoteJSON.encoder.encode(value))
        } catch {
            return .error(500, "could not encode response")
        }
    }

    public static func error(_ status: Int, _ message: String) -> HTTPResponse {
        json(["error": message], status: status)
    }

    /// Status line, headers, and body. Every response closes the connection.
    public func serialized() -> Data {
        var head = "HTTP/1.1 \(status) \(HTTPResponse.reason(status))\r\n"
        head += "Content-Type: \(contentType)\r\n"
        head += "Content-Length: \(body.count)\r\n"
        head += "Cache-Control: no-store\r\n"
        head += "X-Content-Type-Options: nosniff\r\n"
        for (name, value) in headers.sorted(by: { $0.key < $1.key }) {
            head += "\(name): \(value)\r\n"
        }
        head += "Connection: close\r\n\r\n"
        var data = Data(head.utf8)
        data.append(body)
        return data
    }

    public static func reason(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 409: return "Conflict"
        case 413: return "Payload Too Large"
        case 429: return "Too Many Requests"
        case 431: return "Request Header Fields Too Large"
        case 500: return "Internal Server Error"
        case 503: return "Service Unavailable"
        default: return "Status"
        }
    }
}

public typealias HTTPHandler = @Sendable (HTTPRequest) async -> HTTPResponse

/// Limits shared by every PlanMeter listener: one request per connection,
/// bounded header and body sizes, and a hard deadline to receive the request.
public enum HTTPLimits {
    public static let maxHeaderBytes = 16 * 1024
    public static let maxBodyBytes = 1024 * 1024
    public static let connectionTimeout: TimeInterval = 20
}

/// Incremental parser for a single request on a connection. Feed it the bytes
/// received so far; it answers when it has a request, needs more, or the
/// connection should be failed or dropped.
public enum HTTPRequestParser {
    public enum Outcome: Sendable {
        /// Keep reading.
        case incomplete
        case request(HTTPRequest)
        /// Reply with this error and close.
        case failure(status: Int, message: String)
        /// Close without a reply (the peer went away mid-request).
        case close
    }

    static let headerTerminator = Data("\r\n\r\n".utf8)

    public static func parse(_ buffer: Data, isComplete: Bool, remoteHost: String,
                             maxHeaderBytes: Int = HTTPLimits.maxHeaderBytes,
                             maxBodyBytes: Int = HTTPLimits.maxBodyBytes) -> Outcome {
        guard let headerEnd = buffer.range(of: headerTerminator) else {
            if buffer.count > maxHeaderBytes { return .failure(status: 431, message: "headers too large") }
            if isComplete { return .close }
            return .incomplete
        }
        if headerEnd.lowerBound - buffer.startIndex > maxHeaderBytes {
            return .failure(status: 431, message: "headers too large")
        }
        guard let head = String(data: buffer[buffer.startIndex..<headerEnd.lowerBound], encoding: .utf8) else {
            return .failure(status: 400, message: "bad request")
        }
        let lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.first?.split(separator: " ").map(String.init) ?? []
        guard requestLine.count >= 2 else { return .failure(status: 400, message: "bad request") }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let contentLength = Int(headers["content-length"] ?? "0") ?? 0
        // A negative length would otherwise make an invalid body range.
        if contentLength < 0 { return .failure(status: 400, message: "bad request") }
        if contentLength > maxBodyBytes { return .failure(status: 413, message: "body too large") }
        let bodyStart = headerEnd.upperBound
        if buffer.endIndex - bodyStart < contentLength {
            if isComplete { return .failure(status: 400, message: "truncated body") }
            return .incomplete
        }
        let body = buffer.subdata(in: bodyStart..<(bodyStart + contentLength))
        let path = String(requestLine[1].split(separator: "?").first ?? "")
        return .request(HTTPRequest(method: requestLine[0], path: path, headers: headers, body: body, remoteHost: remoteHost))
    }
}
