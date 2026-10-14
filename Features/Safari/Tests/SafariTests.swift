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
    let leaf = { (id: String, title: String, url: String) -> [String: Any] in
        ["WebBookmarkType": "WebBookmarkTypeLeaf", "WebBookmarkUUID": id, "URLString": url, "URIDictionary": ["title": title],
         "ReadingListNonSync": ["neverFetchMetadata": false]]
    }
    let root: [String: Any] = [
        "WebBookmarkType": "WebBookmarkTypeList", "WebBookmarkUUID": "root", "WebBookmarkFileVersion": 1, "Title": "",
        "Sync": ["CloudKitDeviceIdentifier": "device", "CloudKitMigrationState": 0],
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
        #expect(after["Sync"] as? NSDictionary == before["Sync"] as? NSDictionary)
        let children = { (d: NSDictionary) in d["Children"] as! [NSDictionary] }
        #expect(children(after)[3] == children(before)[3])  // reading list untouched
        let bar = children(children(after)[1])
        #expect(bar.first?["ReadingListNonSync"] as? NSDictionary == ["neverFetchMetadata": false])
        #expect(bar.last?["Title"] as? String == "Folder")
        let backups = try FileManager.default.contentsOfDirectory(at: s.backups, includingPropertiesForKeys: nil)
        #expect(!backups.isEmpty)
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

@MainActor
struct FeatureTests {
    @Test func connectingShowsSafariDataAndEditsFlowBack() async throws {
        let home = try makeHome()
        let h = try TestHarness(features: [SafariFeature.self], manifestDirectory: #filePath, activate: false)
        let feature = SafariFeature(context: h.context, access: SafariAccess(grants: h.context.dataDirectory, home: home) { _, url in url })
        feature.activate()
        #expect(feature.model.hasAccess == false)

        try h.run("safari.connect")
        for _ in 0..<100 where feature.model.favorites.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
        #expect(feature.model.hasAccess == true)
        #expect(feature.model.favorites.count == 2)
        #expect(feature.model.devices.first { $0.name == "Arthur’s iPhone" }?.tabs.count == 3)

        _ = h.openTab("https://new.example/page")
        try h.run("safari.add-favorite")
        #expect(try feature.store?.favorites().last?.url.host == "new.example")
        feature.remove(feature.model.favorites[0])
        #expect(try feature.store?.favorites().map(\.title).contains("Apple") == false)

        let provider = SafariHistoryOmnibox(model: feature.model, runtime: h.runtime)
        #expect(provider.items(for: "swift", in: h.window).first?.subtitle == "swift.org")

        try h.run("safari.disconnect")
        #expect(feature.model.hasAccess == false)
        #expect(feature.model.favorites.isEmpty)
        #expect(SafariAccess(grants: h.context.dataDirectory, home: home) { _, _ in nil }.restore() == nil)
    }
}
