import CryptoKit
import Foundation
import SQLite3

/// A page visited here, for Safari's history.
nonisolated struct SafariVisit: Equatable, Sendable {
    var url: URL
    var title: String
    var date: Date
}

/// Writing into Safari's databases the way Safari does (macOS 27, statements from WebBookmarks and the history service),
/// so its sync uploads what's written here with its own changes. Each write is one transaction that waits for Safari.
nonisolated extension SafariStore {
    // MARK: Tab Groups

    /// Makes the Tab Group `title` hold exactly `tabs` (ids are the rows' `external_uuid`): new tabs are added rows
    /// (`added` 1), closed ones are tombstoned (`deleted` 1) or, never uploaded, removed; every change takes a new
    /// `_dav_generation`, which is what the agent uploads (`dav_generation > LastSyncedRecordGeneration`). A tab that
    /// changed is a new id: rows are only added or deleted, never modified.
    func mirrorTabGroup(title: String, tabs: [SafariBookmark]) throws {
        guard let file = tabGroupsFile else { throw StoreError.noAccess }
        try Self.transaction(file) { db in
            let root = try Self.int(db, "SELECT id FROM bookmarks WHERE parent IS NULL AND type = 1 ORDER BY id LIMIT 1")
            var generation: Int?
            func nextGeneration() throws -> Int {
                if let generation { return generation }
                try Self.run(db, "UPDATE sync_properties SET value = value + 1 WHERE key = '_dav_generation'")
                try Self.run(db, "UPDATE generations SET generation = generation + 1")
                let value = try Self.int(db, "SELECT value FROM sync_properties WHERE key = '_dav_generation'")
                generation = value
                return value
            }
            var group = try? Self.int(db, "SELECT id FROM bookmarks WHERE parent = ? AND type = 1 AND subtype = 0 AND title = ? AND deleted = 0 LIMIT 1",
                                      root, title)
            if group == nil {
                let order = try Self.int(db, "SELECT COALESCE(MAX(order_index), -1) + 1 FROM bookmarks WHERE parent = ? AND deleted = 0 AND syncable = 1", root)
                let id = try Self.insertRow(db, title: title, url: nil, parent: root, type: 1, subtype: 0, order: order, attributes: nil,
                                            generation: try nextGeneration())
                try Self.run(db, "INSERT INTO folder_ancestors (folder_id, ancestor_id) VALUES (?, ?)", id, root)
                // Every group has a folder for its scoped favorites.
                let favorites = try Self.insertRow(db, title: "", url: nil, parent: id, type: 1, subtype: 1, order: 0, attributes: nil,
                                                   generation: try nextGeneration())
                try Self.run(db, "INSERT INTO folder_ancestors (folder_id, ancestor_id) VALUES (?, ?), (?, ?)", favorites, root, favorites, id)
                try Self.run(db, "UPDATE bookmarks SET num_children = (SELECT count(*) FROM bookmarks WHERE parent = ?1 AND deleted = 0) WHERE id = ?1", root)
                group = id
            }
            guard let group else { return }
            var existing: [String: (id: Int, uploaded: Bool)] = [:]
            Self.rows(db, "SELECT id, external_uuid, server_id IS NOT NULL FROM bookmarks WHERE parent = \(group) AND type = 0 AND deleted = 0") { s in
                existing[Self.text(s, 1)] = (Int(sqlite3_column_int64(s, 0)), sqlite3_column_int(s, 2) != 0)
            }
            let wanted = Set(tabs.map(\.id))
            for (uuid, row) in existing where !wanted.contains(uuid) {
                if row.uploaded {
                    try Self.run(db, "UPDATE bookmarks SET deleted = 1, dav_generation = ? WHERE id = ?", try nextGeneration(), row.id)
                } else {
                    try Self.run(db, "DELETE FROM bookmarks WHERE id = ?", row.id)
                }
            }
            var order = try Self.int(db, "SELECT COALESCE(MAX(order_index), 0) + 1 FROM bookmarks WHERE parent = ? AND deleted = 0", group)
            let viewed = try PropertyListSerialization.data(fromPropertyList: ["DateLastViewed": Date()], format: .binary, options: 0)
            for tab in tabs where existing[tab.id] == nil {
                _ = try Self.insertRow(db, title: tab.title, url: tab.url.absoluteString, parent: group, type: 0, subtype: 0, order: order,
                                       attributes: viewed, generation: try nextGeneration(), uuid: tab.id)
                order += 1
            }
            if generation != nil {
                try Self.run(db, "UPDATE bookmarks SET num_children = (SELECT count(*) FROM bookmarks WHERE parent = ?1 AND deleted = 0) WHERE id = ?1", group)
            }
        }
    }

    /// Removes the Tab Group `title` and its tabs (tombstones for what reached iCloud).
    func removeTabGroup(title: String) throws {
        guard let file = tabGroupsFile else { throw StoreError.noAccess }
        try Self.transaction(file) { db in
            let root = try Self.int(db, "SELECT id FROM bookmarks WHERE parent IS NULL AND type = 1 ORDER BY id LIMIT 1")
            guard let group = try? Self.int(db, "SELECT id FROM bookmarks WHERE parent = ? AND type = 1 AND subtype = 0 AND title = ? AND deleted = 0 LIMIT 1",
                                            root, title) else { throw StoreError.notFound }
            try Self.run(db, "UPDATE sync_properties SET value = value + 1 WHERE key = '_dav_generation'")
            try Self.run(db, "UPDATE generations SET generation = generation + 1")
            let generation = try Self.int(db, "SELECT value FROM sync_properties WHERE key = '_dav_generation'")
            let members = "(id = ?1 OR parent = ?1 OR parent IN (SELECT id FROM bookmarks WHERE parent = ?1))"
            try Self.run(db, "DELETE FROM bookmarks WHERE \(members) AND server_id IS NULL", group)
            try Self.run(db, "UPDATE bookmarks SET deleted = 1, dav_generation = ?2 WHERE \(members) AND deleted = 0", group, generation)
            try Self.run(db, "UPDATE bookmarks SET num_children = (SELECT count(*) FROM bookmarks WHERE parent = ?1 AND deleted = 0) WHERE id = ?1", root)
        }
    }

    /// Safari's own INSERT (WebBookmarks), with the defaults a new row gets; `added` keeps its default, 1.
    private static func insertRow(_ db: OpaquePointer?, title: String, url: String?, parent: Int, type: Int, subtype: Int, order: Int,
                                  attributes: Data?, generation: Int, uuid: String = UUID().uuidString) throws -> Int {
        try run(db, """
        INSERT INTO bookmarks (title, url, parent, type, external_uuid, order_index, extra_attributes, fetched_icon, icon, locally_added,
            archive_status, web_filter_status, hidden_ancestor_count, editable, local_attributes, syncable, dav_generation, last_selected_child,
            subtype, topic_title, feature_text, fetched_feature_text)
        VALUES (?, ?, ?, ?, ?, ?, ?, 0, NULL, 0, 0, 0, 0, 1, NULL, 1, ?, NULL, ?, NULL, NULL, 0)
        """, title, url, parent, type, uuid, order, attributes, generation, subtype)
        return Int(sqlite3_last_insert_rowid(db))
    }

    /// A tab's row id: the same tab at the same page keeps it, anything else is a new row.
    static func tabRowID(tab: UUID, url: URL, title: String) -> String {
        var bytes = Array(SHA256.hash(data: Data("\(tab.uuidString)|\(url.absoluteString)|\(title)".utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50  // version 5 (name-based)
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15])).uuidString
    }

    // MARK: History

    /// Adds visits as Safari records its own (origin 0, this generation), which its history sync uploads. Counts and scores
    /// are left for Safari to recompute (`should_recompute_derived_visit_counts`); `domain_expansion` needs Safari's own
    /// SQL function, so new items have none.
    func addVisits(_ visits: [SafariVisit]) throws {
        guard !visits.isEmpty else { return }
        try Self.transaction(historyFile) { db in
            let generation = try Self.int(db, "SELECT value FROM metadata WHERE key = 'current_generation'")
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
