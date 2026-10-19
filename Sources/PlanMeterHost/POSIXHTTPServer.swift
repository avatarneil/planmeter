import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// Just enough HTTP/1.1 over POSIX sockets, for hosts without
/// Network.framework (Linux) and for the daemon's local control socket.
///
/// Listens on TCP addresses bound explicitly (never the wildcard) and on Unix
/// domain sockets. Same limits as the Mac's listener: one request per
/// connection, 16 KiB of headers, a 1 MiB body, and 20 seconds to deliver the
/// request. Unix sockets are created `0600`, and with `.sameUser` the peer's
/// credentials (`SO_PEERCRED` on Linux, `getpeereid` elsewhere) must match
/// this process's effective UID. `stop()` returns once the listening sockets
/// are closed, so the same address can be bound again straight away.
public final class POSIXHTTPServer: @unchecked Sendable {
    public enum Endpoint: Sendable, Hashable, CustomStringConvertible {
        case tcp(host: String, port: UInt16)
        case unix(path: String)

        public var description: String {
            switch self {
            case .tcp(let host, let port): return host.contains(":") ? "[\(host)]:\(port)" : "\(host):\(port)"
            case .unix(let path): return path
            }
        }
    }

    public enum PeerPolicy: Sendable {
        case any
        /// Unix sockets: refuse peers running as a different user.
        case sameUser
    }

    public struct Options: Sendable {
        public var maxHeaderBytes = HTTPLimits.maxHeaderBytes
        public var maxBodyBytes = HTTPLimits.maxBodyBytes
        public var connectionTimeout = HTTPLimits.connectionTimeout
        /// Further connections are closed immediately while this many are open.
        public var maxConnections = 32
        /// The same, per remote TCP address, so one peer cannot hold every
        /// slot. Loopback is exempt: Tailscale Serve proxies every HTTPS
        /// client from there.
        public var maxConnectionsPerPeer = 8
        /// Tests turn this off to exercise the per-peer cap over loopback.
        var peerCapExemptsLoopback = true
        public var peerPolicy: PeerPolicy = .any

        public init(peerPolicy: PeerPolicy = .any) {
            self.peerPolicy = peerPolicy
        }
    }

    public enum ServerError: Error, LocalizedError, Equatable {
        case invalidAddress(String)
        case system(String, Int32)
        case pathTooLong(String)
        case alreadyRunning(String)
        case notASocket(String)

        public var errorDescription: String? {
            switch self {
            case .invalidAddress(let a): return "Not a numeric IP address: \(a)"
            case .system(let call, let code): return "\(call) failed: \(String(cString: strerror(code)))"
            case .pathTooLong(let p): return "Socket path is too long: \(p)"
            case .alreadyRunning(let p): return "Another process is already listening on \(p)"
            case .notASocket(let p): return "Refusing to replace \(p): it exists and is not a socket"
            }
        }
    }

    public let endpoints: [Endpoint]
    public let options: Options
    private let handler: HTTPHandler
    private let lock = NSLock()
    private var listeners: [Listener] = []
    private var activeConnections = 0
    private var connectionsByPeer: [String: Int] = [:]
    /// (endpoint, state): "listening", "stopped", or "failed: …".
    public var onStateChange: (@Sendable (String, String) -> Void)?
    /// Diagnostics such as refused peers.
    public var onLog: (@Sendable (String) -> Void)?

    public init(endpoints: [Endpoint], options: Options = Options(), handler: @escaping HTTPHandler) {
        self.endpoints = endpoints
        self.options = options
        self.handler = handler
    }

    deinit { stop() }

    /// Binds every endpoint, or none: a failure closes what was already bound.
    public func start() throws {
        var started: [Listener] = []
        do {
            for endpoint in endpoints {
                started.append(try Listener.open(endpoint))
            }
        } catch {
            for listener in started { listener.close() }
            if let first = endpoints.first { onStateChange?(first.description, "failed: \(error.localizedDescription)") }
            throw error
        }
        lock.lock()
        listeners.append(contentsOf: started)
        lock.unlock()
        for listener in started {
            let thread = Thread { [weak self] in
                if let self { self.acceptLoop(listener) } else { listener.close() }
                listener.markExited()
            }
            thread.name = "planmeter.http.accept"
            thread.start()
            onStateChange?(listener.endpoint.description, "listening")
        }
    }

