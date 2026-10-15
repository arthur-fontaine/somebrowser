import BrowserCore
import BrowserTesting
import Foundation
import SQLite3
import Testing
@testable import FeatureSafari

/// A home folder with Safari's files where Safari keeps them, shaped like the real ones (macOS 27).
func makeHome() throws -> URL {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent("safari-\(UUID().uuidString.prefix(6))")
    let safari = SafariAccess.Folder.library.url(home: home)
    let container = SafariAccess.Folder.container.url(home: home)
    try FileManager.default.createDirectory(at: safari, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
    // Synced items carry their iCloud record (`Sync`).
    let leaf = { (id: String, title: String, url: String) -> [String: Any] in
        ["WebBookmarkType": "WebBookmarkTypeLeaf", "WebBookmarkUUID": id, "URLString": url, "URIDictionary": ["title": title],
         "ReadingListNonSync": ["neverFetchMetadata": false], "Sync": ["ServerID": "server-\(id)", "Data": Data("record-\(id)".utf8)]]
    }
    let root: [String: Any] = [
        "WebBookmarkType": "WebBookmarkTypeList", "WebBookmarkUUID": "root", "WebBookmarkFileVersion": 1, "Title": "",
        "Sync": ["CloudKitDeviceIdentifier": "device", "CloudKitMigrationState": 3],
        "Children": [
            ["WebBookmarkType": "WebBookmarkTypeProxy", "WebBookmarkIdentifier": "History", "Title": "History", "WebBookmarkUUID": "hist"],
            ["WebBookmarkType": "WebBookmarkTypeList", "Title": "BookmarksBar", "WebBookmarkUUID": "bar", "Children": [
                leaf("A1", "Apple", "https://www.apple.com/"), leaf("A2", "Swift", "https://swift.org/"),
                ["WebBookmarkType": "WebBookmarkTypeList", "Title": "Folder", "WebBookmarkUUID": "F1", "Children": []],
            ]],
            ["WebBookmarkType": "WebBookmarkTypeList", "Title": "BookmarksMenu", "WebBookmarkUUID": "menu"],
            ["WebBookmarkType": "WebBookmarkTypeList", "Title": "com.apple.ReadingList", "ShouldOmitFromUI": true, "WebBookmarkUUID": "rl",
             "Children": [leaf("R1", "Later", "https://read.example/")]],
        ],
    ]
    try PropertyListSerialization.data(fromPropertyList: root, format: .binary, options: 0).write(to: safari.appendingPathComponent("Bookmarks.plist"))

    func sqlite(_ file: URL, _ sql: String) {
        var db: OpaquePointer?
        sqlite3_open(file.path, &db)
        sqlite3_exec(db, sql, nil, nil, nil)
        sqlite3_close(db)
    }
    sqlite(safari.appendingPathComponent("History.db"), """
    CREATE TABLE history_items (id INTEGER PRIMARY KEY, url TEXT, domain_expansion TEXT, visit_count INTEGER);
    CREATE TABLE history_visits (id INTEGER PRIMARY KEY, history_item INTEGER, visit_time REAL, title TEXT);
    INSERT INTO history_items VALUES (1, 'https://swift.org/', 'swift', 3), (2, 'https://news.example/', 'news', 1);
    INSERT INTO history_visits VALUES (1, 1, 770000000, 'Swift'), (2, 1, 780000000, 'Swift.org'), (3, 2, 775000000, 'News');
    """)
    // The real schema; positions are zlib-compressed JSON.
    sqlite(container.appendingPathComponent("CloudTabs.db"), """
    CREATE TABLE cloud_tab_devices (device_uuid TEXT PRIMARY KEY NOT NULL, system_fields BLOB NOT NULL, device_name TEXT,
        device_type_identifier TEXT, has_duplicate_device_name BOOLEAN DEFAULT 0, is_ephemeral_device BOOLEAN DEFAULT 0, last_modified REAL NOT NULL);
    CREATE TABLE cloud_tabs (tab_uuid TEXT PRIMARY KEY NOT NULL, system_fields BLOB NOT NULL, device_uuid TEXT NOT NULL, position BLOB NOT NULL,
        title TEXT, url TEXT NOT NULL, is_showing_reader BOOLEAN DEFAULT 0, is_pinned BOOLEAN DEFAULT 0, last_viewed_time REAL DEFAULT 0);
    INSERT INTO cloud_tab_devices VALUES ('D1', x'', 'Arthur’s iPhone', 'com.apple.iphone', 0, 0, 2), ('D2', x'', 'Old iPad', 'com.apple.ipad', 0, 0, 1),
        ('D3', x'', 'This Mac', 'com.apple.macbookpro', 0, 0, 3);
    """)
    // Tab Groups: the real table (macOS 27), with a profile, a group's scoped-favorites folder and tombstones.
    sqlite(container.appendingPathComponent("SafariTabs.db"), """
    CREATE TABLE bookmarks (id INTEGER PRIMARY KEY AUTOINCREMENT,special_id INTEGER DEFAULT 0,parent INTEGER, type INTEGER,title TEXT,url TEXT COLLATE NOCASE,num_children INTEGER DEFAULT 0,editable INTEGER DEFAULT 1,deletable INTEGER DEFAULT 1,hidden INTEGER DEFAULT 0,hidden_ancestor_count INTEGER DEFAULT 0,order_index INTEGER NOT NULL,external_uuid TEXT UNIQUE,read INTEGER DEFAULT NULL,last_modified REAL DEFAULT NULL,server_id TEXT, sync_key TEXT,sync_data BLOB,added INTEGER DEFAULT 1,deleted INTEGER DEFAULT 0,extra_attributes BLOB DEFAULT NULL,local_attributes BLOB DEFAULT NULL,fetched_icon BOOL DEFAULT 0, icon BLOB DEFAULT NULL,dav_generation INTEGER DEFAULT 0,locally_added BOOL DEFAULT 0,archive_status INTEGER DEFAULT 0,syncable BOOL DEFAULT 1,web_filter_status INTEGER DEFAULT 0, modified_attributes UNSIGNED BIG INT DEFAULT 0, date_closed REAL DEFAULT NULL, last_selected_child INTEGER DEFAULT NULL, subtype INTEGER DEFAULT 0, cookies_uuid TEXT DEFAULT NULL, local_storage_uuid TEXT DEFAULT NULL, session_storage_uuid TEXT DEFAULT NULL, topic_title TEXT, feature_text TEXT, fetched_feature_text BOOL DEFAULT 0, is_marked_for_expiration INTEGER);
    INSERT INTO bookmarks (id, special_id, parent, type, subtype, hidden, deleted, order_index, external_uuid, title, url) VALUES
        (0, 0, NULL, 1, 0, 0, 0, 0, 'root', '', NULL),
        (1, 6, 0, 1, 0, 1, 0, 0, 'recovered', 'Recovered', NULL),
        (10, 0, 0, 1, 0, 0, 0, 2, 'G-work', 'Work', NULL),
        (11, 0, 10, 1, 1, 0, 0, 0, 'G-work-favorites', '', NULL),
        (12, 0, 10, 0, 0, 0, 0, 2, 'T-mail', 'Mail', 'https://mail.example/'),
        (13, 0, 10, 0, 0, 0, 0, 1, 'T-docs', 'Docs', 'https://docs.example/'),
        (14, 0, 10, 0, 0, 0, 1, 3, 'T-gone', 'Gone', 'https://gone.example/'),
        (15, 0, 0, 1, 0, 0, 1, 3, 'G-old', 'Old', NULL),
        (16, 0, 0, 1, 0, 0, 0, 1, 'G-empty', 'Empty', NULL),
        (20, 0, 0, 1, 2, 0, 0, 4, 'P-personal', '', NULL),
        (21, 0, 20, 1, 0, 0, 0, 0, 'G-trip', 'Trip', NULL),
        (22, 0, 21, 0, 0, 0, 0, 0, 'T-maps', 'Maps', 'https://maps.example/');
    """)
    var db: OpaquePointer?
    sqlite3_open(container.appendingPathComponent("CloudTabs.db").path, &db)
    for (id, device, title, url, sort, pinned) in [("T1", "D1", "Maps", "https://maps.example/", 300, 0), ("T2", "D1", "Docs", "https://docs.example/", 100, 0),
                                                   ("T3", "D1", "Mail", "https://mail.example/", 900, 1), ("T4", "D3", "Here", "https://here.example/", 1, 0)] {
        var stmt: OpaquePointer?
        sqlite3_prepare_v2(db, "INSERT INTO cloud_tabs VALUES ('\(id)', x'', '\(device)', ?, '\(title)', '\(url)', 0, \(pinned), 0)", -1, &stmt, nil)
        let blob = position(sort)
        _ = blob.withUnsafeBytes { sqlite3_bind_blob(stmt, 1, $0.baseAddress, Int32(blob.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
        sqlite3_step(stmt)
        sqlite3_finalize(stmt)
    }
    sqlite3_close(db)
    return home
}

/// Safari's format for a tab position (zlib header, DEFLATE, Adler-32).
func position(_ sortValue: Int, changeID: Int = 0) -> Data {
    let json = Data(#"{"sortValues":[{"changeID":\#(changeID),"sortValue":\#(sortValue),"deviceIdentifier":"X"}]}"#.utf8)
    var a: UInt32 = 1, b: UInt32 = 0
    for byte in json { a = (a + UInt32(byte)) % 65521; b = (b + a) % 65521 }
    let adler = (b << 16 | a).bigEndian
    return Data([0x78, 0xDA]) + (try! (json as NSData).compressed(using: .zlib) as Data) + withUnsafeBytes(of: adler) { Data($0) }
}

func folders(_ home: URL) -> SafariFolders {
    SafariFolders(library: SafariAccess.Folder.library.url(home: home), container: SafariAccess.Folder.container.url(home: home))
}

struct StoreTests {
    func store() throws -> SafariStore {
        let home = try makeHome()
        return SafariStore(folders: folders(home), backups: home.appendingPathComponent("Backups"), localDeviceName: "This Mac")
    }

    @Test func readsFavoritesTabsAndHistory() throws {
        let s = try store()
        #expect(s.hasAccess)
        #expect(try s.favorites().map(\.title) == ["Apple", "Swift"])
        let devices = try s.cloudTabs()
        #expect(devices.map(\.name) == ["Arthur’s iPhone"])  // not this Mac; the iPad has no tabs
        #expect(devices.first?.tabs.map(\.title) == ["Mail", "Docs", "Maps"])  // pinned first, then Safari's order
        let history = try s.history()
        #expect(history.map(\.url.host) == ["swift.org", "news.example"])
        #expect(history.first?.title == "Swift.org")
        #expect(history.first?.lastVisit == Date(timeIntervalSinceReferenceDate: 780_000_000))
    }

    /// Groups in Safari's order (the default profile's first), their tabs in order; tombstones, the scoped-favorites
    /// folder and Safari's hidden folders left out.
    @Test func readsTabGroups() throws {
        let groups = try store().tabGroups()
        #expect(groups.map(\.title) == ["Empty", "Work", "Trip"])
        #expect(groups[1].tabs.map(\.title) == ["Docs", "Mail"])
        #expect(groups[1].tabs.first?.url.host == "docs.example")
        #expect(groups[2].tabs.map(\.id) == ["T-maps"])
        #expect(groups[0].tabs.isEmpty)
    }

    /// Bytes as Safari writes them (Python's zlib), with two changes: the latest one wins.
    @Test func decodesTabPositions() {
        let hex = "78daab562ace2f2a094bcc294d2d56b28aae564ace48cc4b4ff57451b232d041c82959199a19191b9b1a1800455352cb3293533d5352f34a32d332538b94ac945c4c9d4d9dcc1ccd759dcc5c9c744d9c0c4d752d9dcc4d749d4dcd8c1d2d8d5dcd5c2ccc946a75908d374231de14abb1154ab5b1b50007c331e8"
        let bytes = stride(from: 0, to: hex.count, by: 2).map { i in
            UInt8(hex[hex.index(hex.startIndex, offsetBy: i)..<hex.index(hex.startIndex, offsetBy: i + 2)], radix: 16)!
        }
        #expect(SafariStore.sortValue(Data(bytes)) == 5)
        #expect(SafariStore.sortValue(position(42, changeID: 1)) == 42)
        #expect(SafariStore.sortValue(Data("garbage".utf8)) == .infinity)
    }

    /// Writing back keeps everything we don't touch (sync state, reading list, folders) and keeps a backup.
    @Test func favoritesRoundTripWithoutLosingAnything() throws {
        let s = try store()
        let before = try PropertyListSerialization.propertyList(from: Data(contentsOf: s.bookmarksFile), format: nil) as! NSDictionary
        let added = try s.addFavorite(title: "Example", url: URL(string: "https://example.com/")!)
        #expect(try s.favorites().map(\.title) == ["Apple", "Swift", "Example"])
        try s.removeFavorite(id: added.id)
        try s.removeFavorite(id: "A1")
        #expect(try s.favorites().map(\.id) == ["A2"])
        #expect(throws: SafariStore.StoreError.notFound) { try s.removeFavorite(id: "missing") }

        var format = PropertyListSerialization.PropertyListFormat.xml
        let after = try PropertyListSerialization.propertyList(from: Data(contentsOf: s.bookmarksFile), format: &format) as! NSDictionary
        #expect(format == .binary)
        let sync = (after["Sync"] as! NSDictionary).mutableCopy() as! NSMutableDictionary
        sync.removeObject(forKey: "Changes")
        #expect(sync == before["Sync"] as? NSDictionary)
        #expect(!FileManager.default.fileExists(atPath: s.folders.library.appendingPathComponent("lock").path))
        let children = { (d: NSDictionary) in d["Children"] as! [NSDictionary] }
        #expect(children(after)[3] == children(before)[3])  // reading list untouched
        let bar = children(children(after)[1])
        #expect(bar.first?["ReadingListNonSync"] as? NSDictionary == ["neverFetchMetadata": false])
        #expect(bar.last?["Title"] as? String == "Folder")
        let backups = try FileManager.default.contentsOfDirectory(at: s.backups, includingPropertiesForKeys: nil)
        #expect(!backups.isEmpty)
    }

    func changes(_ s: SafariStore) throws -> [NSDictionary] {
        let root = try PropertyListSerialization.propertyList(from: Data(contentsOf: s.bookmarksFile), format: nil) as! NSDictionary
        return (root["Sync"] as? NSDictionary)?["Changes"] as? [NSDictionary] ?? []
    }

    /// Edits are written to Safari's change log the way Safari writes its own, for its sync agent to upload.
    @Test func editsAreRecordedForSafarisSyncAgent() throws {
        let s = try store()
        let added = try s.addFavorite(title: "Example", url: URL(string: "https://example.com/")!)
        var log = try changes(s)
        #expect(log.count == 1)
        #expect(log[0]["Type"] as? String == "Add")
        #expect(log[0]["BookmarkUUID"] as? String == added.id)
        #expect(log[0]["BookmarkType"] as? String == "Leaf")
        #expect(UUID(uuidString: log[0]["Token"] as? String ?? "") != nil)
        #expect(log[0]["BookmarkServerID"] == nil)

        // Removed before it reached iCloud: Safari's rule, the Add and the Delete cancel out.
        try s.removeFavorite(id: added.id)
        #expect(try changes(s).isEmpty)

        // A synced favorite: the Delete names its iCloud record and keeps the record's data.
        try s.removeFavorite(id: "A1")
        log = try changes(s)
        #expect(log.count == 1)
        #expect(log[0]["Type"] as? String == "Delete")
        #expect(log[0]["BookmarkUUID"] as? String == "A1")
        #expect(log[0]["BookmarkServerID"] as? String == "server-A1")
        #expect(log[0]["DeletedBookmarkSyncData"] as? Data == Data("record-A1".utf8))
        #expect(try s.favorites().map(\.id) == ["A2"])
    }

    @Test func waitsForSafarisLockAndTakesOverAnAbandonedOne() throws {
        let s = try store()
        let lock = s.folders.library.appendingPathComponent("lock")
        func hold(pid: Int32, date: Date) throws {
            try FileManager.default.createDirectory(at: lock, withIntermediateDirectories: true)
            let details: [String: Any] = ["LockFileProcessID": Int(pid), "LockFileDate": date, "LockFileHostname": SafariFileLock.hostname,
                                          "LockFileProcessName": "Safari", "LockFileUsername": NSUserName()]
            try PropertyListSerialization.data(fromPropertyList: details, format: .binary, options: 0).write(to: lock.appendingPathComponent("details.plist"))
        }

        // Held by a live process (this one): wait, then give up.
        try hold(pid: getpid(), date: Date())
        let busy = SafariFileLock(folder: s.folders.library, timeout: 0.2)
        #expect(throws: SafariStore.StoreError.busy) { try busy.withLock {} }
        #expect(FileManager.default.fileExists(atPath: lock.path))

        // Held by a process that's gone, or for too long: taken over, and released after.
        for (pid, date) in [(Int32(99_999), Date()), (getpid(), Date(timeIntervalSinceNow: -3600))] {
            try? FileManager.default.removeItem(at: lock)
            try hold(pid: pid, date: date)
            _ = try s.addFavorite(title: "Example", url: URL(string: "https://example.com/")!)
            #expect(!FileManager.default.fileExists(atPath: lock.path))
        }
    }

    /// Each attempt touches the file (Safari reloads and keeps the records) then asks; stops once the agent took them.
    @Test func uploadRemindsSafariThenAsksUntilTheAgentTookTheRecords() async throws {
        let s = try store()
        _ = try s.addFavorite(title: "Example", url: URL(string: "https://example.com/")!)
        try FileManager.default.setAttributes([.modificationDate: Date.distantPast], ofItemAtPath: s.bookmarksFile.path)
        let asked = Counter()
        let file = s.bookmarksFile
        await s.upload(attempts: Array(repeating: .milliseconds(1), count: 5), reloadGrace: .milliseconds(1), ask: {
            asked.increment()
            guard asked.value == 2 else { return }
            // The agent takes the records on the second request.
            let root = try! PropertyListSerialization.propertyList(from: Data(contentsOf: file), options: .mutableContainers, format: nil) as! NSMutableDictionary
            (root["Sync"] as! NSMutableDictionary).removeObject(forKey: "Changes")
            try! PropertyListSerialization.data(fromPropertyList: root, format: .binary, options: 0).write(to: file)
        })
        #expect(asked.value == 2)
        let touched = try FileManager.default.attributesOfItem(atPath: s.bookmarksFile.path)[.modificationDate] as? Date
        #expect(touched.map { $0 > Date.distantPast } == true)

        // Not migrated to CloudKit bookmarks: the request would start Safari's migration, so nothing is asked.
        let old = try store()
        let root = try PropertyListSerialization.propertyList(from: Data(contentsOf: old.bookmarksFile), options: .mutableContainers, format: nil) as! NSMutableDictionary
        (root["Sync"] as! NSMutableDictionary)["CloudKitMigrationState"] = 1
        try PropertyListSerialization.data(fromPropertyList: root, format: .binary, options: 0).write(to: old.bookmarksFile)
        _ = try old.addFavorite(title: "Example", url: URL(string: "https://example.com/")!)
        let unasked = Counter()
        await old.upload(attempts: [.milliseconds(1)], reloadGrace: .milliseconds(1), ask: { unasked.increment() })
        #expect(unasked.value == 0)
    }

    @Test func missingFilesMeanNoAccessOrNothing() {
        let s = SafariStore(folders: SafariFolders(library: URL(fileURLWithPath: "/nonexistent-library"), container: nil),
                            backups: FileManager.default.temporaryDirectory)
        #expect(!s.hasAccess)
        #expect(throws: SafariStore.StoreError.noAccess) { try s.favorites() }
        #expect((try? s.cloudTabs()) == [])
    }
}

@MainActor
struct AccessTests {
    func grants() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("grants-\(UUID().uuidString.prefix(6))") }

    @Test func eachFolderIsAskedOnceThenRemembered() throws {
        let home = try makeHome(), grants = grants()
        var asked: [SafariAccess.Folder] = []
        let access = SafariAccess(grants: grants, home: home) { folder, url in asked.append(folder); return url }
        #expect(access.restore() == nil)
        #expect(access.request() == folders(home))
        #expect(asked == [.library, .container])
        #expect(access.request() == folders(home))
        #expect(asked.count == 2)

        // Next launch: no panel.
        let later = SafariAccess(grants: grants, home: home) { _, _ in Issue.record("asked again"); return nil }
        #expect(later.restore() == folders(home))
        later.forget()
        #expect(SafariAccess(grants: grants, home: home) { _, _ in nil }.restore() == nil)
    }

    @Test func anotherFolderOrCancelDoesNotCount() throws {
        let home = try makeHome()
        let wrong = SafariAccess(grants: grants(), home: home) { _, _ in home }
        #expect(wrong.request() == nil)

        // Cancelling the second panel keeps favorites and history.
        let partial = SafariAccess(grants: grants(), home: home) { folder, url in folder == .library ? url : nil }
        #expect(partial.request() == SafariFolders(library: folders(home).library, container: nil))
    }
}

nonisolated final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}

@MainActor
struct FeatureTests {
    @Test func connectingShowsSafariDataAndEditsFlowBack() async throws {
        let home = try makeHome()
        let h = try TestHarness(features: [SafariFeature.self], manifestDirectory: #filePath, activate: false)
        let feature = SafariFeature(context: h.context, access: SafariAccess(grants: h.context.dataDirectory, home: home) { _, url in url })
        let asked = Counter()
        feature.askSafariToSync = { asked.increment() }
        feature.uploadAttempts = Array(repeating: .milliseconds(20), count: 50)
        feature.reloadGrace = .milliseconds(1)
        feature.activate()
        #expect(feature.model.hasAccess == false)

        try h.run("safari.connect")
        for _ in 0..<100 where feature.model.favorites.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
        #expect(feature.model.hasAccess == true)
        #expect(feature.model.favorites.count == 2)
        #expect(feature.model.devices.first { $0.name == "Arthur’s iPhone" }?.tabs.count == 3)

        _ = h.openTab("https://new.example/page")
        try h.run("safari.add-favorite")
        let store = try #require(feature.store)
        #expect(try store.favorites().last?.url.host == "new.example")

        // Safari is asked to sync until its agent has taken the record (here: the test clears the log).
        for _ in 0..<100 where asked.value < 2 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(asked.value >= 2)
        let root = try PropertyListSerialization.propertyList(from: Data(contentsOf: store.bookmarksFile), options: .mutableContainers, format: nil) as! NSMutableDictionary
        (root["Sync"] as! NSMutableDictionary).removeObject(forKey: "Changes")
        try PropertyListSerialization.data(fromPropertyList: root, format: .binary, options: 0).write(to: store.bookmarksFile)
        try await Task.sleep(for: .milliseconds(100))
        let settled = asked.value
        try await Task.sleep(for: .milliseconds(100))
        #expect(asked.value == settled)

        // Delete from the start page: gone here and recorded for the agent.
        let apple = try #require(feature.model.favorites.first { $0.id == "A1" })
        feature.removeFavorite(apple)
        #expect(!feature.model.favorites.contains { $0.id == "A1" })
        #expect(try !store.favorites().contains { $0.id == "A1" })
        #expect(try store.pendingChanges() == 1)

        let provider = SafariHistoryOmnibox(model: feature.model, runtime: h.runtime)
        #expect(provider.items(for: "swift", in: h.window).first?.subtitle == "swift.org")

        try h.run("safari.disconnect")
        #expect(feature.model.hasAccess == false)
        #expect(feature.model.favorites.isEmpty)
        #expect(SafariAccess(grants: h.context.dataDirectory, home: home) { _, _ in nil }.restore() == nil)
    }

    @Test func offersSafariForImport() async throws {
        let home = try makeHome()
        let h = try TestHarness(features: [SafariFeature.self], manifestDirectory: #filePath, activate: false)
        let feature = SafariFeature(context: h.context, access: SafariAccess(grants: h.context.dataDirectory, home: home) { _, url in url })
        feature.activate()
        let source = try #require(h.runtime.capabilities.all(BrowserImportSource.self).first)
        #expect(source.name == "Safari")
        let data = try #require(await source.importData())  // asks for the folders, then reads
        #expect(data.bookmarks == [.folder(title: "Favorites", children: [.link(title: "Apple", url: URL(string: "https://www.apple.com/")!),
                                                                          .link(title: "Swift", url: URL(string: "https://swift.org/")!),
                                                                          .folder(title: "Folder", children: [])])])
        #expect(data.history.count == 2)
    }
}
