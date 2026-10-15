import BrowserCore
import Foundation
import SQLite3
import Testing
@testable import FeatureSafari

/// Drives the real Safari data through the feature's store, on throwaway items only ("<Brand.name> lab…"). Off by
/// default: `SAFARI_LAB=add:<title>`, `remove:<title>`, `group:<title>`, `ungroup:<title>`, `visit` or `status`, then
/// watch SafariBookmarksSyncAgent's log.
@MainActor @Test(.enabled(if: ProcessInfo.processInfo.environment["SAFARI_LAB"] != nil))
func safariLab() async throws {
    let home = FileManager.default.homeDirectoryForCurrentUser
    let store = SafariStore(folders: SafariFolders(library: SafariAccess.Folder.library.url(home: home),
                                                   container: SafariAccess.Folder.container.url(home: home)),
                            backups: FileManager.default.temporaryDirectory.appendingPathComponent("safari-lab-backups"), localDeviceName: nil)
    let prefix = "\(Brand.name) lab"
    let action = ProcessInfo.processInfo.environment["SAFARI_LAB"]!
    let (verb, title) = (String(action.prefix { $0 != ":" }), String(action.drop { $0 != ":" }.dropFirst()))
    try #require(verb == "status" || verb == "visit" || title.hasPrefix(prefix), "lab items only")
    /// What the feature does after an edit.
    func upload() async throws {
        let start = Date()
        await store.upload(attempts: [1, 3, 5, 10, 20, 40].map { .seconds($0) }, progress: { pending in
            print("LAB after \(Int(Date().timeIntervalSince(start))) s: \(pending) change records waiting")
        })
    }
    switch verb {
    case "group":
        let tabs = ["one", "two"].map { n in
            let url = URL(string: "https://example.com/somebrowser-lab-\(n)")!
            return SafariBookmark(id: SafariStore.tabRowID(tab: UUID(), url: url, title: "Lab \(n)"), title: "Lab \(n)", url: url)
        }
        let file = try #require(store.tabGroupsFile)
        let writer = try #require(SafariTabGroupWriter(database: file))
        try await writer.mirror(title: title, tabs: tabs)
        print("LAB group written", title, try store.tabGroups().first { $0.title == title }?.tabs.map(\.title) ?? [])
    case "ungroup":
        let file = try #require(store.tabGroupsFile)
        try await SafariTabGroupWriter(database: file)?.remove(title: title)
        print("LAB group removed", title)
    case "visit":
        try store.addVisits([SafariVisit(url: URL(string: "https://example.com/somebrowser-lab-history")!, title: "\(prefix) visit", date: Date())])
        print("LAB visit written")
    case "add":
        print("LAB added", try store.addFavorite(title: title, url: URL(string: "https://example.com/somebrowser-lab")!).id)
        try await upload()
    case "remove":
        let match = try store.favorites().filter { $0.title == title }
        for f in match { try store.removeFavorite(id: f.id) }
        print("LAB removed", match.count)
        try await upload()
    default:
        let root = try PropertyListSerialization.propertyList(from: Data(contentsOf: store.bookmarksFile), options: .mutableContainers, format: nil) as! NSDictionary
        let bar = try SafariStore.bar(in: root)
        for leaf in bar["Children"] as? [NSDictionary] ?? [] {
            guard let name = (leaf["URIDictionary"] as? NSDictionary)?["title"] as? String, name.hasPrefix(prefix) else { continue }
            print("LAB favorite", name, "in iCloud:", (leaf["Sync"] as? NSDictionary)?["ServerID"] != nil)
        }
        let changes = (root["Sync"] as? NSDictionary)?["Changes"] as? [NSDictionary] ?? []
        print("LAB pending changes", changes.map { "\($0["Type"] ?? "?") \($0["BookmarkUUID"] ?? "?")" })
        if let file = store.tabGroupsFile {
            try SafariStore.query(file) { db in
                SafariStore.rows(db, """
                SELECT g.title, t.title, t.server_id IS NOT NULL, t.added FROM bookmarks g JOIN bookmarks t ON t.parent = g.id AND t.type = 0
                WHERE g.type = 1 AND g.title LIKE '\(prefix)%' AND g.deleted = 0 AND t.deleted = 0
                """) { s in
                    print("LAB group", SafariStore.text(s, 0), "tab", SafariStore.text(s, 1), "in iCloud:", sqlite3_column_int(s, 2) != 0, "added:", sqlite3_column_int(s, 3))
                }
            }
        }
    }
}
