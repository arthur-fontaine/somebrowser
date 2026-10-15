import AppKit
import BrowserCore
import SwiftUI
import SystemConfiguration

/// Safari ⇄ iPhone (Radian, 08-07): Safari's Favorites on the start page, live, and added from here; the iPhone's
/// open tabs ("iCloud Tabs"); Safari's history in the command bar. Works on Safari's own synced files, so iCloud does
/// the syncing; access is two clicks in open panels (`SafariAccess`), not Full Disk Access.
public final class SafariFeature: BrowserFeature {
    let context: FeatureContext
    let model = SafariModel()
    let access: SafariAccess
    var store: SafariStore?
    private var watchers: [DispatchSourceFileSystemObject] = []
    private var pendingRefresh = false
    private var upload: Task<Void, Never>?
    var mirrorTask: Task<Void, Never>?
    var flushTask: Task<Void, Never>?
    var pendingVisits: [UUID: SafariVisit] = [:]
    var visitQueue: [SafariVisit] = []
    /// Tabs change in bursts: mirror once they settle. Visits are written in batches.
    var mirrorDelay: Duration = .seconds(10)
    var visitFlushDelay: Duration = .seconds(20)
    /// Swapped in tests, which mustn't reach the real Safari.
    var askSafariToSync: @Sendable () -> Void = SafariStore.askSafariToSync
    /// If Safari wasn't listening, ask again until the agent has taken the records.
    var uploadAttempts: [Duration] = [1, 5, 10, 20, 40, 80, 160].map { .seconds($0) }
    var reloadGrace: Duration = .milliseconds(500)
    static let cloudTabsFlag = "safari.cloud-tabs"

    public convenience init(context: FeatureContext) {
        self.init(context: context, access: SafariAccess(grants: context.dataDirectory.appendingPathComponent("Grants")))
    }

    init(context: FeatureContext, access: SafariAccess) {
        self.context = context
        self.access = access
    }

    public func activate() {
        context.capabilities.contribute(BrowserImportSource.self, SafariImportSource(feature: self))
        guard context.settings.bool("safari.enabled") else { return }
        context.commands.handle("safari.add-favorite") { [weak self] inv in self?.addCurrentPage(in: inv.window) }
        context.commands.handle("safari.cloud-tabs") { [weak self] inv in
            guard self?.store?.folders.container != nil || self?.connect() == true else { return }
            inv.window?.toggle(flag: Self.cloudTabsFlag)
        }
        context.commands.handle("safari.connect") { [weak self] _ in self?.connect() }
        context.commands.handle("safari.disconnect") { [weak self] _ in self?.disconnect() }
        context.capabilities.contribute(OmniboxProvider.self, SafariHistoryOmnibox(model: model, runtime: context.runtime))

        let model = self.model
        context.ui.contribute("start-page.extras", id: "safari.start", order: 10) { [weak self] window in
            SafariStartSection(model: model, window: window,
                               open: { url, newTab in self?.open(url, in: window, newTab: newTab) },
                               openInNewWindow: { url in
                                   self?.context.shell?.openWindow(spaceID: window.spaceID, isPrivate: window.isPrivate, initialURL: url)
                               },
                               delete: { self?.removeFavorite($0) },
                               connect: { self?.connect() })
        }
        context.ui.contribute(.overlay, id: "safari.cloud-tabs", order: 75) { [weak self] window in
            CloudTabsPanel(model: model, window: window, open: { self?.open($0, in: window, newTab: true) })
        }
        startSharing()
        if let folders = access.restore() { use(folders) } else { model.hasAccess = false }
    }

    /// Asks for whatever folder isn't granted yet; true once Safari's library is readable.
    @discardableResult
    func connect() -> Bool {
        guard let folders = access.request() else { return false }
        use(folders)
        return true
    }

    func disconnect() {
        access.forget()
        watchers.forEach { $0.cancel() }
        watchers = []
        store = nil
        model.hasAccess = false
        model.favorites = []
        model.devices = []
        model.tabGroups = []
        model.history = []
    }

    private func use(_ folders: SafariFolders) {
        guard store?.folders != folders else { return }
        store = SafariStore(folders: folders, backups: context.dataDirectory.appendingPathComponent("Backups"),
                            localDeviceName: SCDynamicStoreCopyComputerName(nil, nil) as String?)
        watchers.forEach { $0.cancel() }
        watchers = []
        watch([folders.library, folders.container].compactMap { $0 })
        refresh()
    }

    func refresh() {
        guard let store else { return }
        Task.detached(priority: .utility) { [weak self] in
            let access = store.hasAccess
            let favorites = access ? (try? store.favorites()) ?? [] : []
            let devices = (try? store.cloudTabs()) ?? []
            let tabGroups = ((try? store.tabGroups()) ?? []).filter { $0.title != store.localDeviceName }  // ours: this browser's tabs
            let history = access ? (try? store.history()) ?? [] : []
            await MainActor.run {
                guard let self, self.store?.folders == store.folders else { return }
                self.model.hasAccess = access
                self.model.favorites = favorites
                self.model.devices = devices
                self.model.tabGroups = tabGroups
                self.model.history = history
            }
        }
    }

