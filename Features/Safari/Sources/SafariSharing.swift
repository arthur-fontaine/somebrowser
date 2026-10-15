import BrowserCore
import Foundation

/// This browser on the iPhone: its open tabs as a Tab Group named after this Mac (`safari.share-tabs`), its history in
/// Safari's (`safari.share-history`). Written into Safari's databases the way Safari writes; they go to iCloud with
/// Safari's next sync of each (its own activity, launch, display sleep or wake, or a change from the iPhone).
/// Private windows are never shared.
extension SafariFeature {
    static let sharedTabsLimit = 300

    func startSharing() {
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

    /// Every open tab of normal windows, in sidebar order, web pages only.
    func sharedTabs() -> [SafariBookmark] {
        var seen = Set<UUID>()
        var out: [SafariBookmark] = []
        for space in context.tabs.spaces {
            for tab in context.tabs.orderedTabs(in: space.id, includeFavorites: true) where !tab.isPrivate && seen.insert(tab.id).inserted {
                guard let url = tab.live?.url ?? tab.url, ["http", "https"].contains(url.scheme ?? "") else { continue }
                let title = tab.displayTitle
                out.append(SafariBookmark(id: SafariStore.tabRowID(tab: tab.id, url: url, title: title), title: title, url: url))
                if out.count == Self.sharedTabsLimit { return out }
            }
        }
        return out
    }

    func mirrorTabs() async {
        guard let store, context.settings.bool("safari.share-tabs") else { return }
        let (tabs, title) = (sharedTabs(), sharedGroupTitle)
        await Task.detached(priority: .utility) { try? store.mirrorTabGroup(title: title, tabs: tabs) }.value
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
            Task.detached(priority: .utility) { try? store.addVisits(visits) }
        }
        if !pendingVisits.isEmpty { scheduleVisitFlush() }
    }
}
