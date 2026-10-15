import BrowserCore
import Foundation

/// This browser on the iPhone: its open tabs as a Tab Group named after this Mac (`safari.share-tabs`), its history in
/// Safari's (`safari.share-history`). Written into Safari's databases as Safari writes them; they go to iCloud with
/// Safari's next sync of each (its own activity, launch, display sleep or wake, or a change from the iPhone).
/// Private windows are never shared.
extension SafariFeature {
    static let sharedTabsLimit = 300

    func startSharing() {
        loadSharedRows()
        context.events.subscribe(TabNavigated.self) { [weak self] e in
            self?.navigated(e)
            self?.scheduleTabMirror()
        }
        context.events.subscribe(TabFinishedLoading.self) { [weak self] e in
            self?.finishedLoading(e.tabID)
            self?.scheduleTabMirror()
        }
        context.events.subscribe(TabOpened.self) { [weak self] _ in self?.scheduleTabMirror() }
        context.events.subscribe(TabsClosed.self) { [weak self] _ in self?.scheduleTabMirror() }
        context.events.subscribe(AppWillTerminate.self) { [weak self] _ in self?.flushVisits(everything: true) }
    }

    /// The Tab Group's name: this Mac's name, as Safari names it in iCloud Tabs.
    var sharedGroupTitle: String { store?.localDeviceName ?? "Mac" }

    // MARK: Tabs