    /// Closes every listening socket and waits for the accept threads to let
    /// go of them; connections already accepted finish on their own.
    public func stop() {
        lock.lock()
        let current = listeners
        listeners.removeAll()
        lock.unlock()
        for listener in current { listener.wake() }
        for listener in current {
            if !listener.waitForExit(timeout: Self.stopTimeout) {
                onLog?("\(listener.endpoint): accept thread did not stop within \(Self.stopTimeout) s")
            }
            onStateChange?(listener.endpoint.description, "stopped")
        }
    }

    /// The accept thread only has to notice the wake pipe; this bound is for
    /// a thread that never got scheduled, not a normal stop.
    static let stopTimeout: TimeInterval = 5

    /// The bound TCP port for an endpoint, useful after binding port 0.
    public func boundPort(for endpoint: Endpoint) -> UInt16? {
        lock.lock(); defer { lock.unlock() }
        return listeners.first { $0.endpoint == endpoint }?.boundPort
    }

    // MARK: Accepting

    private func acceptLoop(_ listener: Listener) {
        defer {
            lock.lock()
            listeners.removeAll { $0 === listener }
            lock.unlock()
            listener.close()
        }
        while true {
            var fds = [
                pollfd(fd: listener.fd, events: Int16(POLLIN), revents: 0),
                pollfd(fd: listener.wakeRead, events: Int16(POLLIN), revents: 0),
            ]
            let ready = poll(&fds, 2, -1)
            if ready < 0 {
                if errno == EINTR { continue }
                return
            }
            if fds[1].revents != 0 { return }
            guard fds[0].revents & Int16(POLLIN) != 0 else {
                if fds[0].revents & Int16(POLLERR | POLLHUP | POLLNVAL) != 0 { return }
                continue
            }
            var storage = sockaddr_storage()
            var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
            let client = withUnsafeMutablePointer(to: &storage) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { accept(listener.fd, $0, &length) }
            }
            if client < 0 {
                if errno == EMFILE || errno == ENFILE { usleep(100_000) }
                continue
            }
            let remoteHost: String
            if case .unix = listener.endpoint {
                remoteHost = "unix"
            } else {
                remoteHost = Self.describe(&storage)
            }
            serve(client, endpoint: listener.endpoint, remoteHost: remoteHost)
        }
    }

    private func serve(_ fd: Int32, endpoint: Endpoint, remoteHost: String) {
        // Unix sockets have one trusted peer; loopback may be Tailscale Serve.
        var peer: String?
        if case .tcp = endpoint, !(options.peerCapExemptsLoopback && TailscaleInfo.isLoopback(remoteHost)) { peer = remoteHost }
        lock.lock()
        let perPeer = peer.map { connectionsByPeer[$0, default: 0] } ?? 0
        if activeConnections >= options.maxConnections || perPeer >= options.maxConnectionsPerPeer {
            lock.unlock()
            posixClose(fd)
            onLog?("\(endpoint): too many connections; dropped one from \(remoteHost)")
            return
        }
        activeConnections += 1
        if let peer { connectionsByPeer[peer] = perPeer + 1 }
        lock.unlock()
        let connection = Connection(fd: fd, peer: peer)
        Socket.configureAccepted(fd)
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            if case .unix = endpoint, options.peerPolicy == .sameUser {
                let uid = Socket.peerUID(fd)
                guard let uid, uid == geteuid() else {
                    onLog?("\(endpoint): refused peer uid \(uid.map(String.init) ?? "unknown")")
                    finish(connection, response: .error(403, "forbidden"))
                    return
                }
            }
            readRequest(connection, endpoint: endpoint, remoteHost: remoteHost)
        }
    }

    /// An accepted socket and the peer it counts against.
    private struct Connection: Sendable {
        let fd: Int32
        let peer: String?
    }

    private func readRequest(_ connection: Connection, endpoint: Endpoint, remoteHost: String) {
        let fd = connection.fd
        let deadline = Date().addingTimeInterval(options.connectionTimeout)
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 65536)
        var isComplete = false
        while true {
            switch HTTPRequestParser.parse(buffer, isComplete: isComplete, remoteHost: remoteHost,
                                           maxHeaderBytes: options.maxHeaderBytes, maxBodyBytes: options.maxBodyBytes) {
            case .request(let request):
                let handler = self.handler
                Task {
                    let response = await handler(request)
                    // Write from a dispatch thread: a slow reader must never
                    // block the cooperative pool.
                    DispatchQueue.global(qos: .userInitiated).async { self.finish(connection, response: response) }
                }
                return
            case .failure(let status, let message):
                finish(connection, response: .error(status, message))
                return
            case .close:
                finish(connection, response: nil)
                return
            case .incomplete:
                guard Socket.wait(fd, for: Int16(POLLIN), until: deadline) else {
                    // Same as the Mac listener: a request that misses the
                    // deadline is dropped without a reply.
                    finish(connection, response: nil)
                    return
                }
                let count = chunk.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
                if count > 0 {
                    buffer.append(contentsOf: chunk[0..<count])
                } else if count == 0 {
                    isComplete = true
                } else if errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR {
                    finish(connection, response: nil)
                    return
                }
            }
        }
    }

    private func finish(_ connection: Connection, response: HTTPResponse?) {
        let fd = connection.fd
        if let response {
            Socket.writeAll(fd, response.serialized(), until: Date().addingTimeInterval(options.connectionTimeout))
        }
        shutdown(fd, Int32(SHUT_WR))
        posixClose(fd)
        lock.lock()
        activeConnections -= 1
        if let peer = connection.peer {
            let remaining = connectionsByPeer[peer, default: 1] - 1
            connectionsByPeer[peer] = remaining > 0 ? remaining : nil
        }
        lock.unlock()
    }

    static func describe(_ storage: inout sockaddr_storage) -> String {
        let length = Int32(storage.ss_family) == AF_INET6 ? MemoryLayout<sockaddr_in6>.size : MemoryLayout<sockaddr_in>.size
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let ok = withUnsafePointer(to: &storage) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getnameinfo($0, socklen_t(length), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0
            }
        }
        guard ok else { return "unknown" }
        let s = String(cString: host)
        return s.split(separator: "%").first.map(String.init) ?? s
    }
}

