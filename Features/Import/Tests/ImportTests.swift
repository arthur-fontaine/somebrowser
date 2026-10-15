import BrowserCore
import BrowserTesting
import Foundation
import SQLite3
import Testing
@testable import FeatureImport

/// A Chromium user-data directory like Chrome's: two profiles, bookmarks, a History database, extensions.
func makeUserData() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("import-\(UUID().uuidString.prefix(6))")
    let appSupport = root.appendingPathComponent("Application Support")
    let chrome = appSupport.appendingPathComponent("Google/Chrome")
    let profile = chrome.appendingPathComponent("Default")
    try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: chrome.appendingPathComponent("Profile 1"), withIntermediateDirectories: true)
    func write(_ object: Any, _ url: URL) throws { try JSONSerialization.data(withJSONObject: object).write(to: url) }
    try write(["profile": ["info_cache": ["Default": ["name": "Personal"], "Profile 1": ["name": "Work"]]]], chrome.appendingPathComponent("Local State"))
    try write(["roots": [
        "bookmark_bar": ["type": "folder", "name": "Bookmarks bar", "children": [
            ["type": "url", "name": "Swift", "url": "https://swift.org/"],
            ["type": "folder", "name": "News", "children": [["type": "url", "name": "HN", "url": "https://news.ycombinator.com/"]]],
        ]],
        "other": ["type": "folder", "name": "Other bookmarks", "children": [["type": "url", "name": "Docs", "url": "https://developer.apple.com/"]]],
        "synced": ["type": "folder", "name": "Mobile bookmarks", "children": []],
    ]], profile.appendingPathComponent("Bookmarks"))
    try write(["extensions": ["settings": [
        "storeext": ["location": 1, "path": "storeext/1_0", "from_webstore": true, "manifest": ["name": "Store Ext"]],
        "devext": ["location": 4, "path": "/tmp/dev", "manifest": ["name": "Dev Ext"]],
    ]]], profile.appendingPathComponent("Secure Preferences"))
    var db: OpaquePointer?
    sqlite3_open(profile.appendingPathComponent("History").path, &db)
    sqlite3_exec(db, """
    CREATE TABLE urls(id INTEGER PRIMARY KEY, url TEXT, title TEXT, visit_count INTEGER, typed_count INTEGER, last_visit_time INTEGER, hidden INTEGER);
    INSERT INTO urls VALUES (1, 'https://swift.org/', 'Swift', 12, 0, 13400000000000000, 0);
    INSERT INTO urls VALUES (2, 'https://hidden.example/', 'Hidden', 1, 0, 13400000000000000, 1);
    INSERT INTO urls VALUES (3, 'https://older.example/', 'Older', 2, 0, 13300000000000000, 0);
    """, nil, nil, nil)
    sqlite3_close(db)
    return appSupport
}

struct ReaderTests {
    @Test func discoversProfilesWithData() throws {
        let appSupport = try makeUserData()
        let profiles = ChromiumImport.profiles(applicationSupport: appSupport)
        // "Work" has no data yet: not offered.
        #expect(profiles.map(\.name) == ["Personal"])
        #expect(profiles.first?.source.id == "chrome")
    }

    @Test func readsBookmarksHistoryAndStoreExtensions() throws {
        let appSupport = try makeUserData()
        let data = ChromiumImport.read(appSupport.appendingPathComponent("Google/Chrome/Default"))
        #expect(data.bookmarks == [
            .link(title: "Swift", url: URL(string: "https://swift.org/")!),
            .folder(title: "News", children: [.link(title: "HN", url: URL(string: "https://news.ycombinator.com/")!)]),
            .folder(title: "Other bookmarks", children: [.link(title: "Docs", url: URL(string: "https://developer.apple.com/")!)]),
        ])
        #expect(data.bookmarkCount == 3)
        #expect(data.history.map(\.url.host) == ["swift.org", "older.example"])
        #expect(data.history.first?.visitCount == 12)
        // 13400000000000000 µs since 1601 = 2025-08-22T…Z
        #expect(abs(data.history[0].lastVisit.timeIntervalSince1970 - 1_755_526_400) < 86_400 * 2)
        #expect(data.extensions.map(\.id) == ["storeext"])
    }
}

