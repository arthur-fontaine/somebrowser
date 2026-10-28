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
    private var walWatcher: DispatchSourceFileSystemObject?
    private var pendingRefresh = false
    private var pendingGroupsRefresh = false
    private var upload: Task<Void, Never>?
    var mirrorTask: Task<Void, Never>?
    var flushTask: Task<Void, Never>?
    var pendingVisits: [UUID: SafariVisit] = [:]
    var visitQueue: [SafariVisit] = []
    /// Tabs change in bursts: mirror once they settle. Visits are written in batches.
    var mirrorDelay: Duration = .seconds(10)
    var visitFlushDelay: Duration = .seconds(20)
    let backgroundSync = SafariBackgroundSync()
    /// The shared Tab Group's rows, by iCloud record, and the tabs here they stand for (`SafariSharing`); nil until
    /// the browser's tabs first set the group.
    var sharedRows: [String: UUID]?
    /// Records missing from the group, since when: closed elsewhere once a second look agrees.
    var missingRows: [String: Date] = [:]
    var remoteCloseDelay: TimeInterval = 5
    /// Odd while a mirror runs: a refresh that overlapped one doesn't read remote changes from it.
    var mirrorRevision = 0
    /// The last history generation written here: waiting until Safari uploads it.
    var historyGeneration = 0
    /// Swapped in tests, which mustn't reach the real Safari.
    var askSafariToSync: @Sendable () -> Void = SafariStore.askSafariToSync
    /// If Safari wasn't listening, ask again until the agent has taken the records.
    var uploadAttempts: [Duration] = [1, 5, 10, 20, 40, 80, 160].map { .seconds($0) }
    var reloadGrace: Duration = .milliseconds(500)
    static let cloudTabsFlag = "safari.cloud-tabs"

    public convenience init(context: FeatureContext) {
        let grants = context.dataDirectory.appendingPathComponent("Grants")
        // A stand-in Safari home for running the app in tests: its folders count as picked, so nothing is asked.
        if let home = ProcessInfo.processInfo.environment["BROWSER_SAFARI_HOME"] {
            self.init(context: context, access: SafariAccess(grants: grants, home: URL(fileURLWithPath: home), choose: { _, url, _ in url }))
        } else {
            self.init(context: context, access: SafariAccess(grants: grants))
        }
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
        context.ui.contribute("start-page.suggestions", id: "safari.connect", order: 10) { [weak self] window in
            if model.hasAccess == false {
                PageCard(symbol: "safari", title: "Sync with Safari on your iPhone") { self?.connect() }
            }
        }
        context.ui.contribute("start-page.extras", id: "safari.start", order: 10) { [weak self] window in
            SafariStartSection(model: model, window: window,
                               open: { url, newTab in self?.open(url, in: window, newTab: newTab) },
                               openInNewWindow: { url in
                                   self?.context.shell?.openWindow(spaceID: window.spaceID, isPrivate: window.isPrivate, initialURL: url)
                               },
                               delete: { self?.removeFavorite($0) })
        }
        let runtime = context.runtime
        context.ui.contribute(.overlay, id: "safari.cloud-tabs", order: 75) { [weak self] window in
            CloudTabsPanel(model: model, window: window, runtime: runtime, open: { self?.openCloudTab($0, in: window, select: $1) })
        }
        context.ui.contribute("sidebar.footer", id: "safari.cloud-tabs.button", order: 30) { window in
            if !window.isPrivate, !model.devices.isEmpty || !model.tabGroups.isEmpty {
                ChromeButton(systemImage: "icloud", help: "iCloud Tabs") { window.toggle(flag: Self.cloudTabsFlag) }
            }
        }
        startSharing()
        backgroundSync.isPending = { [weak self] in self?.somethingWaits() ?? false }
        backgroundSync.whenLaunched = { [weak self] in self?.uploadEdits() }
        if access.isConnected, let folders = access.restore() { use(folders) } else { model.hasAccess = false }
    }

    /// Asks for whatever folder isn't granted yet; true once Safari's library is readable.
    @discardableResult
    func connect() -> Bool {
        guard let folders = access.request() else { return false }
        access.isConnected = true
        use(folders)
        return true
    }

    /// Safari's library to import from, without syncing: only the library folder is asked for, for importing.
    func importStore() -> SafariStore? {
        if let store { return store }
        guard let folders = access.restore() ?? access.request([.library], for: .import) else { return nil }
        return SafariStore(folders: folders, backups: context.dataDirectory.appendingPathComponent("Backups"), localDeviceName: nil)
    }

    func disconnect() {
        access.forget()
        watchers.forEach { $0.cancel() }
        watchers = []
        walWatcher?.cancel()
        walWatcher = nil
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
        watchTabGroups()
        refresh()  // first: applies what other devices changed in the shared group meanwhile
        scheduleTabMirror()
    }

    func refresh() {
        guard let store else { return }
        let revision = mirrorRevision
        Task.detached(priority: .utility) { [weak self] in
            let access = store.hasAccess
            let favorites = access ? (try? store.favorites()) ?? [] : []
            let devices = (try? store.cloudTabs()) ?? []
            let groups = (try? store.tabGroups()) ?? []
            let history = access ? (try? store.history()) ?? [] : []
            await MainActor.run {
                guard let self, self.store?.folders == store.folders else { return }
                self.model.hasAccess = access
                self.model.favorites = favorites
                self.model.devices = devices
                self.model.history = history
                self.use(groups, readAt: revision)
            }
        }
    }

    /// Only the Tab Groups: what the sync agent writes as other devices change them.
    func refreshTabGroups() {
        guard let store else { return }
        let revision = mirrorRevision
        Task.detached(priority: .utility) { [weak self] in
            let groups = (try? store.tabGroups()) ?? []
            await MainActor.run {
                guard let self, self.store?.folders == store.folders else { return }
                self.use(groups, readAt: revision)
            }
        }
    }

    /// Safari's groups for the panel; ours (named after this Mac) for the tabs here, unless a mirror overlapped the read.
    private func use(_ groups: [SafariTabGroup], readAt revision: Int) {
        model.tabGroups = groups.filter { $0.title != sharedGroupTitle }
        if let ours = groups.first(where: { $0.title == sharedGroupTitle }), revision == mirrorRevision, revision % 2 == 0 {
            applyRemoteTabChanges(ours)
        }
    }

    /// Safari replaces its files atomically and the sync agent writes the databases: watch the folders, debounce.
    private func watch(_ folders: [URL]) {
        for dir in folders {
            let fd = Darwin.open(dir.path, O_EVTONLY)
            guard fd >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: .main)
            source.setEventHandler { [weak self] in
                guard let self else { return }
                if self.walWatcher == nil { self.watchTabGroups() }  // the WAL came back
                guard !self.pendingRefresh else { return }
                self.pendingRefresh = true
                // Weakly: a refresh must not keep the feature (and its context) past the runtime.
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.pendingRefresh = false; self?.refresh() }
            }
            source.setCancelHandler { close(fd) }
            source.resume()
            watchers.append(source)
        }
    }

    /// The sync agent appends other devices' Tab Group changes to SafariTabs.db's WAL, which the folder watch doesn't
    /// see (a remote close took 50 s to show, seen live). Re-armed when the WAL is removed and comes back.
    private func watchTabGroups() {
        walWatcher?.cancel()
        walWatcher = nil
        guard let file = store?.tabGroupsFile else { return }
        let fd = Darwin.open(file.path + "-wal", O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .extend, .delete, .rename], queue: .main)
        source.setEventHandler { [weak self, weak source] in
            guard let self, let source else { return }
            if !source.data.isDisjoint(with: [.delete, .rename]) {
                source.cancel()
                if self.walWatcher === source { self.walWatcher = nil }
            }
            guard !self.pendingGroupsRefresh else { return }
            self.pendingGroupsRefresh = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.pendingGroupsRefresh = false; self?.refreshTabGroups() }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        walWatcher = source
    }

    func open(_ url: URL, in window: BrowserWindowState, newTab: Bool) {
        if !newTab, let tab = context.runtime.selectedTab(in: window), tab.url == nil {
            context.runtime.navigate(tab, to: url)
        } else {
            context.runtime.openTab(url, in: window)
        }
    }

    /// An iCloud tab: the tab here already showing it, else a new one (the blank one when the start page is up).
    func openCloudTab(_ url: URL, in window: BrowserWindowState, select: Bool = true) {
        let runtime = context.runtime
        if let tab = runtime.tabs.tabs(matching: url, in: window.spaceID).first(where: { $0.isPrivate == window.isPrivate }) {
            if select { runtime.select(tab.id, in: window) }
        } else if select {
            runtime.open(url, fillingBlankTabIn: window)
        } else {
            runtime.openTab(url, in: window, select: false)
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
        requestBackgroundSync()
    }
}

