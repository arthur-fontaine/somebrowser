import BrowserCore
import Foundation
import SQLite3

/// SQLite-backed history (system libsqlite3, no dependency). One row per URL with frecency inputs.
final class HistoryStore: HistoryService {
    nonisolated(unsafe) private var db: OpaquePointer?
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(path: String) {
        if sqlite3_open_v2(path, &db, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) != SQLITE_OK {
            sqlite3_open(":memory:", &db)
        }
        exec("PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL;")
        exec("""
        CREATE TABLE IF NOT EXISTS pages (
          url TEXT PRIMARY KEY, title TEXT NOT NULL DEFAULT '', host TEXT NOT NULL DEFAULT '',
          last_visit REAL NOT NULL, visit_count INTEGER NOT NULL DEFAULT 1);
        CREATE INDEX IF NOT EXISTS pages_last ON pages(last_visit DESC);
        """)
    }

    deinit { sqlite3_close(db) }

    @discardableResult
    private func exec(_ sql: String) -> Bool { sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK }

    private func prepare(_ sql: String, _ bind: (OpaquePointer?) -> Void) -> OpaquePointer? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        bind(stmt)
        return stmt
    }

    func record(url: URL, title: String?, at date: Date = Date()) {
        guard ["http", "https", "file"].contains(url.scheme ?? "") else { return }
        let stmt = prepare("""
        INSERT INTO pages(url, title, host, last_visit, visit_count) VALUES(?1, coalesce(?2, ''), ?3, ?4, 1)
        ON CONFLICT(url) DO UPDATE SET last_visit = ?4, visit_count = visit_count + 1,
          title = CASE WHEN ?2 IS NULL OR ?2 = '' THEN title ELSE ?2 END
        """) { s in
            sqlite3_bind_text(s, 1, url.absoluteString, -1, transient)
            if let title { sqlite3_bind_text(s, 2, title, -1, transient) } else { sqlite3_bind_null(s, 2) }
            sqlite3_bind_text(s, 3, url.host() ?? "", -1, transient)
            sqlite3_bind_double(s, 4, date.timeIntervalSince1970)
        }
        sqlite3_step(stmt)
        sqlite3_finalize(stmt)
    }

    func updateTitle(url: URL, title: String) {
        guard !title.isEmpty else { return }
        let stmt = prepare("UPDATE pages SET title = ?2 WHERE url = ?1") { s in
            sqlite3_bind_text(s, 1, url.absoluteString, -1, transient)
            sqlite3_bind_text(s, 2, title, -1, transient)
        }
        sqlite3_step(stmt)
        sqlite3_finalize(stmt)
    }

    private func rows(_ stmt: OpaquePointer?) -> [HistoryEntry] {
        var out: [HistoryEntry] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let u = sqlite3_column_text(stmt, 0), let url = URL(string: String(cString: u)) else { continue }
            let title = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""
            out.append(HistoryEntry(url: url, title: title, lastVisit: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 2)),
                                    visitCount: Int(sqlite3_column_int(stmt, 3))))
        }
        sqlite3_finalize(stmt)
        return out
    }

    func search(_ query: String, limit: Int) -> [HistoryEntry] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return recent(limit: limit) }
        // Candidates by LIKE, ranked by frecency in Swift (cheap for a bounded candidate set).
        let words = q.split(separator: " ").prefix(4).map(String.init)
        let clause = words.indices.map { "(url LIKE ?\($0 + 1) OR title LIKE ?\($0 + 1))" }.joined(separator: " AND ")
        let stmt = prepare("SELECT url, title, last_visit, visit_count FROM pages WHERE \(clause) ORDER BY last_visit DESC LIMIT 400") { s in
            for (i, w) in words.enumerated() { sqlite3_bind_text(s, Int32(i + 1), "%\(w)%", -1, transient) }
        }
        let now = Date()
        return rows(stmt)
            .map { e -> (HistoryEntry, Double) in
                let match = max(FuzzyMatch.score(q, in: e.title), FuzzyMatch.score(q, in: e.url.host() ?? ""), 0.4)
                return (e, match * Self.frecency(e, now: now))
            }
            .sorted { $0.1 > $1.1 }
            .prefix(limit)
            .map(\.0)
    }

    /// Visit count with a recency decay (half-life of two weeks).
    static func frecency(_ e: HistoryEntry, now: Date) -> Double {
        let days = max(0, now.timeIntervalSince(e.lastVisit) / 86_400)
        return (1 + log2(Double(max(1, e.visitCount)))) * pow(0.5, days / 14)
    }

    func recent(limit: Int) -> [HistoryEntry] {
        rows(prepare("SELECT url, title, last_visit, visit_count FROM pages ORDER BY last_visit DESC LIMIT ?1") { s in
            sqlite3_bind_int(s, 1, Int32(limit))
        })
    }

    func remove(url: URL) {
        let stmt = prepare("DELETE FROM pages WHERE url = ?1") { s in sqlite3_bind_text(s, 1, url.absoluteString, -1, transient) }
        sqlite3_step(stmt)
        sqlite3_finalize(stmt)
    }

    func clear(since date: Date?) {
        let stmt = prepare("DELETE FROM pages WHERE last_visit >= ?1") { s in sqlite3_bind_double(s, 1, date?.timeIntervalSince1970 ?? 0) }
        sqlite3_step(stmt)
        sqlite3_finalize(stmt)
    }

    func prune(olderThan days: Int) {
        let stmt = prepare("DELETE FROM pages WHERE last_visit < ?1") { s in
            sqlite3_bind_double(s, 1, Date().addingTimeInterval(-Double(days) * 86_400).timeIntervalSince1970)
        }
        sqlite3_step(stmt)
        sqlite3_finalize(stmt)
    }
}
