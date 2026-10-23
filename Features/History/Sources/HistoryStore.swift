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

    func importEntries(_ entries: [HistoryEntry]) {
        exec("BEGIN")
        let stmt = prepare("""
        INSERT INTO pages(url, title, host, last_visit, visit_count) VALUES(?1, ?2, ?3, ?4, ?5)
        ON CONFLICT(url) DO UPDATE SET visit_count = visit_count + excluded.visit_count,
          title = CASE WHEN excluded.last_visit > last_visit AND excluded.title != '' THEN excluded.title ELSE title END,
          last_visit = max(last_visit, excluded.last_visit)
        """) { _ in }
        for entry in entries where ["http", "https", "file"].contains(entry.url.scheme ?? "") {
            sqlite3_reset(stmt)
            sqlite3_bind_text(stmt, 1, entry.url.absoluteString, -1, transient)
            sqlite3_bind_text(stmt, 2, entry.title, -1, transient)
            sqlite3_bind_text(stmt, 3, entry.url.host() ?? "", -1, transient)
            sqlite3_bind_double(stmt, 4, entry.lastVisit.timeIntervalSince1970)
            sqlite3_bind_int64(stmt, 5, Int64(max(entry.visitCount, 1)))
            sqlite3_step(stmt)
        }
        sqlite3_finalize(stmt)
        exec("COMMIT")
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
        let stmt: OpaquePointer?
        if words.count == 1, q.contains("://"), prefixCount(q, upTo: 401) <= 400 {
            // An address (the editor opens on the page's own) matches a few rows, and `LIKE '%…%'` reads every row before
            // it can tell: on a large imported history, ~50 ms. A prefix is a lookup in the url index.
            stmt = prepare("SELECT url, title, last_visit, visit_count FROM pages WHERE url >= ?1 AND url < ?2 ORDER BY last_visit DESC") { s in
                self.bindPrefix(q, to: s)
            }
        } else {
            let clause = words.indices.map { "(url LIKE ?\($0 + 1) OR title LIKE ?\($0 + 1))" }.joined(separator: " AND ")
            stmt = prepare("SELECT url, title, last_visit, visit_count FROM pages WHERE \(clause) ORDER BY last_visit DESC LIMIT 400") { s in
                for (i, w) in words.enumerated() { sqlite3_bind_text(s, Int32(i + 1), "%\(w)%", -1, transient) }
            }
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

    /// Pages whose url starts with `prefix`, counted up to `limit`.
    private func prefixCount(_ prefix: String, upTo limit: Int) -> Int {
        let stmt = prepare("SELECT count(*) FROM (SELECT 1 FROM pages WHERE url >= ?1 AND url < ?2 LIMIT ?3)") { s in
            bindPrefix(prefix, to: s)
            sqlite3_bind_int(s, 3, Int32(limit))
        }
        defer { sqlite3_finalize(stmt) }
        return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int(stmt, 0)) : 0
    }

    private func bindPrefix(_ prefix: String, to stmt: OpaquePointer?) {
        sqlite3_bind_text(stmt, 1, prefix, -1, transient)
        sqlite3_bind_text(stmt, 2, prefix + "\u{10FFFF}", -1, transient)
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

    /// The sites visited most (by visits to all their pages), each with its most visited page.
    func frequentSites(limit: Int, excluding hosts: Set<String> = []) -> [HistoryEntry] {
        let pages = rows(prepare("SELECT url, title, last_visit, visit_count FROM pages ORDER BY visit_count DESC LIMIT 400") { _ in })
        var bySite: [String: (top: HistoryEntry, visits: Int)] = [:]
        for page in pages {
            guard let site = Self.site(page.url), !hosts.contains(site) else { continue }
            if let known = bySite[site] { bySite[site] = (known.top, known.visits + page.visitCount) } else { bySite[site] = (page, page.visitCount) }
        }
        return bySite.values.sorted { $0.visits > $1.visits }.prefix(limit).map(\.top)
    }

    /// A page's site: its host without `www.`.
    static func site(_ url: URL) -> String? {
        guard ["http", "https"].contains(url.scheme), var host = url.host()?.lowercased() else { return nil }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        return host
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