/// Records what the importer hands to history.
final class RecordingHistory: HistoryService {
    var imported: [HistoryEntry] = []
    func search(_ query: String, limit: Int) -> [HistoryEntry] { [] }
    func recent(limit: Int) -> [HistoryEntry] { [] }
    func remove(url: URL) {}
    func clear(since date: Date?) {}
    func importEntries(_ entries: [HistoryEntry]) { imported += entries }
}

@MainActor
struct ImportFlowTests {
    @Test func importsIntoAPinnedFolderAndHistory() async throws {
        let appSupport = try makeUserData()
        let h = try TestHarness(features: [ImportFeature.self], manifestDirectory: #filePath, activate: false)
        let history = RecordingHistory()
        h.runtime.capabilities.provide(HistoryService.self, history)
        h.activate()
        let feature = try #require(h.runtime.feature(ImportFeature.self))
        feature.discover = { ChromiumImport.profiles(applicationSupport: appSupport) }
        try h.run("import.open")
        #expect(h.window.flags.contains(ImportFeature.sheetFlag))
        let profile = try #require(feature.model.selected)
        for _ in 0..<100 where feature.model.preview == nil { try await Task.sleep(for: .milliseconds(20)) }
        let data = try #require(feature.model.preview)
        await feature.importData(data, from: profile, into: h.window)

        let pinned = h.runtime.tabs.nodes(in: .section(h.window.spaceID, .pinned))
        let folder = try #require(pinned.compactMap { h.runtime.tabs.folder($0) }.first)
        #expect(folder.name == "Google Chrome (Personal)")
        let inside = h.runtime.tabs.nodes(in: .node(folder.id))
        #expect(inside.count == 3)  // Swift, News/, Other bookmarks/
        #expect(h.runtime.tabs.tab(inside[0])?.url?.host == "swift.org")
        #expect(h.runtime.tabs.tab(inside[0])?.engineTab == nil)  // imported, not loaded
        #expect(history.imported.count == 2)
        #expect(feature.model.result?.bookmarks == 3)
    }

    /// Another feature's source (e.g. Safari) is listed first and read through it.
    @Test func importsFromContributedSources() async throws {
        let h = try TestHarness(features: [ImportFeature.self], manifestDirectory: #filePath, activate: false)
        let history = RecordingHistory()
        h.runtime.capabilities.provide(HistoryService.self, history)
        let source = FakeSource()
        h.runtime.capabilities.contribute(BrowserImportSource.self, source)
        h.activate()
        let feature = try #require(h.runtime.feature(ImportFeature.self))
        feature.discover = { [] }
        try h.run("import.open")
        let profile = try #require(feature.model.selected)
        #expect(profile.isContributed && profile.source.name == "Safari")
        for _ in 0..<100 where feature.model.preview == nil { try await Task.sleep(for: .milliseconds(20)) }
        let data = try #require(feature.model.preview)
        #expect(data.bookmarkCount == 2 && data.history.count == 1)
        await feature.importData(data, from: profile, into: h.window)
        let folder = try #require(h.runtime.tabs.nodes(in: .section(h.window.spaceID, .pinned)).compactMap { h.runtime.tabs.folder($0) }.first)
        #expect(folder.name == "Safari")
        #expect(history.imported.count == 1)
    }

    final class FakeSource: BrowserImportSource {
        let name = "Safari"
        let bundleIdentifier = "com.apple.Safari"
        func importData() async -> ImportableData? {
            ImportableData(bookmarks: [.folder(title: "Favorites", children: [.link(title: "Apple", url: URL(string: "https://apple.com")!),
                                                                                .link(title: "Swift", url: URL(string: "https://swift.org")!)])],
                           history: [HistoryEntry(url: URL(string: "https://swift.org")!, title: "Swift", lastVisit: .now, visitCount: 2)])
        }
    }
}
