import AppKit
import BrowserCore
import Foundation

/// Safari's two folders, opened for this process.
nonisolated struct SafariFolders: Equatable, Sendable {
    /// `~/Library/Safari`: Bookmarks.plist, History.db.
    var library: URL
    /// Safari's container: CloudTabs.db. Optional: favorites and history work without it.
    var container: URL?
}

/// Safari's folders without Full Disk Access: picking a folder in an open panel is explicit consent, which macOS
/// honors even for Safari's protected data, and a security-scoped bookmark keeps the grant across launches. One
/// click per folder.
@MainActor
final class SafariAccess {
    enum Folder: String, CaseIterable, Sendable {
        case library, container

        func url(home: URL) -> URL {
            switch self {
            case .library: home.appendingPathComponent("Library/Safari", isDirectory: true)
            case .container: home.appendingPathComponent("Library/Containers/com.apple.Safari/Data/Library/Safari", isDirectory: true)
            }
        }

        var message: String {
            switch self {
            case .library: "\(Brand.name) syncs with Safari on your iPhone through Safari's own iCloud data. Click Allow to share Safari's bookmarks and history."
            case .container: "Click Allow to share the iPhone's open tabs (iCloud Tabs)."
            }
        }
    }

    let grants: URL
    let home: URL
    /// Shows the open panel on a folder; returns what the user picked.
    var choose: (Folder, URL) -> URL?
    /// Granted folders, as the URLs that carry the grant (stopped on `forget`).
    private var opened: [Folder: URL] = [:]

    init(grants: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser, choose: ((Folder, URL) -> URL?)? = nil) {
        self.grants = grants
        self.home = home
        self.choose = choose ?? Self.panel
    }

    /// The folders granted earlier, or nil if Safari's library was never granted.
    func restore() -> SafariFolders? {
        for folder in Folder.allCases where opened[folder] == nil {
            if let url = resolve(folder) { opened[folder] = url }
        }
        return folders
    }

    /// Asks for each folder not granted yet. Picking another folder than Safari's doesn't count.
    func request() -> SafariFolders? {
        _ = restore()
        for folder in Folder.allCases where opened[folder] == nil {
            let expected = folder.url(home: home)
            guard let chosen = choose(folder, expected) else { break }
            guard Self.same(chosen, expected) else { continue }
            if let data = try? chosen.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) {
                try? FileManager.default.createDirectory(at: grants, withIntermediateDirectories: true)
                try? data.write(to: file(folder), options: .atomic)
            }
            opened[folder] = chosen
        }
        return folders
    }

    func forget() {
        for url in opened.values { url.stopAccessingSecurityScopedResource() }
        opened = [:]
        for folder in Folder.allCases { try? FileManager.default.removeItem(at: file(folder)) }
    }

    private var folders: SafariFolders? {
        guard opened[.library] != nil else { return nil }
        return SafariFolders(library: Folder.library.url(home: home), container: opened[.container].map { _ in Folder.container.url(home: home) })
    }

    private func file(_ folder: Folder) -> URL { grants.appendingPathComponent("\(folder.rawValue).grant") }

    private func resolve(_ folder: Folder) -> URL? {
        guard let data = try? Data(contentsOf: file(folder)) else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &stale),
              Self.same(url, folder.url(home: home)) else { return nil }
        _ = url.startAccessingSecurityScopedResource()  // for the process lifetime
        if stale, let fresh = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) {
            try? fresh.write(to: file(folder), options: .atomic)
        }
        return url
    }

    static func same(_ a: URL, _ b: URL) -> Bool {
        a.standardizedFileURL.resolvingSymlinksInPath().path == b.standardizedFileURL.resolvingSymlinksInPath().path
    }

    static func panel(_ folder: Folder, at url: URL) -> URL? {
        let panel = NSOpenPanel()
        panel.directoryURL = url
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Allow"
        panel.message = folder.message
        return panel.runModal() == .OK ? panel.url : nil
    }
}
