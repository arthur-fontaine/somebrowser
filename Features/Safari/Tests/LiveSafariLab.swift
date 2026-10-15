import BrowserCore
import Foundation
import Testing
@testable import FeatureSafari

/// Drives the real Safari data through the feature's store, on throwaway favorites only ("<Brand.name> lab…"). Off by
/// default: `SAFARI_LAB=add:<title>`, `remove:<title>` or `status`, then watch SafariBookmarksSyncAgent's log.
@Test(.enabled(if: ProcessInfo.processInfo.environment["SAFARI_LAB"] != nil))
func safariLab() async throws {
    let home = FileManager.default.homeDirectoryForCurrentUser
    let store = SafariStore(folders: SafariFolders(library: SafariAccess.Folder.library.url(home: home),
                                                   container: SafariAccess.Folder.container.url(home: home)),
                            backups: FileManager.default.temporaryDirectory.appendingPathComponent("safari-lab-backups"), localDeviceName: nil)
    let prefix = "\(Brand.name) lab"
    let action = ProcessInfo.processInfo.environment["SAFARI_LAB"]!
    let (verb, title) = (String(action.prefix { $0 != ":" }), String(action.drop { $0 != ":" }.dropFirst()))
    try #require(verb == "status" || title.hasPrefix(prefix), "lab favorites only")
    /// What the feature does after an edit: ask Safari to sync until its agent has taken the records.
    func upload() async throws {
        let start = Date()
        for delay in [2, 5, 10, 20, 40, 80] {
            try await Task.sleep(for: .seconds(delay))
            let pending = try store.pendingChanges()
            print("LAB after \(Int(Date().timeIntervalSince(start))) s: \(pending) change records waiting")
            if pending == 0 { return }
            SafariStore.askSafariToSync()
        }
    }
    switch verb {
    case "add":
        print("LAB added", try store.addFavorite(title: title, url: URL(string: "https://example.com/somebrowser-lab")!).id)
        try await upload()
    case "remove":
        let match = try store.favorites().filter { $0.title == title }
        for f in match { try store.removeFavorite(id: f.id) }
        print("LAB removed", match.count)
        try await upload()
    default:
        let root = try PropertyListSerialization.propertyList(from: Data(contentsOf: store.bookmarksFile), format: nil) as! NSDictionary
        let bar = try SafariStore.bar(in: root)
        for leaf in bar["Children"] as? [NSDictionary] ?? [] {
            guard let name = (leaf["URIDictionary"] as? NSDictionary)?["title"] as? String, name.hasPrefix(prefix) else { continue }
            print("LAB favorite", name, "in iCloud:", (leaf["Sync"] as? NSDictionary)?["ServerID"] != nil)
        }
        let changes = (root["Sync"] as? NSDictionary)?["Changes"] as? [NSDictionary] ?? []
        print("LAB pending changes", changes.map { "\($0["Type"] ?? "?") \($0["BookmarkUUID"] ?? "?")" })
    }
}