// MARK: - Listening sockets

private final class Listener: @unchecked Sendable {
    let endpoint: POSIXHTTPServer.Endpoint
    let fd: Int32
    let wakeRead: Int32
    let wakeWrite: Int32
    let boundPort: UInt16?
    /// Device and inode of the socket file we created, so stopping never
    /// unlinks a socket another process has since put in its place.
    let socketIdentity: (dev: UInt64, ino: UInt64)?
    private let closeLock = NSLock()
    private var closed = false
    private let exited = DispatchSemaphore(value: 0)

    init(endpoint: POSIXHTTPServer.Endpoint, fd: Int32, boundPort: UInt16?, socketIdentity: (dev: UInt64, ino: UInt64)?) throws {
        var pipeFDs: [Int32] = [0, 0]
        guard pipe(&pipeFDs) == 0 else { throw POSIXHTTPServer.ServerError.system("pipe", errno) }
        Socket.setCloseOnExec(pipeFDs[0])
        Socket.setCloseOnExec(pipeFDs[1])
        self.endpoint = endpoint
        self.fd = fd
        self.wakeRead = pipeFDs[0]
        self.wakeWrite = pipeFDs[1]
        self.boundPort = boundPort
        self.socketIdentity = socketIdentity
    }

    static func open(_ endpoint: POSIXHTTPServer.Endpoint) throws -> Listener {
        switch endpoint {
        case .tcp(let host, let port):
            let (fd, bound) = try Socket.listenTCP(host: host, port: port)
            do { return try Listener(endpoint: endpoint, fd: fd, boundPort: bound, socketIdentity: nil) } catch {
                posixClose(fd); throw error
            }
        case .unix(let path):
            let (fd, identity) = try Socket.listenUnix(path: path)
            do { return try Listener(endpoint: endpoint, fd: fd, boundPort: nil, socketIdentity: identity) } catch {
                posixClose(fd); unlink(path); throw error
            }
        }
    }

