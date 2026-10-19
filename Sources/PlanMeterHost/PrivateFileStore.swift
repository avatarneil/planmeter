import Foundation
import PlanMeterRemote
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// A `SecretStore` of 0600 files in a 0700 directory, for the daemon's server
/// key and paired devices.
///
/// Unlike `FileSecretStore` it never asks for a data-protection class (which
/// unsigned command-line tools cannot get on macOS, and Linux does not have),
/// and each file is created 0600 before any secret is written to it, then
/// renamed into place, so there is no moment when it is readable by others.
public struct PrivateFileStore: SecretStore {
    public let directory: URL

    public init(directory: URL) { self.directory = directory }

    public enum StoreError: Error, LocalizedError {
        case invalidKey(String)
        case io(String, Int32)

        public var errorDescription: String? {
            switch self {
            case .invalidKey(let key): return "Invalid secret name: \(key)"
            case .io(let what, let code): return "\(what): \(String(cString: strerror(code)))"
            }
        }
    }

    func url(_ key: String) throws -> URL {
        guard !key.isEmpty, !key.contains("/"), key != ".", key != ".." else { throw StoreError.invalidKey(key) }
        return directory.appendingPathComponent(key)
    }

    public func read(_ key: String) throws -> Data? {
        let file = try url(key)
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        return try Data(contentsOf: file)
    }

    public func write(_ key: String, _ data: Data) throws {
        let file = try url(key)
        try HostPaths.preparePrivateDirectory(directory.path, tighten: true)
        let temporary = directory.appendingPathComponent(".\(key).\(UUID().uuidString).tmp")
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard fd >= 0 else { throw StoreError.io("create \(temporary.path)", errno) }
        var failure: StoreError?
        data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let written = posixWrite(fd, raw.baseAddress! + offset, raw.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    failure = .io("write \(temporary.path)", errno)
                    return
                }
                offset += written
            }
        }
        if failure == nil, fsync(fd) != 0 { failure = .io("fsync \(temporary.path)", errno) }
        posixClose(fd)
        if failure == nil, rename(temporary.path, file.path) != 0 { failure = .io("rename to \(file.path)", errno) }
        if let failure {
            unlink(temporary.path)
            throw failure
        }
    }

    public func delete(_ key: String) throws {
        let file = try url(key)
        if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
    }
}

@inline(__always) private func posixWrite(_ fd: Int32, _ buffer: UnsafeRawPointer, _ count: Int) -> Int {
    #if canImport(Darwin)
    return Darwin.write(fd, buffer, count)
    #elseif canImport(Glibc)
    return Glibc.write(fd, buffer, count)
    #else
    return Musl.write(fd, buffer, count)
    #endif
}
