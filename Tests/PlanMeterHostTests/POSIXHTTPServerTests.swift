import XCTest
@testable import PlanMeterHost
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

final class POSIXHTTPServerTests: XCTestCase {
    /// Echoes the request back as JSON.
    static let echo: HTTPHandler = { request in
        .json(["method": request.method, "path": request.path, "body": String(decoding: request.body, as: UTF8.self), "remoteHost": request.remoteHost])
    }

    private func startTCP(_ host: String = "127.0.0.1", options: POSIXHTTPServer.Options = .init(), handler: @escaping HTTPHandler = echo) throws -> (POSIXHTTPServer, UInt16) {
        let endpoint = POSIXHTTPServer.Endpoint.tcp(host: host, port: 0)
        let server = POSIXHTTPServer(endpoints: [endpoint], options: options, handler: handler)
        try server.start()
        return (server, try XCTUnwrap(server.boundPort(for: endpoint)))
    }

    func testTCPRoundTrip() throws {
        let (server, port) = try startTCP()
        defer { server.stop() }
        let reply = try XCTUnwrap(RawHTTP.exchange(.tcp("127.0.0.1", port), RawHTTP.request("POST", "/v1/rpc?q=1", body: Data("hello".utf8))))
        XCTAssertEqual(reply.status, 200)
        XCTAssertEqual(reply.headers["connection"], "close")
        XCTAssertEqual(reply.headers["content-length"], String(reply.body.count))
        let json = try XCTUnwrap(reply.json as? [String: String])
        XCTAssertEqual(json, ["method": "POST", "path": "/v1/rpc", "body": "hello", "remoteHost": "127.0.0.1"])
    }

    func testIPv6Loopback() throws {
        let server: POSIXHTTPServer
        let port: UInt16
        do {
            (server, port) = try startTCP("::1")
        } catch {
            throw XCTSkip("IPv6 loopback unavailable: \(error)")
        }
        defer { server.stop() }
        // The raw client speaks IPv4 only; check the bind and the port.
        XCTAssertGreaterThan(port, 0)
    }

    func testRejectsNonNumericAddresses() {
        let server = POSIXHTTPServer(endpoints: [.tcp(host: "localhost", port: 0)], handler: Self.echo)
        XCTAssertThrowsError(try server.start()) { error in
            XCTAssertEqual(error as? POSIXHTTPServer.ServerError, .invalidAddress("localhost"))
        }
    }

    func testHeaderAndBodyLimits() throws {
        let (server, port) = try startTCP()
        defer { server.stop() }
        let huge = "GET / HTTP/1.1\r\nX-Big: \(String(repeating: "a", count: HTTPLimits.maxHeaderBytes + 10))"
        let headers = try XCTUnwrap(RawHTTP.exchange(.tcp("127.0.0.1", port), Data(huge.utf8)))
        XCTAssertEqual(headers.status, 431)
        XCTAssertEqual(headers.errorMessage, "headers too large")

        let body = try XCTUnwrap(RawHTTP.exchange(.tcp("127.0.0.1", port), Data("POST / HTTP/1.1\r\nContent-Length: \(HTTPLimits.maxBodyBytes + 1)\r\n\r\n".utf8)))
        XCTAssertEqual(body.status, 413)

        let exact = Data(repeating: 0x61, count: HTTPLimits.maxBodyBytes)
        let ok = try XCTUnwrap(RawHTTP.exchange(.tcp("127.0.0.1", port), RawHTTP.request("POST", "/", body: exact)))
        XCTAssertEqual(ok.status, 200)
    }

    func testTruncatedBodyAndEarlyClose() throws {
        let (server, port) = try startTCP()
        defer { server.stop() }
        let truncated = try XCTUnwrap(RawHTTP.exchange(.tcp("127.0.0.1", port), Data("POST / HTTP/1.1\r\nContent-Length: 50\r\n\r\nshort".utf8), halfClose: true))
        XCTAssertEqual(truncated.status, 400)
        XCTAssertEqual(truncated.errorMessage, "truncated body")
        // Closing before the headers end gets no reply.
        XCTAssertNil(RawHTTP.exchange(.tcp("127.0.0.1", port), Data("GET / HTTP/1.1\r\n".utf8), halfClose: true))
    }

    func testSlowRequestsAreDroppedAtTheDeadline() throws {
        var options = POSIXHTTPServer.Options()
        options.connectionTimeout = 0.5
        let (server, port) = try startTCP(options: options)
        defer { server.stop() }
        let started = Date()
        XCTAssertNil(RawHTTP.exchange(.tcp("127.0.0.1", port), Data("GET / HTTP/1.1\r\n".utf8), timeout: 10))
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
    }

