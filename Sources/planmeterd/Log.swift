import Foundation

/// Line-oriented logging to stderr. Under systemd (`JOURNAL_STREAM` set) each
/// line carries a syslog priority prefix that journald understands; in a
/// terminal it carries a timestamp instead.
enum Log {
    enum Level: Int {
        case error = 3
        case warning = 4
        case info = 6
        case debug = 7
    }

    nonisolated(unsafe) static var verbose = false
    static let toJournal = ProcessInfo.processInfo.environment["JOURNAL_STREAM"] != nil
    private static let lock = NSLock()

    static func error(_ message: String) { write(.error, message) }
    static func warning(_ message: String) { write(.warning, message) }
    static func info(_ message: String) { write(.info, message) }
    static func debug(_ message: String) { if verbose { write(.debug, message) } }

    static func write(_ level: Level, _ message: String) {
        let line: String
        if toJournal {
            line = "<\(level.rawValue)>\(message)\n"
        } else {
            let stamp = ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withInternetDateTime])
            let tag = level == .error ? "error: " : level == .warning ? "warning: " : ""
            line = "\(stamp) planmeterd: \(tag)\(message)\n"
        }
        lock.lock()
        FileHandle.standardError.write(Data(line.utf8))
        lock.unlock()
    }
}
