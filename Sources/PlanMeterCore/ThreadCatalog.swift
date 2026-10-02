import Foundation
import SQLite3

/// Enrich session IDs using explicit provider mappings, never title similarity.
public enum ThreadCatalog {
    public static func load(discovery: Discovery, t3Database: String = T3Settings.defaultHome().appendingPathComponent("userdata/state.sqlite").path) -> [String: ThreadLink] {
        var catalog: [String: ThreadLink] = [:]
        let homes = Set(discovery.sources.filter { $0.provider == .codex }.map {
            URL(fileURLWithPath: $0.rootDir).deletingLastPathComponent().path
        })
        for home in homes {
            read(path: home + "/state_5.sqlite", sql: "SELECT id, title FROM threads") { columns in
                guard columns.count == 2, !columns[0].isEmpty, !columns[1].isEmpty else { return }
                catalog["codex:\(columns[0])"] = ThreadLink(title: columns[1], chatId: nil)
            }
        }
        read(path: t3Database, sql: """
            SELECT s.provider_name, s.provider_session_id, s.provider_thread_id, t.thread_id, t.title
            FROM projection_thread_sessions s JOIN projection_threads t ON t.thread_id = s.thread_id
            """) { columns in
            guard columns.count == 5, let provider = ProviderKind.from(t3Driver: columns[0]) else { return }
            for session in Set([columns[1], columns[2]]) where !session.isEmpty {
                catalog["\(provider.rawValue):\(session)"] = ThreadLink(title: columns[4], chatId: columns[3])
            }
        }
        // Current T3 versions keep the provider resume ID in the runtime
        // cursor rather than projection_thread_sessions.
        read(path: t3Database, sql: """
            SELECT s.provider_name, s.resume_cursor_json, t.thread_id, t.title
            FROM provider_session_runtime s JOIN projection_threads t ON t.thread_id = s.thread_id
            """) { columns in
            guard columns.count == 4, let provider = ProviderKind.from(t3Driver: columns[0]),
                  let cursor = JSON.object(Data(columns[1].utf8)) else { return }
            for key in ["threadId", "sessionId"] {
                if let session = JSON.string(cursor[key]) {
                    catalog["\(provider.rawValue):\(session)"] = ThreadLink(title: columns[3], chatId: columns[2])
                }
            }
        }
        return catalog
    }

    public static func link(_ rows: [ThreadSpend], catalog: [String: ThreadLink]) -> [ThreadSpend] {
        rows.map { row in
            var row = row
            if let link = catalog["\(row.provider.rawValue):\(row.sessionId)"] {
                row.title = link.title
                row.chatId = link.chatId
            }
            return row
        }
    }

    private static func read(path: String, sql: String, row: ([String]) -> Void) {
        guard FileManager.default.fileExists(atPath: path) else { return }
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK, let db else {
            if let db { sqlite3_close(db) }
            return
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 1000)
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { return }
        defer { sqlite3_finalize(statement) }
        while sqlite3_step(statement) == SQLITE_ROW {
            row((0..<sqlite3_column_count(statement)).map { column in
                sqlite3_column_text(statement, column).map { String(cString: $0) } ?? ""
            })
        }
    }
}
