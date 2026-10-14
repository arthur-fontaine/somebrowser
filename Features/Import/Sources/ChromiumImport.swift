import BrowserCore
import Foundation
import SQLite3

/// A browser whose data can be imported: Chromium browsers keep profiles under Application Support.
nonisolated struct BrowserSource: Identifiable, Equatable, Sendable {
    var id: String
    var name: String
    var bundleID: String
    /// Candidate user-data directories, relative to `~/Library/Application Support` (first existing wins).
    var userData: [String]

    static let chromium: [BrowserSource] = [
        BrowserSource(id: "chrome", name: "Google Chrome", bundleID: "com.google.Chrome", userData: ["Google/Chrome"]),
        BrowserSource(id: "arc", name: "Arc", bundleID: "company.thebrowser.Browser", userData: ["Arc/User Data"]),
        BrowserSource(id: "dia", name: "Dia", bundleID: "company.thebrowser.dia", userData: ["Dia/User Data"]),
        BrowserSource(id: "atlas", name: "ChatGPT Atlas", bundleID: "com.openai.atlas",
                      userData: ["com.openai.atlas/browser-data/host", "com.openai.atlas.beta/browser-data/host"]),
        BrowserSource(id: "helium", name: "Helium", bundleID: "net.imput.helium", userData: ["net.imput.helium"]),
        BrowserSource(id: "brave", name: "Brave", bundleID: "com.brave.Browser", userData: ["BraveSoftware/Brave-Browser"]),
        BrowserSource(id: "edge", name: "Microsoft Edge", bundleID: "com.microsoft.edgemac", userData: ["Microsoft Edge"]),
        BrowserSource(id: "vivaldi", name: "Vivaldi", bundleID: "com.vivaldi.Vivaldi", userData: ["Vivaldi"]),
        BrowserSource(id: "chromium", name: "Chromium", bundleID: "org.chromium.Chromium", userData: ["Chromium"]),
    ]
}

/// One profile of a source browser.
nonisolated struct SourceProfile: Identifiable, Equatable, Sendable {
    var source: BrowserSource
    var name: String
    var directory: URL
    var id: String { directory.path }
}

nonisolated indirect enum ImportedBookmark: Equatable, Sendable {
    case link(title: String, url: URL)
    case folder(title: String, children: [ImportedBookmark])

    var linkCount: Int {
        switch self {
        case .link: 1
        case .folder(_, let children): children.reduce(0) { $0 + $1.linkCount }
        }
    }
}

/// What a profile holds.
nonisolated struct ImportedData: Equatable, Sendable {
    var bookmarks: [ImportedBookmark] = []
    var history: [HistoryEntry] = []
    var extensions: [BrowserExtension] = []
    var bookmarkCount: Int { bookmarks.reduce(0) { $0 + $1.linkCount } }
}

nonisolated enum ChromiumImport {
    /// Profiles of every installed Chromium browser (names from `Local State`).
    static func profiles(of sources: [BrowserSource] = BrowserSource.chromium,
                         applicationSupport: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]) -> [SourceProfile] {
        sources.flatMap { source -> [SourceProfile] in
            guard let root = source.userData.map({ applicationSupport.appendingPathComponent($0) })
                .first(where: { FileManager.default.fileExists(atPath: $0.appendingPathComponent("Local State").path) }) else { return [] }
            let state = (try? Data(contentsOf: root.appendingPathComponent("Local State")))
                .flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }
            let cache = (state?["profile"] as? [String: Any])?["info_cache"] as? [String: [String: Any]] ?? [:]
            let dirs = cache.isEmpty ? ["Default"] : cache.keys.sorted { $0 == "Default" ? true : $1 == "Default" ? false : $0 < $1 }
            return dirs.compactMap { dir in
                let directory = root.appendingPathComponent(dir)
                let hasData = ["Bookmarks", "History", "Secure Preferences"].contains {
                    FileManager.default.fileExists(atPath: directory.appendingPathComponent($0).path)
                }
                guard hasData else { return nil }
                let profileName = cache[dir]?["name"] as? String ?? dir
                return SourceProfile(source: source, name: profileName, directory: directory)
            }
        }
    }

    static func read(_ profile: URL, historyLimit: Int = 200_000) -> ImportedData {
        ImportedData(bookmarks: bookmarks(profile.appendingPathComponent("Bookmarks")),
                     history: history(profile.appendingPathComponent("History"), limit: historyLimit),
                     extensions: ChromiumExtensions.read(profile: profile).filter(\.isFromWebStore))
    }

    /// The bookmarks bar's items, then "Other Bookmarks" and "Mobile Bookmarks" as folders.
    static func bookmarks(_ file: URL) -> [ImportedBookmark] {
        guard let data = try? Data(contentsOf: file),
              let roots = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["roots"] as? [String: Any] else { return [] }
        func node(_ n: [String: Any]) -> ImportedBookmark? {
            let title = n["name"] as? String ?? ""
            if n["type"] as? String == "url", let s = n["url"] as? String, let url = URL(string: s) { return .link(title: title, url: url) }
            guard n["type"] as? String == "folder" else { return nil }
            return .folder(title: title, children: (n["children"] as? [[String: Any]] ?? []).compactMap(node))
        }
        var out = (((roots["bookmark_bar"] as? [String: Any])?["children"]) as? [[String: Any]] ?? []).compactMap(node)
        for key in ["other", "synced"] {
            guard let root = roots[key] as? [String: Any], case .folder(let title, let children)? = node(root), !children.isEmpty else { continue }
            out.append(.folder(title: title, children: children))
        }
        return out
    }

    /// Chromium's `urls` table. The browser may be running (the file is locked/journaled), so a copy is read.
    static func history(_ file: URL, limit: Int) -> [HistoryEntry] {
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent("import-history-\(UUID().uuidString)")
        defer { for suffix in ["", "-journal", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: copy.path + suffix) } }
        for suffix in ["", "-wal"] where FileManager.default.fileExists(atPath: file.path + suffix) {
            try? FileManager.default.copyItem(atPath: file.path + suffix, toPath: copy.path + suffix)
        }
        var db: OpaquePointer?
        guard sqlite3_open_v2(copy.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { sqlite3_close(db); return [] }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        let sql = "SELECT url, title, visit_count, last_visit_time FROM urls WHERE hidden = 0 AND last_visit_time > 0 ORDER BY last_visit_time DESC LIMIT ?1"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, Int64(limit))
        var out: [HistoryEntry] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let u = sqlite3_column_text(stmt, 0), let url = URL(string: String(cString: u)) else { continue }
            let title = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""
            out.append(HistoryEntry(url: url, title: title, lastVisit: date(chromium: sqlite3_column_int64(stmt, 3)),
                                    visitCount: Int(sqlite3_column_int64(stmt, 2))))
        }
        return out
    }

    /// Chromium time: microseconds since 1601-01-01 UTC.
    static func date(chromium microseconds: Int64) -> Date {
        Date(timeIntervalSince1970: Double(microseconds) / 1_000_000 - 11_644_473_600)
    }
}