    /// Asks the accept loop to return. A no-op once closed: the pipe's fd
    /// number may already belong to something else.
    func wake() {
        closeLock.lock()
        defer { closeLock.unlock() }
        guard !closed else { return }
        var byte: UInt8 = 1
        _ = write(wakeWrite, &byte, 1)
    }

    /// Called by the accept thread after `close()`.
    func markExited() { exited.signal() }

    func waitForExit(timeout: TimeInterval) -> Bool {
        exited.wait(timeout: .now() + timeout) == .success
    }

    func close() {
        closeLock.lock()
        defer { closeLock.unlock() }
        guard !closed else { return }
        closed = true
        posixClose(fd)
        posixClose(wakeRead)
        posixClose(wakeWrite)
        if case .unix(let path) = endpoint, let socketIdentity, let current = Socket.identity(path),
           current.dev == socketIdentity.dev, current.ino == socketIdentity.ino {
            unlink(path)
        }
    }
}

// MARK: - Socket helpers

/// `close(2)`, spelled out because `Listener.close()` shadows it.
@inline(__always) func posixClose(_ fd: Int32) {
    #if canImport(Darwin)
    _ = Darwin.close(fd)
    #elseif canImport(Glibc)
    _ = Glibc.close(fd)
    #elseif canImport(Musl)
    _ = Musl.close(fd)
    #endif
}

enum Socket {
    #if canImport(Darwin)
    static let stream = SOCK_STREAM
    static let sendFlags: Int32 = 0
    #else
    static let stream = Int32(SOCK_STREAM.rawValue)
    static let sendFlags = Int32(MSG_NOSIGNAL)
    #endif

    static func setCloseOnExec(_ fd: Int32) {
        _ = fcntl(fd, F_SETFD, fcntl(fd, F_GETFD) | FD_CLOEXEC)
    }

    static func setNonBlocking(_ fd: Int32) {
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
    }

    static func configureAccepted(_ fd: Int32) {
        setCloseOnExec(fd)
        setNonBlocking(fd)
        #if canImport(Darwin)
        var on: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        #endif
    }

