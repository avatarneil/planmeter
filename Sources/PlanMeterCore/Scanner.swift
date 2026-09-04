import Foundation

/// Per-file parse output kept in the scan cache so warm refreshes only touch
/// files whose size or mtime changed.
public struct FileScanEntry: Codable, Sendable {
    public var size: Int64
    public var mtimeMs: Int64
    public var cells: [CellEntry]
    public var rateLimits: RateLimitSnapshot?
    public var malformed: Int

    public init(size: Int64, mtimeMs: Int64, cells: [CellEntry], rateLimits: RateLimitSnapshot?, malformed: Int) {
        self.size = size
        self.mtimeMs = mtimeMs
        self.cells = cells
        self.rateLimits = rateLimits
        self.malformed = malformed
    }
}

public struct CellEntry: Codable, Sendable {
    public var key: CellKey
    public var cell: Cell
}

struct ScanCacheDocument: Codable {
    var version: Int
    var files: [String: FileScanEntry]
}

/// Disk-backed cache of per-file parse results.
public actor ScanCache {
    /// Bump whenever parser output changes shape or semantics; cached entries
    /// are keyed only on file size and mtime, so stale logic would otherwise
    /// survive a rebuild.
    static let version = 3
    let url: URL
    var files: [String: FileScanEntry] = [:]
    var dirty = false

    public init(url: URL = AppPaths.supportDirectory().appendingPathComponent("scan-cache.json")) {
        self.url = url
    }

    public func load() {
        guard let data = try? Data(contentsOf: url) else { return }
        guard let doc = try? JSONDecoder().decode(ScanCacheDocument.self, from: data), doc.version == Self.version else { return }
        files = doc.files
    }

    public func entry(for path: String, size: Int64, mtimeMs: Int64) -> FileScanEntry? {
        guard let e = files[path], e.size == size, e.mtimeMs == mtimeMs else { return nil }
        return e
    }

    public func store(_ entry: FileScanEntry, for path: String) {
        files[path] = entry
        dirty = true
    }

    public func prune(keeping live: Set<String>) {
        let before = files.count
        files = files.filter { live.contains($0.key) }
        if files.count != before { dirty = true }
    }

    public func save() {
        guard dirty else { return }
        let doc = ScanCacheDocument(version: Self.version, files: files)
        guard let data = try? JSONEncoder().encode(doc) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
        dirty = false
    }
}

public struct ScanOutput: Sendable {
    public var cells: [CellKey: Cell]
    /// Latest Codex subscription-window reading per plan type.
    public var rateLimits: [String: RateLimitSnapshot]
    public var sources: [SourceReport]
    public var scannedAt: Date

    public init(cells: [CellKey: Cell] = [:], rateLimits: [String: RateLimitSnapshot] = [:], sources: [SourceReport] = [], scannedAt: Date = Date()) {
        self.cells = cells
        self.rateLimits = rateLimits
        self.sources = sources
        self.scannedAt = scannedAt
    }
}

struct TranscriptFile: Sendable {
    var path: String
    var size: Int64
    var mtimeMs: Int64
}