    /// Safari replaces its files atomically and the sync agent writes the databases: watch the folders, debounce.
    private func watch(_ folders: [URL]) {
        for dir in folders {
            let fd = Darwin.open(dir.path, O_EVTONLY)
            guard fd >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: .main)
            source.setEventHandler { [weak self] in
                guard let self, !self.pendingRefresh else { return }
                self.pendingRefresh = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.pendingRefresh = false; self.refresh() }
            }
            source.setCancelHandler { close(fd) }
            source.resume()
            watchers.append(source)
        }
    }

    func open(_ url: URL, in window: BrowserWindowState, newTab: Bool) {
        if !newTab, let tab = context.runtime.selectedTab(in: window), tab.url == nil {
            context.runtime.navigate(tab, to: url)
        } else {
            context.runtime.openTab(url, in: window)
        }
    }

    /// A favorite added here appears in Safari and on the iPhone (verified with Safari running).
    func addCurrentPage(in window: BrowserWindowState?) {
        guard let window, let tab = context.runtime.selectedTab(in: window), let url = tab.live?.url ?? tab.url else { return }
        guard store != nil || connect(), let store else { return }
        do {
            let item = try store.addFavorite(title: tab.displayTitle, url: url)
            model.favorites.append(item)
            uploadEdits()
            context.notify("Added to Safari Favorites", systemImage: "star.fill")
        } catch {
            context.notify("Couldn't add to Safari Favorites", systemImage: "exclamationmark.triangle")
        }
    }

    /// Removed here, in Safari and on the iPhone (verified live).
    func removeFavorite(_ favorite: SafariBookmark) {
        guard let store else { return }
        do {
            try store.removeFavorite(id: favorite.id)
            model.favorites.removeAll { $0.id == favorite.id }
            uploadEdits()
        } catch {
            context.notify("Couldn't delete the Safari favorite", systemImage: "exclamationmark.triangle")
        }
    }

    /// Gets the change records just written to iCloud: Safari's agent doesn't watch the file (README, "Writing like Safari").
    func uploadEdits() {
        guard let store else { return }
        upload?.cancel()
        let (ask, attempts, grace) = (askSafariToSync, uploadAttempts, reloadGrace)
        upload = Task.detached(priority: .utility) { await store.upload(attempts: attempts, reloadGrace: grace, ask: ask) }
    }
}

/// Safari in the import sheet: its bookmarks and history (this Mac and the iPhone), through the same folder grants.
final class SafariImportSource: BrowserImportSource {
    let name = "Safari"
    let bundleIdentifier = "com.apple.Safari"
    private weak var feature: SafariFeature?

    init(feature: SafariFeature) { self.feature = feature }

    func importData() async -> ImportableData? {
        guard let feature, feature.store != nil || feature.connect(), let store = feature.store else { return nil }
        return await Task.detached(priority: .userInitiated) {
            guard store.hasAccess else { return nil }
            return ImportableData(bookmarks: (try? store.bookmarkTree()) ?? [], history: (try? store.history(limit: 200_000)) ?? [])
        }.value
    }
}

@Observable
final class SafariModel {
    var hasAccess: Bool?
    var favorites: [SafariBookmark] = []
    var devices: [SafariDevice] = []
    var tabGroups: [SafariTabGroup] = []
    var history: [HistoryEntry] = []
}

/// Safari history in the command bar (this Mac and the iPhone, through iCloud).
final class SafariHistoryOmnibox: OmniboxProvider {
    let model: SafariModel
    unowned let runtime: BrowserRuntime
    init(model: SafariModel, runtime: BrowserRuntime) {
        self.model = model
        self.runtime = runtime
    }

    func items(for query: String, in window: BrowserWindowState) -> [OmniboxItem] {
        guard query.count >= 2 else { return [] }
        var out: [OmniboxItem] = []
        for entry in model.history {
            let score = max(FuzzyMatch.score(query, in: entry.title), FuzzyMatch.score(query, in: entry.url.absoluteString) * 0.9)
            guard score >= 0.6 else { continue }
            let runtime = self.runtime
            out.append(OmniboxItem(id: "safari:" + entry.url.absoluteString, title: entry.title.isEmpty ? entry.url.absoluteString : entry.title,
                                   subtitle: entry.url.host(), icon: .favicon(entry.url), kind: "Safari", score: score * 0.6) { w in
                runtime.openTab(entry.url, in: w)
            })
            if out.count >= 5 { break }
        }
        return out
    }
}