    static func listenTCP(host: String, port: UInt16) throws -> (fd: Int32, port: UInt16) {
        var v4 = in_addr()
        var v6 = in6_addr()
        let family: Int32
        if inet_pton(AF_INET, host, &v4) == 1 {
            family = AF_INET
        } else if inet_pton(AF_INET6, host, &v6) == 1 {
            family = AF_INET6
        } else {
            throw POSIXHTTPServer.ServerError.invalidAddress(host)
        }
        let fd = socket(family, stream, 0)
        guard fd >= 0 else { throw POSIXHTTPServer.ServerError.system("socket", errno) }
        setCloseOnExec(fd)
        var on: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, socklen_t(MemoryLayout<Int32>.size))
        let result: Int32
        if family == AF_INET {
            var addr = sockaddr_in()
            #if canImport(Darwin)
            addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            #endif
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = port.bigEndian
            addr.sin_addr = v4
            result = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
        } else {
            _ = setsockopt(fd, Int32(IPPROTO_IPV6), IPV6_V6ONLY, &on, socklen_t(MemoryLayout<Int32>.size))
            var addr = sockaddr_in6()
            #if canImport(Darwin)
            addr.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            #endif
            addr.sin6_family = sa_family_t(AF_INET6)
            addr.sin6_port = port.bigEndian
            addr.sin6_addr = v6
            result = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) }
            }
        }
        guard result == 0 else {
            let code = errno
            posixClose(fd)
            throw POSIXHTTPServer.ServerError.system("bind \(host):\(port)", code)
        }
        guard listen(fd, 64) == 0 else {
            let code = errno
            posixClose(fd)
            throw POSIXHTTPServer.ServerError.system("listen", code)
        }
        setNonBlocking(fd)
        return (fd, boundPort(fd) ?? port)
    }

    static func boundPort(_ fd: Int32) -> UInt16? {
        var storage = sockaddr_storage()
        var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
        let ok = withUnsafeMutablePointer(to: &storage) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) == 0 }
        }
        guard ok else { return nil }
        if Int32(storage.ss_family) == AF_INET6 {
            return withUnsafePointer(to: &storage) { $0.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { UInt16(bigEndian: $0.pointee.sin6_port) } }
        }
        return withUnsafePointer(to: &storage) { $0.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt16(bigEndian: $0.pointee.sin_port) } }
    }

    static func unixAddress(_ path: String) throws -> sockaddr_un {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        guard !bytes.isEmpty, bytes.count < capacity else { throw POSIXHTTPServer.ServerError.pathTooLong(path) }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        #if canImport(Darwin)
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        #endif
        return addr
    }

    static func identity(_ path: String) -> (dev: UInt64, ino: UInt64)? {
        var st = stat()
        guard lstat(path, &st) == 0 else { return nil }
        return (UInt64(bitPattern: Int64(st.st_dev)), UInt64(st.st_ino))
    }

    static func isSocket(_ mode: mode_t) -> Bool { (UInt32(mode) & UInt32(S_IFMT)) == UInt32(S_IFSOCK) }

    /// True when something accepts connections at `path`.
    static func isLive(_ path: String) -> Bool {
        guard var addr = try? unixAddress(path) else { return false }
        let fd = socket(AF_UNIX, stream, 0)
        guard fd >= 0 else { return false }
        defer { posixClose(fd) }
        return withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0 }
        }
    }

    static func listenUnix(path: String) throws -> (fd: Int32, identity: (dev: UInt64, ino: UInt64)?) {
        var addr = try unixAddress(path)
        var st = stat()
        if lstat(path, &st) == 0 {
            guard isSocket(st.st_mode) else { throw POSIXHTTPServer.ServerError.notASocket(path) }
            if isLive(path) { throw POSIXHTTPServer.ServerError.alreadyRunning(path) }
            unlink(path)
        }
        let fd = socket(AF_UNIX, stream, 0)
        guard fd >= 0 else { throw POSIXHTTPServer.ServerError.system("socket", errno) }
        setCloseOnExec(fd)
        // Create the socket file 0600 from the start rather than chmod-ing it
        // after a window in which it is reachable with default permissions.
        let previousMask = umask(0o177)
        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        let bindErrno = errno
        umask(previousMask)
        guard result == 0 else {
            posixClose(fd)
            throw POSIXHTTPServer.ServerError.system("bind \(path)", bindErrno)
        }
        chmod(path, 0o600)
        guard listen(fd, 16) == 0 else {
            let code = errno
            posixClose(fd)
            unlink(path)
            throw POSIXHTTPServer.ServerError.system("listen", code)
        }
        setNonBlocking(fd)
        return (fd, identity(path))
    }

    /// The peer's effective UID on a connected Unix socket.
    static func peerUID(_ fd: Int32) -> uid_t? {
        #if os(Linux)
        // struct ucred { pid_t pid; uid_t uid; gid_t gid; }
        struct PeerCredentials { var pid: Int32 = 0; var uid: UInt32 = 0; var gid: UInt32 = 0 }
        var credentials = PeerCredentials()
        var length = socklen_t(MemoryLayout<PeerCredentials>.size)
        guard getsockopt(fd, SOL_SOCKET, SO_PEERCRED, &credentials, &length) == 0,
              length == socklen_t(MemoryLayout<PeerCredentials>.size) else { return nil }
        return uid_t(credentials.uid)
        #else
        var uid = uid_t()
        var gid = gid_t()
        guard getpeereid(fd, &uid, &gid) == 0 else { return nil }
        return uid
        #endif
    }

    /// Waits until `fd` is ready for `events` or the deadline passes.
    static func wait(_ fd: Int32, for events: Int16, until deadline: Date) -> Bool {
        while true {
            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 { return false }
            var pfd = pollfd(fd: fd, events: events, revents: 0)
            let ready = poll(&pfd, 1, Int32(min(remaining * 1000, Double(Int32.max)).rounded(.up)))
            if ready > 0 { return true }
            if ready == 0 { return false }
            if errno != EINTR { return false }
        }
    }

    static func writeAll(_ fd: Int32, _ data: Data, until deadline: Date) {
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < raw.count {
                let sent = send(fd, base + offset, raw.count - offset, sendFlags)
                if sent > 0 {
                    offset += sent
                } else if sent < 0 && (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR) {
                    guard wait(fd, for: Int16(POLLOUT), until: deadline) else { return }
                } else {
                    return
                }
            }
        }
    }
}
