import AppKit
import BrowserCore
import SwiftUI

/// "Make it easier to switch" (Radian, 08-13): bookmarks, history and extensions from Chrome, Arc, Dia, Atlas,
/// Helium and other Chromium browsers, and from sources other features offer (`BrowserImportSource`: Safari). Bookmarks land as a pinned folder in the current space (as Arc does);
/// extensions are listed with one-click "Add" (installing needs the user's click on the Web Store).
public final class ImportFeature: BrowserFeature {
    let context: FeatureContext
    let model = ImportModel()
    /// Overridable in tests.
    var discover: () -> [SourceProfile] = { ChromiumImport.profiles() }
    var reader: @Sendable (URL) -> ImportedData = { ChromiumImport.read($0) }
    var keychainPassword: @Sendable (String) -> Data? = { ChromiumCookies.password(service: $0) }
    private var contributed: [String: BrowserImportSource] = [:]
    let grants: FolderGrants
    static let sheetFlag = "import.sheet"

    public convenience init(context: FeatureContext) {
        self.init(context: context, grants: FolderGrants(directory: context.dataDirectory.appendingPathComponent("Grants")))
    }

    init(context: FeatureContext, grants: FolderGrants) {
        self.context = context
        self.grants = grants
    }

    public func activate() {
        context.commands.handle("import.open") { [weak self] inv in self?.open(in: inv.window) }
        let model = self.model
        context.ui.contribute(.overlay, id: "import.sheet", order: 90) { [weak self] window in
            ImportSheet(model: model, window: window,
                        select: { self?.select($0) },
                        allowAccess: { self?.allowAccess($0) },
                        start: { self?.start(into: window) },
                        addExtension: { self?.addExtension($0, in: window) },
                        close: { window.flags.remove(Self.sheetFlag) })
        }
    }

    func open(in window: BrowserWindowState?) {
        guard let window else { return }
        let sources = context.runtime.capabilities.all(BrowserImportSource.self)
        let offered = sources.map { source in
            SourceProfile(source: BrowserSource(id: "contributed.\(source.name)", name: source.name, bundleID: source.bundleIdentifier, userData: []),
                          name: "Default", directory: URL(string: "contributed:\(source.name.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "")")!,
                          isContributed: true)
        }
        contributed = Dictionary(uniqueKeysWithValues: zip(offered.map(\.id), sources))
        grants.restoreAll()
        model.profiles = offered + discover()
        model.canImportCookies = context.engine is EngineCookieStore
        model.result = nil
        window.flags.insert(Self.sheetFlag)
        // A browser read without asking: another feature's source may ask for access, which waits for a click on it.
        if let first = model.profiles.first(where: { !$0.isContributed && !$0.isLocked }) { select(first) }
    }

    /// The open panel on a locked browser's folder; once allowed, its profiles replace it and the first is selected.
    func allowAccess(_ profile: SourceProfile) {
        let message = "macOS keeps \(profile.source.name)'s data from other apps. Click Allow to import from it."
        guard grants.request(profile.directory, id: profile.source.id, message: message) else { return }
        let found = discover().filter { $0.source.id == profile.source.id }
        guard let index = model.profiles.firstIndex(of: profile), !found.contains(where: \.isLocked) else { return }
        model.profiles.replaceSubrange(index...index, with: found)
        if let first = found.first { select(first) }
    }

    /// Reads the profile off the main thread so the sheet shows what will be imported.
    func select(_ profile: SourceProfile) {
        model.selected = profile
        model.preview = nil
        guard !profile.isLocked else { return }
        if let source = contributed[profile.id] {
            Task { [weak self] in
                let data = await source.importData()
                guard self?.model.selected == profile else { return }
                self?.model.preview = ImportedData(bookmarks: data?.bookmarks ?? [], history: data?.history ?? [])
            }
            return
        }
        let reader = self.reader
        Task.detached(priority: .userInitiated) { [weak self] in
            let data = reader(profile.directory)
            await MainActor.run {
                guard self?.model.selected == profile else { return }
                self?.model.preview = data
            }
        }
    }

    func start(into window: BrowserWindowState) {
        guard let profile = model.selected, let data = model.preview else { return }
        Task { await self.importData(data, from: profile, into: window) }
    }

    func importData(_ data: ImportedData, from profile: SourceProfile, into window: BrowserWindowState) async {
        model.isImporting = true
        defer { model.isImporting = false }
        var result = ImportModel.Result()
        if model.includeBookmarks, !data.bookmarks.isEmpty {
            let name = profile.source.name + (profile.name == "Default" || profile.name.isEmpty ? "" : " (\(profile.name))")
            let folder = context.runtime.tabs.insertFolder(Folder(name: name, icon: "square.and.arrow.down", isCollapsed: true),
                                                          into: .section(window.spaceID, .pinned))
            result.bookmarks = insert(data.bookmarks, into: folder.id)
        }
        if model.includeHistory, let history = context.runtime.capabilities.history {
            // In chunks so the window keeps responding during large imports.
            for start in stride(from: 0, to: data.history.count, by: 5000) {
                history.importEntries(Array(data.history[start..<min(start + 5000, data.history.count)]))
                await Task.yield()
            }
            result.history = data.history.count
        }
        if model.includeCookies, !data.cookies.isEmpty, let store = context.engine as? EngineCookieStore {
            // Off the main thread: reading the Keychain waits for the user to answer macOS's prompt.
            let rows = data.cookies, service = profile.source.keychainService, password = keychainPassword
            let cookies = await Task.detached(priority: .userInitiated) { () -> [BrowserCookie]? in
                guard let password = password(service) else { return nil }
                let key = ChromiumCookies.key(password: password)
                return rows.compactMap { ChromiumCookies.cookie($0, key: key) }
            }.value
            if let cookies { result.cookies = await store.addCookies(cookies) } else { result.cookiesLocked = true }
        }
        result.extensions = model.includeExtensions && context.engine.capabilities.contains(.chromeExtensions) ? data.extensions : []
        model.result = result
        context.notify("Imported from \(profile.source.name)", systemImage: "square.and.arrow.down")
    }

    private func insert(_ bookmarks: [ImportedBookmark], into folder: NodeID) -> Int {
        var count = 0
        for bookmark in bookmarks {
            switch bookmark {
            case .link(let title, let url):
                context.runtime.tabs.insert(BrowserTab(url: url, title: title), into: .node(folder))
                count += 1
            case .folder(let title, let children):
                let sub = context.runtime.tabs.insertFolder(Folder(name: title.isEmpty ? "Folder" : title, isCollapsed: true), into: .node(folder))
                count += insert(children, into: sub.id)
            }
        }
        return count
    }

    /// The Web Store page, where one click installs it again.
    func addExtension(_ ext: BrowserExtension, in window: BrowserWindowState) {
        guard let url = URL(string: "https://chromewebstore.google.com/detail/\(ext.id)") else { return }
        context.runtime.openTab(url, in: window)
        model.added.insert(ext.id)
    }
}

@Observable
final class ImportModel {
    struct Result: Equatable {
        var bookmarks = 0
        var history = 0
        var cookies = 0
        /// The source's Keychain item couldn't be read (the user refused, or it isn't there).
        var cookiesLocked = false
        var extensions: [BrowserExtension] = []
    }

    var profiles: [SourceProfile] = []
    var selected: SourceProfile?
    var preview: ImportedData?
    var includeBookmarks = true
    var includeHistory = true
    var includeExtensions = true
    var includeCookies = true
    var canImportCookies = false
    var isImporting = false
    var result: Result?
    var added: Set<String> = []
}
