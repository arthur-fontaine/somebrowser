import BrowserCore
import Foundation

/// Arc's own sidebar: each Space's pinned tabs and folders, which Arc keeps in `StorableSidebar.json` beside its
/// `User Data`, not in the Chromium profile. As arc-export reads it: `sidebar.containers` holds a `global` entry and one
/// with `spaces` and `items` (lists mixing ids and objects); a Space names its pinned container after a `pinned` marker;
/// items point to their parent (`parentID`) and list their children (`childrenIds`); tabs carry `data.tab.savedURL`.
nonisolated enum ArcSidebar {
    static func file(forProfile profile: URL) -> URL {
        profile.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("StorableSidebar.json")
    }

    /// One folder per Space of the profile (`profileDirectory`: "Default", "Profile 1"…) holding its pinned tabs.
    static func bookmarks(_ file: URL, profileDirectory: String) -> [BookmarkNode] {
        guard let data = try? Data(contentsOf: file), let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let containers = (root["sidebar"] as? [String: Any])?["containers"] as? [Any],
              let main = containers.compactMap({ $0 as? [String: Any] }).first(where: { $0["spaces"] != nil }) else { return [] }
        let items = (main["items"] as? [Any] ?? []).compactMap { $0 as? [String: Any] }
        let byID = Dictionary(items.compactMap { item in (item["id"] as? String).map { ($0, item) } }, uniquingKeysWith: { a, _ in a })

        func children(of id: String) -> [BookmarkNode] {
            let ids = byID[id]?["childrenIds"] as? [String]
                ?? items.filter { $0["parentID"] as? String == id }.compactMap { $0["id"] as? String }
            return ids.compactMap(node)
        }
        func node(_ id: String) -> BookmarkNode? {
            guard let item = byID[id] else { return nil }
            let title = (item["title"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            if let tab = (item["data"] as? [String: Any])?["tab"] as? [String: Any] {
                guard let saved = tab["savedURL"] as? String, let url = URL(string: saved) else { return nil }
                return .link(title: title ?? tab["savedTitle"] as? String ?? saved, url: url)
            }
            let kids = children(of: id)
            return kids.isEmpty ? nil : .folder(title: title ?? "Folder", children: kids)
        }

        let spaces = (main["spaces"] as? [Any] ?? []).compactMap { $0 as? [String: Any] }
        return spaces.enumerated().compactMap { index, space in
            guard profile(of: space) == profileDirectory, let pinned = pinnedContainer(of: space) else { return nil }
            let kids = children(of: pinned)
            return kids.isEmpty ? nil : .folder(title: space["title"] as? String ?? "Space \(index + 1)", children: kids)
        }
    }

    /// The id after the `pinned` marker: `[{"pinned": {}}, "<id>", {"unpinned": {…}}, "<id>"]` (older files: plain strings).
    static func pinnedContainer(of space: [String: Any]) -> String? {
        let ids = space["newContainerIDs"] as? [Any] ?? space["containerIDs"] as? [Any] ?? []
        guard let i = ids.firstIndex(where: { ($0 as? [String: Any])?["pinned"] != nil || $0 as? String == "pinned" }),
              i + 1 < ids.count else { return nil }
        return ids[i + 1] as? String
    }

    /// Spaces of other profiles name their directory; the default profile's don't.
    static func profile(of space: [String: Any]) -> String {
        let custom = ((space["profile"] as? [String: Any])?["custom"] as? [String: Any])?["_0"] as? [String: Any]
        return custom?["directoryBasename"] as? String ?? "Default"
    }
}