    func scheduleTabMirror() {
        guard store?.tabGroupsFile != nil, context.settings.bool("safari.share-tabs") else { return }
        mirrorTask?.cancel()
        let delay = mirrorDelay
        mirrorTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self?.mirrorTabs()
        }
    }

    /// Every open tab of normal windows, in sidebar order, web pages only, with its record in the group if it has one.
    func sharedTabs() -> [(row: SafariBookmark, tab: UUID)] {
        let records = Dictionary((sharedRows ?? [:]).map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        var seen = Set<UUID>()
        var out: [(row: SafariBookmark, tab: UUID)] = []
        for space in context.tabs.spaces {
            for tab in context.tabs.orderedTabs(in: space.id, includeFavorites: true) where !tab.isPrivate && seen.insert(tab.id).inserted {
                guard let url = tab.live?.url ?? tab.url, ["http", "https"].contains(url.scheme ?? "") else { continue }
                // Closed elsewhere, waiting for a second look: not written back meanwhile.
                if let record = records[tab.id], missingRows[record] != nil { continue }
                out.append((SafariBookmark(id: SafariStore.tabRowID(tab: tab.id, url: url), title: tab.displayTitle, url: url,
                                           serverID: records[tab.id]), tab.id))
                if out.count == Self.sharedTabsLimit { return out }
            }
        }
        return out
    }

    /// Through Safari's own code (`SafariTabGroupWriter`): rows written otherwise never upload.
    func mirrorTabs() async {
        guard let file = store?.tabGroupsFile, context.settings.bool("safari.share-tabs"),
              let writer = SafariTabGroupWriter(database: file) else { return }
        mirrorRevision += 1
        defer { mirrorRevision += 1 }
        let shared = sharedTabs()
        guard let result = try? await writer.mirror(title: sharedGroupTitle, tabs: shared.map(\.row)) else { return }
        var rows: [String: UUID] = [:]
        for (record, entry) in zip(result.serverIDs, shared) { if let record { rows[record] = entry.tab } }
        for (record, tab) in sharedRows ?? [:] where missingRows[record] != nil { rows[record] = tab }
        sharedRows = rows
        saveSharedRows()
        if result.changed { requestBackgroundSync() }
    }

    /// The group as other devices left it, by iCloud record (this Mac's row ids change when the agent recreates a row).
    /// A record gone since the last mirror was closed there, so is its tab here, once a second look agrees (the agent
    /// may rewrite a row in two steps). A record this browser didn't write was opened there: it opens here in the
    /// background, and keeps its row.
    func applyRemoteTabChanges(_ group: SafariTabGroup) {
        guard context.settings.bool("safari.share-tabs"), var rows = sharedRows else { return }
        let present = Set(group.tabs.compactMap(\.serverID))
        let now = Date()
        var changed = false
        for record in missingRows.keys where present.contains(record) { missingRows[record] = nil }
        for (record, tab) in rows where !present.contains(record) {
            if let since = missingRows[record], now.timeIntervalSince(since) >= remoteCloseDelay {
                missingRows[record] = nil
                rows[record] = nil
                changed = true
                if context.tabs.tab(tab)?.isPrivate == false { context.runtime.close(tab) }
            } else if missingRows[record] == nil {
                missingRows[record] = now
                DispatchQueue.main.asyncAfter(deadline: .now() + remoteCloseDelay + 0.2) { [weak self] in self?.refresh() }
            }
        }
        if let window = context.windows.first(where: { !$0.isPrivate }) {
            for remote in group.tabs {
                guard let record = remote.serverID, rows[record] == nil else { continue }
                rows[record] = context.runtime.openTab(remote.url, in: window, select: false).id
                changed = true
            }
        }
        guard changed else { return }
        sharedRows = rows
        saveSharedRows()
    }

    private var sharedRowsFile: URL { context.dataDirectory.appendingPathComponent("SharedTabs.json") }

    func loadSharedRows() {
        guard let data = try? Data(contentsOf: sharedRowsFile), let saved = try? JSONDecoder().decode(SharedRows.self, from: data) else { return }
        sharedRows = saved.rows
    }

    private func saveSharedRows() {
        guard let rows = sharedRows, let data = try? JSONEncoder().encode(SharedRows(rows: rows)) else { return }
        try? FileManager.default.createDirectory(at: context.dataDirectory, withIntermediateDirectories: true)
        try? data.write(to: sharedRowsFile, options: .atomic)
    }

    // MARK: Safari in the background

    /// Gets Safari to sync what was written here (`SafariBackgroundSync`), unless turned off.
    func requestBackgroundSync() {
        guard store != nil, context.settings.bool("safari.background-sync") else { return }
        backgroundSync.request()
    }

    /// Favorites' change records, the shared Tab Group's rows or visits written here, not in iCloud yet.
    func somethingWaits() -> Bool {
        guard let store else { return false }
        if ((try? store.pendingChanges()) ?? 0) > 0 { return true }
        if (try? store.tabGroupPending(title: sharedGroupTitle)) == true { return true }
        return historyGeneration > ((try? store.historySyncedGeneration()) ?? .max)
    }

    // MARK: History

    func navigated(_ e: TabNavigated) {
        guard store != nil, !e.isPrivate, context.settings.bool("safari.share-history"),
              ["http", "https"].contains(e.url.scheme ?? "") else { return }
        if let earlier = pendingVisits.removeValue(forKey: e.tabID) { visitQueue.append(earlier) }
        pendingVisits[e.tabID] = SafariVisit(url: e.url, title: "", date: Date())
        scheduleVisitFlush()
    }

    /// The page's title is known once it loaded: the visit is complete.
    func finishedLoading(_ tabID: UUID) {
        guard var visit = pendingVisits[tabID], let live = context.tabs.tab(tabID)?.live, live.url == visit.url else { return }
        visit.title = live.title
        pendingVisits[tabID] = nil
        visitQueue.append(visit)
        scheduleVisitFlush()
    }

    func scheduleVisitFlush() {
        guard flushTask == nil else { return }
        let delay = visitFlushDelay
        flushTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            self?.flushTask = nil
            self?.flushVisits(everything: false)
        }
    }

    /// Writes the complete visits, and pages that never finished loading after a while; `everything` at quit.
    func flushVisits(everything: Bool) {
        guard let store else { return }
        let stale = Date().addingTimeInterval(-30)
        for (id, visit) in pendingVisits where everything || visit.date < stale {
            visitQueue.append(visit)
            pendingVisits[id] = nil
        }
        guard !visitQueue.isEmpty else { return }
        let visits = visitQueue
        visitQueue = []
        if everything {
            try? store.addVisits(visits)
        } else {
            Task { [weak self] in
                let generation = await Task.detached(priority: .utility) { (try? store.addVisits(visits)) ?? 0 }.value
                guard let self, generation > 0 else { return }
                self.historyGeneration = max(self.historyGeneration, generation)
                self.requestBackgroundSync()
            }
        }
        if !pendingVisits.isEmpty { scheduleVisitFlush() }
    }
}

/// The shared group's records and their tabs here as of the last mirror, kept between launches (`SharedTabs.json`).
nonisolated struct SharedRows: Codable {
    var rows: [String: UUID]
}
