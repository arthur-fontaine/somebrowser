import BrowserCore
import Foundation
import SQLite3

/// A Safari bookmark (Favorites are the bookmarks bar's leaves).
nonisolated struct SafariBookmark: Identifiable, Equatable, Sendable {
    var id: String  // WebBookmarkUUID
    var title: String
    var url: URL
}

nonisolated struct SafariDevice: Identifiable, Equatable, Sendable {
    var id: String
    var name: String
    var tabs: [SafariBookmark]
}

/// Safari's own files. Safari's agents keep them in sync with the iPhone through iCloud, so reading them shows the
/// iPhone's favorites, tabs and history; Favorites edited here go into Bookmarks.plist, Safari's own store.
/// The folders come from `SafariAccess` (granted by the user, no Full Disk Access).
nonisolated struct SafariStore: Sendable {
    var folders: SafariFolders
    /// Where backups of Bookmarks.plist go before every write.
    var backups: URL
    /// This Mac's iCloud Tabs device, left out (Safari lists it too).
    var localDeviceName: String?

    var bookmarksFile: URL { folders.library.appendingPathComponent("Bookmarks.plist") }
    var historyFile: URL { folders.library.appendingPathComponent("History.db") }
    var cloudTabsFile: URL? { folders.container?.appendingPathComponent("CloudTabs.db") }

    enum StoreError: Error, Equatable { case noAccess, malformed, notFound }

    /// Reading actually fails without the grant (`access()` would say yes).
    var hasAccess: Bool { (try? FileHandle(forReadingFrom: bookmarksFile))?.closeFile() != nil }

    // MARK: Favorites

    func favorites() throws -> [SafariBookmark] {
        let root = try readBookmarks()
        return Self.leaves(of: try Self.bar(in: root))
    }

    /// Adds a favorite (Safari's sync agent uploads items without sync state as new).
    @discardableResult
    func addFavorite(title: String, url: URL) throws -> SafariBookmark {
        let root = try readBookmarks()
        let bar = try Self.bar(in: root)
        let item = SafariBookmark(id: UUID().uuidString, title: title, url: url)
        let children = (bar["Children"] as? NSMutableArray) ?? NSMutableArray()
        children.add(NSMutableDictionary(dictionary: [
            "WebBookmarkType": "WebBookmarkTypeLeaf",
            "WebBookmarkUUID": item.id,
            "URLString": url.absoluteString,
            "URIDictionary": NSMutableDictionary(dictionary: ["title": title]),
        ]))
        bar["Children"] = children
        try write(root)
        return item
    }

    func removeFavorite(id: String) throws {
        let root = try readBookmarks()
        guard let children = try Self.bar(in: root)["Children"] as? NSMutableArray else { throw StoreError.notFound }
        let index = children.indexOfObject { item, _, _ in (item as? NSDictionary)?["WebBookmarkUUID"] as? String == id }
        guard index != NSNotFound else { throw StoreError.notFound }
        children.removeObject(at: index)
        try write(root)
    }

    private func readBookmarks() throws -> NSMutableDictionary {
        guard let data = try? Data(contentsOf: bookmarksFile) else { throw hasAccess ? StoreError.notFound : StoreError.noAccess }
        guard let root = try PropertyListSerialization.propertyList(from: data, options: .mutableContainersAndLeaves, format: nil)
            as? NSMutableDictionary else { throw StoreError.malformed }
        return root
    }

    /// Backs up the current file, then replaces it atomically in Safari's own (binary) format; every key we
    /// don't know (sync state, reading list…) is written back untouched.
    private func write(_ root: NSMutableDictionary) throws {
        try FileManager.default.createDirectory(at: backups, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        try? FileManager.default.copyItem(at: bookmarksFile, to: backups.appendingPathComponent("Bookmarks-\(stamp).plist"))
        let old = (try? FileManager.default.contentsOfDirectory(at: backups, includingPropertiesForKeys: nil)) ?? []
        for file in old.sorted(by: { $0.lastPathComponent > $1.lastPathComponent }).dropFirst(10) { try? FileManager.default.removeItem(at: file) }
        let data = try PropertyListSerialization.data(fromPropertyList: root, format: .binary, options: 0)
        try data.write(to: bookmarksFile, options: .atomic)
    }

    static func bar(in root: NSDictionary) throws -> NSMutableDictionary {
        let children = root["Children"] as? [NSMutableDictionary] ?? []
        guard let bar = children.first(where: { $0["Title"] as? String == "BookmarksBar" }) else { throw StoreError.malformed }
        return bar
    }

    /// Every bookmark for import: Favorites, the Bookmarks Menu's contents and other folders (not the Reading List).
    func bookmarkTree() throws -> [BookmarkNode] {
        func nodes(_ list: NSDictionary) -> [BookmarkNode] {
            (list["Children"] as? [NSDictionary] ?? []).compactMap { item in
                switch item["WebBookmarkType"] as? String {
                case "WebBookmarkTypeLeaf":
                    guard let s = item["URLString"] as? String, let url = URL(string: s) else { return nil }
                    return .link(title: (item["URIDictionary"] as? NSDictionary)?["title"] as? String ?? url.host() ?? s, url: url)
                case "WebBookmarkTypeList":
                    return .folder(title: item["Title"] as? String ?? "", children: nodes(item))
                default:
                    return nil
                }
            }
        }
        return try nodes(readBookmarks()).flatMap { node -> [BookmarkNode] in
            guard case .folder(let title, let children) = node else { return [node] }
            switch title {
            case "BookmarksBar": return children.isEmpty ? [] : [.folder(title: "Favorites", children: children)]
            case "BookmarksMenu": return children
            case "com.apple.ReadingList": return []
            default: return [node]
            }
        }
    }

    static func leaves(of list: NSDictionary) -> [SafariBookmark] {
        (list["Children"] as? [NSDictionary] ?? []).compactMap { item in
            guard item["WebBookmarkType"] as? String == "WebBookmarkTypeLeaf", let id = item["WebBookmarkUUID"] as? String,
                  let s = item["URLString"] as? String, let url = URL(string: s) else { return nil }
            let title = (item["URIDictionary"] as? NSDictionary)?["title"] as? String ?? url.host() ?? s
            return SafariBookmark(id: id, title: title, url: url)
        }
    }

    // MARK: iCloud Tabs

    /// Other devices' open tabs, most recently synced device first, in each device's tab order (pinned first).
    func cloudTabs() throws -> [SafariDevice] {
        guard let file = cloudTabsFile, FileManager.default.fileExists(atPath: file.path) else { return [] }
        return try Self.query(file) { db in
            var devices: [String: SafariDevice] = [:]
            var order: [String] = []
            Self.rows(db, "SELECT device_uuid, device_name FROM cloud_tab_devices ORDER BY last_modified DESC") { s in
                let id = Self.text(s, 0), name = Self.text(s, 1)
                guard name != localDeviceName else { return }
                devices[id] = SafariDevice(id: id, name: name, tabs: [])
                order.append(id)
            }
            var keys: [String: (pinned: Bool, position: Double)] = [:]
            Self.rows(db, "SELECT tab_uuid, device_uuid, title, url, position, is_pinned FROM cloud_tabs") { s in
                let id = Self.text(s, 0), device = Self.text(s, 1)
                guard let url = URL(string: Self.text(s, 3)), devices[device] != nil else { return }
                let blob = sqlite3_column_blob(s, 4).map { Data(bytes: $0, count: Int(sqlite3_column_bytes(s, 4))) } ?? Data()
                keys[id] = (sqlite3_column_int(s, 5) != 0, Self.sortValue(blob))
                devices[device]?.tabs.append(SafariBookmark(id: id, title: Self.text(s, 2), url: url))
            }
            return order.compactMap { id in
                devices[id].map { device in
                    var device = device
                    device.tabs.sort { a, b in
                        let ka = keys[a.id]!, kb = keys[b.id]!
                        return ka.pinned != kb.pinned ? ka.pinned : ka.position < kb.position
                    }
                    return device
                }
            }.filter { !$0.tabs.isEmpty }
        }
    }

    /// A tab's position: zlib-compressed JSON, `{"sortValues":[{"changeID":…,"sortValue":…}]}`; the latest change wins.
    static func sortValue(_ blob: Data) -> Double {
        let body = blob.first == 0x78 ? blob.dropFirst(2) : blob[...]  // zlib header; Foundation decodes raw DEFLATE
        guard let json = try? (Data(body) as NSData).decompressed(using: .zlib) as Data,
              let object = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
              let values = object["sortValues"] as? [[String: Any]],
              let latest = values.max(by: { ($0["changeID"] as? Int ?? 0) < ($1["changeID"] as? Int ?? 0) }),
              let value = latest["sortValue"] as? NSNumber else { return .infinity }
        return value.doubleValue
    }

    // MARK: History

    /// Safari's history (this Mac and, through iCloud, the iPhone), newest first.
    func history(limit: Int = 20_000) throws -> [HistoryEntry] {
        try Self.query(historyFile) { db in
            var out: [HistoryEntry] = []
            let sql = """
            SELECT i.url, v.title, i.visit_count, MAX(v.visit_time) AS last FROM history_items i
            JOIN history_visits v ON v.history_item = i.id GROUP BY i.id ORDER BY last DESC LIMIT \(limit)
            """
            Self.rows(db, sql) { s in
                guard let url = URL(string: Self.text(s, 0)) else { return }
                out.append(HistoryEntry(url: url, title: Self.text(s, 1), lastVisit: Date(timeIntervalSinceReferenceDate: sqlite3_column_double(s, 3)),
                                        visitCount: Int(sqlite3_column_int64(s, 2))))
            }
            return out
        }
    }

    // MARK: SQLite

    /// Safari keeps its databases open (WAL): read a private copy.
    static func query<T>(_ file: URL, _ body: (OpaquePointer?) -> T) throws -> T {
        guard FileManager.default.fileExists(atPath: file.path) else { throw StoreError.notFound }
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent("safari-\(UUID().uuidString)")
        defer { for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: copy.path + suffix) } }
        do { try FileManager.default.copyItem(at: file, to: copy) } catch { throw StoreError.noAccess }
        if FileManager.default.fileExists(atPath: file.path + "-wal") { try? FileManager.default.copyItem(atPath: file.path + "-wal", toPath: copy.path + "-wal") }
        var db: OpaquePointer?
        guard sqlite3_open_v2(copy.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else { sqlite3_close(db); throw StoreError.malformed }
        defer { sqlite3_close(db) }
        return body(db)
    }

    static func rows(_ db: OpaquePointer?, _ sql: String, _ row: (OpaquePointer?) -> Void) {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        while sqlite3_step(stmt) == SQLITE_ROW { row(stmt) }
    }

    static func text(_ stmt: OpaquePointer?, _ column: Int32) -> String {
        sqlite3_column_text(stmt, column).map { String(cString: $0) } ?? ""
    }
}