/// Walks provider transcript directories, parses what changed, and folds the
/// records into hourly cells keyed by account and model.
public enum Scanner {
    public static func scan(sources: [ScanSource], openCodeDatabase: String?, sinceMs: Int64, cache: ScanCache) async -> ScanOutput {
        var output = ScanOutput()
        var live: Set<String> = []

        for source in sources {
            let files = listFiles(root: source.rootDir, sinceMs: sinceMs, fileName: source.fileName)
            if files == nil {
                output.sources.append(SourceReport(provider: source.provider, path: source.rootDir, status: .missing, scannedFiles: 0, reusedFiles: 0, skippedFiles: 0, message: "Directory not found."))
                continue
            }
            var scanned = 0
            var reused = 0
            var skipped = 0
            var malformed = 0

            // Parse in parallel; the JSONL parsing dominates and is CPU bound.
            let entries: [(String, FileScanEntry, Bool)] = await withTaskGroup(of: (String, FileScanEntry, Bool)?.self) { group in
                var results: [(String, FileScanEntry, Bool)] = []
                var pending = files!.makeIterator()
                var inFlight = 0
                let width = max(2, min(8, ProcessInfo.processInfo.activeProcessorCount))
                func launch(_ file: TranscriptFile) {
                    group.addTask {
                        if let cached = await cache.entry(for: file.path, size: file.size, mtimeMs: file.mtimeMs) {
                            return (file.path, cached, true)
                        }
                        guard let entry = parseFile(file, source: source) else { return nil }
                        await cache.store(entry, for: file.path)
                        return (file.path, entry, false)
                    }
                }
                while inFlight < width, let next = pending.next() { launch(next); inFlight += 1 }
                while let result = await group.next() {
                    inFlight -= 1
                    if let result { results.append(result) } else { skipped += 1 }
                    if let next = pending.next() { launch(next); inFlight += 1 }
                }
                return results
            }

            for (path, entry, wasCached) in entries {
                live.insert(path)
                if wasCached { reused += 1 } else { scanned += 1 }
                malformed += entry.malformed
                for ce in entry.cells {
                    if var existing = output.cells[ce.key] {
                        existing.merge(ce.cell)
                        output.cells[ce.key] = existing
                    } else {
                        output.cells[ce.key] = ce.cell
                    }
                }
                if let limits = entry.rateLimits {
                    if let held = output.rateLimits[limits.planType], held.timestampMs >= limits.timestampMs { continue }
                    output.rateLimits[limits.planType] = limits
                }
            }
            let status: SourceStatus = (skipped > 0 || malformed > 0) ? .partial : .ok
            var message: String?
            if skipped > 0 { message = "\(skipped) files could not be read." }
            if malformed > 0 { message = (message.map { $0 + " " } ?? "") + "\(malformed) malformed lines." }
            output.sources.append(SourceReport(provider: source.provider, path: source.rootDir, status: status, scannedFiles: scanned, reusedFiles: reused, skippedFiles: skipped, message: message))
        }

        if let db = openCodeDatabase {
            let result = OpenCodeReader.read(databasePath: db, sinceMs: sinceMs)
            var seen: Set<String> = []
            for record in result.records {
                if let key = record.dedupeKey {
                    if seen.contains(key) { continue }
                    seen.insert(key)
                }
                let key = CellKey(hourStartMs: CellKey.hourStart(forMs: record.timestampMs), accountId: Account.openCodeLocalId, model: record.model)
                var cell = output.cells[key] ?? Cell()
                cell.add(record)
                output.cells[key] = cell
            }
            output.sources.append(SourceReport(provider: .opencode, path: db, status: result.status, scannedFiles: result.status == .ok || result.status == .partial ? 1 : 0, reusedFiles: 0, skippedFiles: 0, message: result.message))
        }

        await cache.prune(keeping: live)
        await cache.save()
        output.scannedAt = Date()
        return output
    }

    /// Lists `.jsonl` files under `root` modified at or after `sinceMs`.
    /// Returns nil when the root does not exist.
    static func listFiles(root: String, sinceMs: Int64, fileName: String?) -> [TranscriptFile]? {
        let fm = FileManager.default
        guard PathUtil.isDirectory(root) else { return nil }
        let rootURL = URL(fileURLWithPath: root)
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        guard let enumerator = fm.enumerator(at: rootURL, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else { return [] }
        var out: [TranscriptFile] = []
        for case let url as URL in enumerator {
            let name = url.lastPathComponent
            if let fileName {
                if name != fileName { continue }
            } else if !name.hasSuffix(".jsonl") {
                continue
            }
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            let mtimeMs = Int64(((values.contentModificationDate ?? .distantPast).timeIntervalSince1970 * 1000).rounded())
            if mtimeMs < sinceMs { continue }
            out.append(TranscriptFile(path: url.path, size: Int64(values.fileSize ?? 0), mtimeMs: mtimeMs))
        }
        return out
    }

    static func parseFile(_ file: TranscriptFile, source: ScanSource) -> FileScanEntry? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: file.path), options: [.mappedIfSafe]) else { return nil }
        var cells: [CellKey: Cell] = [:]
        var seenKeys: Set<String> = []
        var codexState = CodexScanState()
        // Parsers drop unreadable lines silently; the count is kept in the
        // entry so a future parser can start reporting it without a cache bump.
        let malformed = 0

        func fold(_ record: UsageRecord) {
            if let key = record.dedupeKey {
                if seenKeys.contains(key) { return }
                seenKeys.insert(key)
            }
            let accountId: String
            switch source.provider {
            case .codex:
                accountId = Account.codexId(planType: record.planType ?? "unknown")
            default:
                accountId = source.fixedAccountId ?? Account.placeholder(id: "\(source.provider.rawValue):unattributed").id
            }
            let key = CellKey(hourStartMs: CellKey.hourStart(forMs: record.timestampMs), accountId: accountId, model: record.model)
            var cell = cells[key] ?? Cell()
            cell.add(record)
            cells[key] = cell
        }

        data.forEachLine { line in
            switch source.provider {
            case .claude:
                if let r = ClaudeParser.parse(line: line) { fold(r) }
            case .codex:
                if let r = CodexParser.parse(line: line, state: &codexState) { fold(r) }
            case .grok:
                for r in GrokParser.parse(line: line) { fold(r) }
            case .opencode:
                break
            }
        }

        return FileScanEntry(
            size: file.size,
            mtimeMs: file.mtimeMs,
            cells: cells.map { CellEntry(key: $0.key, cell: $0.value) },
            rateLimits: codexState.latestRateLimits,
            malformed: malformed
        )
    }
}