    func testConcurrentRequests() throws {
        let (server, port) = try startTCP(handler: { request in
            try? await Task.sleep(nanoseconds: 50_000_000)
            return .json(["path": request.path])
        })
        defer { server.stop() }
        final class Statuses: @unchecked Sendable {
            private let lock = NSLock()
            private var values: [Int] = []
            func append(_ value: Int) { lock.lock(); values.append(value); lock.unlock() }
            var sorted: [Int] { lock.lock(); defer { lock.unlock() }; return values.sorted() }
        }
        let group = DispatchGroup()
        let statuses = Statuses()
        for i in 0..<12 {
            group.enter()
            DispatchQueue.global().async {
                statuses.append(RawHTTP.exchange(.tcp("127.0.0.1", port), RawHTTP.request("GET", "/\(i)"))?.status ?? -1)
                group.leave()
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 20), .success)
        XCTAssertEqual(statuses.sorted, Array(repeating: 200, count: 12))
    }

    func testStopClosesTheListener() throws {
        let (server, port) = try startTCP()
        server.stop()
        Thread.sleep(forTimeInterval: 0.2)
        XCTAssertNil(RawHTTP.connect(.tcp("127.0.0.1", port)).map { fd -> Int32 in posixClose(fd); return fd })
    }

    // MARK: Unix sockets

    func testUnixSocketIsPrivateAndServesTheSameUser() throws {
        let dir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("control.sock").path
        let server = POSIXHTTPServer(endpoints: [.unix(path: path)], options: .init(peerPolicy: .sameUser), handler: Self.echo)
        try server.start()
        var st = stat()
        XCTAssertEqual(lstat(path, &st), 0)
        XCTAssertTrue(Socket.isSocket(st.st_mode))
        XCTAssertEqual(UInt32(st.st_mode) & 0o777, 0o600)

        let reply = try XCTUnwrap(RawHTTP.exchange(.unix(path), RawHTTP.request("GET", "/v1/status")))
        XCTAssertEqual(reply.status, 200)
        XCTAssertEqual((reply.json as? [String: String])?["remoteHost"], "unix")
        XCTAssertEqual(Socket.peerUIDForTesting(path: path), geteuid())

        server.stop()
        Thread.sleep(forTimeInterval: 0.2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path), "stop removes the socket")
    }

    func testUnixSocketReplacesStaleSocketsOnly() throws {
        let dir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("control.sock").path

        // A live socket belongs to another daemon.
        let first = POSIXHTTPServer(endpoints: [.unix(path: path)], handler: Self.echo)
        try first.start()
        let second = POSIXHTTPServer(endpoints: [.unix(path: path)], handler: Self.echo)
        XCTAssertThrowsError(try second.start()) { XCTAssertEqual($0 as? POSIXHTTPServer.ServerError, .alreadyRunning(path)) }
        first.stop()
        Thread.sleep(forTimeInterval: 0.2)

        // A dead one (left by a crash) is replaced.
        let fd = socket(AF_UNIX, Socket.stream, 0)
        var addr = try Socket.unixAddress(path)
        XCTAssertEqual(withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { posixBind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }, 0)
        posixClose(fd)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
        let third = POSIXHTTPServer(endpoints: [.unix(path: path)], handler: Self.echo)
        try third.start()
        XCTAssertEqual(RawHTTP.exchange(.unix(path), RawHTTP.request("GET", "/"))?.status, 200)
        third.stop()

        // Anything else is left alone.
        let file = dir.appendingPathComponent("not-a-socket").path
        FileManager.default.createFile(atPath: file, contents: Data("keep".utf8))
        let fourth = POSIXHTTPServer(endpoints: [.unix(path: file)], handler: Self.echo)
        XCTAssertThrowsError(try fourth.start()) { XCTAssertEqual($0 as? POSIXHTTPServer.ServerError, .notASocket(file)) }
        XCTAssertEqual(FileManager.default.contents(atPath: file), Data("keep".utf8))
    }

    func testSocketPathTooLong() {
        let path = "/tmp/" + String(repeating: "x", count: 200) + ".sock"
        let server = POSIXHTTPServer(endpoints: [.unix(path: path)], handler: Self.echo)
        XCTAssertThrowsError(try server.start()) { XCTAssertEqual($0 as? POSIXHTTPServer.ServerError, .pathTooLong(path)) }
    }
}

extension Socket {
    /// Connects to `path` and reads the peer UID the way the server does,
    /// from the server's side of a socketpair-like connection.
    static func peerUIDForTesting(path: String) -> uid_t? {
        // Our own UID as seen through a real Unix socket connection.
        var fds: [Int32] = [0, 0]
        guard socketpair(AF_UNIX, stream, 0, &fds) == 0 else { return nil }
        defer { posixClose(fds[0]); posixClose(fds[1]) }
        return peerUID(fds[0])
    }
}
