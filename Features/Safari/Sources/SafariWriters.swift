import CryptoKit
import Foundation
import SQLite3

/// A page visited here, for Safari's history.
nonisolated struct SafariVisit: Equatable, Sendable {
    var url: URL
    var title: String
    var date: Date
}

/// Writing into Safari's history the way the history service does (macOS 27, its own statements), so Safari's history
/// sync uploads it with its own visits. Each write is one transaction that waits for Safari.
nonisolated extension SafariStore {
    // MARK: Tab Groups (written through WebBookmarks: SafariTabGroupWriter)

    /// A Tab Group's tabs as rows (by the group's `external_uuid`), from the live database.
    static func groupRows(in file: URL, groupID: String) throws -> [SafariBookmark] {
        let id = groupID.replacingOccurrences(of: "'", with: "''")
        return try read(file) { db in
            var tabs: [SafariBookmark] = []
            rows(db, """
            SELECT t.external_uuid, t.title, t.url, t.server_id FROM bookmarks t JOIN bookmarks g ON t.parent = g.id
            WHERE g.external_uuid = '\(id)' AND t.type = 0 AND t.deleted = 0
            """) { s in
                guard let url = URL(string: text(s, 2)) else { return }
                tabs.append(SafariBookmark(id: text(s, 0), title: text(s, 1), url: url,
                                           serverID: sqlite3_column_type(s, 3) == SQLITE_NULL ? nil : text(s, 3)))
            }
            return tabs
        }
    }

    /// A tab's id in the Tab Group when it writes the row: the same tab at the same page gets the same one.
    static func tabRowID(tab: UUID, url: URL) -> String {
        var bytes = Array(SHA256.hash(data: Data("\(tab.uuidString)|\(url.absoluteString)".utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50  // version 5 (name-based)
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15])).uuidString
    }

    // MARK: History

    /// Adds visits as Safari records its own (origin 0, this generation), which its history sync uploads. Counts and scores
    /// are left for Safari to recompute (`should_recompute_derived_visit_counts`); `domain_expansion` needs Safari's own
    /// SQL function, so new items have none.
    /// Returns the generation the visits got: they're uploaded once `historySyncedGeneration()` reaches it.
    @discardableResult
    func addVisits(_ visits: [SafariVisit]) throws -> Int {
        guard !visits.isEmpty else { return 0 }
        var written = 0
        try Self.transaction(historyFile) { db in
            let generation = try Self.int(db, "SELECT value FROM metadata WHERE key = 'current_generation'")
            written = generation
            for visit in visits {
                let url = visit.url.absoluteString
                let item: Int
                if let found = try? Self.int(db, "SELECT id FROM history_items WHERE url = ? LIMIT 1", url) {
                    try Self.run(db, "UPDATE history_items SET visit_count = visit_count + 1, should_recompute_derived_visit_counts = 1 WHERE id = ?", found)
                    item = found
                } else {
                    try Self.run(db, """
                    INSERT INTO history_items (url, visit_count, visit_count_score, daily_visit_counts, weekly_visit_counts,
                        should_recompute_derived_visit_counts, status_code, domain_expansion)
                    VALUES (?, 1, 100, ?, NULL, 1, 0, NULL)
                    """, url, withUnsafeBytes(of: Int32(100).littleEndian) { Data($0) })
                    item = Int(sqlite3_last_insert_rowid(db))
                }
                try Self.run(db, """
                INSERT INTO history_visits (history_item, visit_time, title, load_successful, http_non_get, origin, generation, attributes, score)
                VALUES (?, ?, ?, 1, 0, 0, ?, 0, 100)
                """, item, visit.date.timeIntervalSinceReferenceDate, visit.title, generation)
            }
        }
        return written
    }

    // MARK: Waiting for iCloud

    /// The last history generation Safari uploaded.
    func historySyncedGeneration() throws -> Int {
        try Self.read(historyFile) { db in try Self.int(db, "SELECT value FROM metadata WHERE key = 'last_synced_generation'") }
    }

    /// Rows of the Tab Group `title` the agent hasn't uploaded yet (new, changed or tombstoned).
    func tabGroupPending(title: String) throws -> Bool {
        guard let file = tabGroupsFile, FileManager.default.fileExists(atPath: file.path) else { return false }
        let name = title.replacingOccurrences(of: "'", with: "''")
        return try Self.read(file) { db in
            try Self.int(db, """
            SELECT count(*) FROM bookmarks WHERE syncable = 1 AND (added = 1 OR deleted = 1 OR modified_attributes != 0) AND (id IN (SELECT id FROM bookmarks WHERE title = '\(name)' AND type = 1 AND subtype = 0)
                OR parent IN (SELECT id FROM bookmarks WHERE title = '\(name)' AND type = 1 AND subtype = 0))
            """) > 0
        }
    }

    /// A read on Safari's live database (WAL: readers don't block it).
    static func read<T>(_ file: URL, _ body: (OpaquePointer?) throws -> T) throws -> T {
        var db: OpaquePointer?
        guard sqlite3_open_v2(file.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { sqlite3_close(db); throw StoreError.noAccess }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 5000)
        return try body(db)
    }

    // MARK: SQLite, writing

    /// One transaction on Safari's live database; waits for Safari's own writes, rolls back on failure.
    static func transaction(_ file: URL, _ body: (OpaquePointer?) throws -> Void) throws {
        guard FileManager.default.fileExists(atPath: file.path) else { throw StoreError.notFound }
        var db: OpaquePointer?
        guard sqlite3_open_v2(file.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else { sqlite3_close(db); throw StoreError.noAccess }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 5000)
        try run(db, "BEGIN IMMEDIATE")
        do {
            try body(db)
            try run(db, "COMMIT")
        } catch {
            _ = sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
            throw error
        }
    }

    static func run(_ db: OpaquePointer?, _ sql: String, _ values: Any?...) throws {
        let stmt = try prepare(db, sql, values)
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw StoreError.malformed }
    }

    static func int(_ db: OpaquePointer?, _ sql: String, _ values: Any?...) throws -> Int {
        let stmt = try prepare(db, sql, values)
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW, sqlite3_column_type(stmt, 0) != SQLITE_NULL else { throw StoreError.notFound }
        return Int(sqlite3_column_int64(stmt, 0))
    }

    private static func prepare(_ db: OpaquePointer?, _ sql: String, _ values: [Any?]) throws -> OpaquePointer? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { throw StoreError.malformed }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (i, value) in values.enumerated() {
            let index = Int32(i + 1)
            switch value {
            case let v as Int: sqlite3_bind_int64(stmt, index, Int64(v))
            case let v as Double: sqlite3_bind_double(stmt, index, v)
            case let v as String: sqlite3_bind_text(stmt, index, v, -1, transient)
            case let v as Data: _ = v.withUnsafeBytes { sqlite3_bind_blob(stmt, index, $0.baseAddress, Int32(v.count), transient) }
            default: sqlite3_bind_null(stmt, index)
            }
        }
        return stmt
    }
}