/// Safari in the import sheet: its bookmarks and history (this Mac and the iPhone), through the same folder grants.
final class SafariImportSource: BrowserImportSource {
    let name = "Safari"
    let bundleIdentifier = "com.apple.Safari"
    private weak var feature: SafariFeature?

    init(feature: SafariFeature) { self.feature = feature }

    func importData() async -> ImportableData? {
        guard let store = feature?.importStore() else { return nil }
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
    var history: [HistoryEntry] = [] {
        didSet { historyText = history.map { Array(($0.title + "\n" + $0.url.absoluteString).lowercased().utf8) } }
    }
    /// Each entry's title and address, lowercased once: the command bar looks through all of them on every keystroke.
    @ObservationIgnored private(set) var historyText: [[UInt8]] = []

    /// The iPhone's tabs, last looked at first, one per address (every device's when there's no iPhone). Tabs Safari
    /// never timed come after, in their device's order.
    var recentTabs: [SafariBookmark] {
        let phones = devices.filter(\.isPhone)
        var seen = Set<URL>()
        return (phones.isEmpty ? devices : phones).flatMap(\.tabs).enumerated().sorted { a, b in
            switch (a.element.lastViewed, b.element.lastViewed) {
            case let (x?, y?) where x != y: x > y
            case (_?, nil): true
            case (nil, _?): false
            default: a.offset < b.offset
            }
        }.map(\.element).filter { seen.insert($0.url).inserted }
    }

    /// What `recentTabs` holds, as a heading.
    var recentTabsTitle: String { devices.contains(where: \.isPhone) ? "iPhone Tabs" : "iCloud Tabs" }
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
        let needle = Array(query.lowercased().trimmingCharacters(in: .whitespaces).utf8)
        guard needle.count >= 2 else { return [] }
        var out: [OmniboxItem] = []
        // Only text containing the query scores 0.6, so the rest is skipped by a byte search (20,000 pages: ~3 ms, where
        // scoring each took ~240 ms).
        for (i, text) in model.historyText.enumerated() where Self.contains(text, needle) {
            let entry = model.history[i]
            let score = max(FuzzyMatch.score(query, in: entry.title), FuzzyMatch.score(query, in: entry.url.absoluteString) * 0.9)
            guard score >= 0.6 else { continue }
            let runtime = self.runtime
            out.append(OmniboxItem(id: "safari:" + entry.url.absoluteString, title: entry.title.isEmpty ? entry.url.absoluteString : entry.title,
                                   subtitle: entry.url.host(), icon: .favicon(entry.url), kind: "Safari", score: score * 0.6,
                                   fill: entry.url.absoluteString) { w in
                runtime.openTab(entry.url, in: w)
            })
            if out.count >= 5 { break }
        }
        return out
    }

    static func contains(_ text: [UInt8], _ needle: [UInt8]) -> Bool {
        text.withUnsafeBytes { t in needle.withUnsafeBytes { n in memmem(t.baseAddress, t.count, n.baseAddress, n.count) != nil } }
    }
}
