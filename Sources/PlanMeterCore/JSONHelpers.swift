import Foundation

/// Tiny helpers over `JSONSerialization` output. Transcripts are heterogeneous
/// JSONL, so typed `Codable` structs would need a schema per provider version.
enum JSON {
    static func object(_ data: Data) -> [String: Any]? {
        guard let parsed = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else { return nil }
        return parsed as? [String: Any]
    }

    static func object(_ value: Any?) -> [String: Any]? { value as? [String: Any] }

    static func string(_ value: Any?) -> String? {
        guard let s = value as? String, !s.isEmpty else { return nil }
        return s
    }

    /// Positive finite integer, else 0 (matches T3's `int()` helper).
    static func positiveInt(_ value: Any?) -> Int {
        if let n = value as? Int { return n > 0 ? n : 0 }
        if let n = value as? Double, n.isFinite { return n > 0 ? Int(n) : 0 }
        if let n = value as? NSNumber { return n.intValue > 0 ? n.intValue : 0 }
        return 0
    }

    static func double(_ value: Any?) -> Double? {
        if let n = value as? Double, n.isFinite { return n }
        if let n = value as? Int { return Double(n) }
        if let n = value as? NSNumber, n.doubleValue.isFinite { return n.doubleValue }
        return nil
    }

    static func bool(_ value: Any?) -> Bool? {
        if let b = value as? Bool { return b }
        return nil
    }

    static func timestampMs(_ value: Any?) -> Int64? {
        guard let s = value as? String else { return nil }
        return ISO8601.parseMs(s)
    }
}

enum ISO8601 {
    nonisolated(unsafe) private static let fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    nonisolated(unsafe) private static let plain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static let lock = NSLock()

    static func parseMs(_ s: String) -> Int64? {
        lock.lock()
        defer { lock.unlock() }
        let date = fractional.date(from: s) ?? plain.date(from: s)
        guard let date else { return nil }
        return Int64((date.timeIntervalSince1970 * 1000).rounded())
    }
}

extension Data {
    /// Splits newline-delimited data into line slices without copying.
    func forEachLine(_ body: (Data) -> Void) {
        var start = startIndex
        while start < endIndex {
            let end = self[start...].firstIndex(of: 0x0A) ?? endIndex
            var lineEnd = end
            if lineEnd > start, self[lineEnd - 1] == 0x0D { lineEnd -= 1 }
            if lineEnd > start { body(self[start..<lineEnd]) }
            start = end == endIndex ? endIndex : end + 1
        }
    }
}
