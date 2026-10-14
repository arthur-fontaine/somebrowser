import AppKit
import Foundation
import Observation
import os

/// Where a new tab goes in the tree.
public enum TabPlacement {
    /// Top of the window's space "Today" list.
    case automatic
    /// Child of a tab (Horse tree).
    case childOf(NodeID)
    /// Sibling right after a node.
    case after(NodeID)
    case container(Container, index: Int?)
}

/// Composition root: owns the model and registries, activates features in generated order, and manages
/// the lifecycle of live engine pages. It never names a feature.
@Observable
public final class BrowserRuntime {
    @ObservationIgnored public let engine: BrowserEngine
    @ObservationIgnored public let settings: SettingsStore
    @ObservationIgnored public let commands = CommandRegistry()
    @ObservationIgnored public let events = EventBus()
    @ObservationIgnored public let capabilities = CapabilityRegistry()
    public let tabs = TabStore()
    public let ui = UIRegistry()
    @ObservationIgnored public let siteSettings: SiteSettingsStore
    @ObservationIgnored public let dataDirectory: URL
    @ObservationIgnored public let manifests: [FeatureManifest]
    public private(set) var windows: [BrowserWindowState] = []
    @ObservationIgnored public weak var shell: ShellServices?
    @ObservationIgnored public private(set) var features: [String: BrowserFeature] = [:]
    /// Order in which features were activated (ids).
    @ObservationIgnored public private(set) var activationOrder: [String] = []
    @ObservationIgnored public let log = Logger(subsystem: Brand.bundleIdentifier, category: "runtime")

    @ObservationIgnored private let registrations: [FeatureRegistration]
    @ObservationIgnored private var bindings: [NodeID: LiveTabBinding] = [:]
    @ObservationIgnored private var persistence: SessionPersistence?

    public init(engine: BrowserEngine, registrations: [FeatureRegistration], settingOverrides: [String: SettingValue] = [:],
                dataDirectory: URL, userDefaults: UserDefaults?, persistSession: Bool = true) {
        self.engine = engine
        self.registrations = registrations
        self.dataDirectory = dataDirectory
        self.manifests = registrations.map(\.manifest)
        self.settings = SettingsStore(storage: userDefaults)
        for m in manifests {
            commands.register(m.commands)
            settings.register(m.settings, overrides: settingOverrides)
        }
        try? FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
        siteSettings = SiteSettingsStore(url: persistSession ? dataDirectory.appendingPathComponent("site-settings.json") : nil)
        if persistSession { persistence = SessionPersistence(url: dataDirectory.appendingPathComponent("session.json")) }
        tabs.onTabsRemoved = { [weak self] removed in self?.tabsRemoved(removed) }
        tabs.onChange = { [weak self] in self?.persistence?.scheduleSave { self?.sessionSnapshot() } }
        engine.hooks.userAgentBrand = Brand.userAgentBrand
    }

    // MARK: Features

    public func activateFeatures() {
        for r in registrations where features[r.manifest.id] == nil {
            let context = FeatureContext(manifest: r.manifest, runtime: self)
            let feature = r.make(context)
            features[r.manifest.id] = feature
            activationOrder.append(r.manifest.id)
            feature.activate()
        }
        #if DEBUG
        for d in commands.descriptors where !commands.isHandled(d.id) {
            log.warning("command \(d.id, privacy: .public) is declared but has no handler")
        }
        #endif
    }

    public func deactivateFeatures() {
        events.publish(AppWillTerminate())
        for id in activationOrder.reversed() { features[id]?.deactivate() }
        saveSessionNow()
    }

    public func feature<F: BrowserFeature>(_ type: F.Type) -> F? {
        features.values.lazy.compactMap { $0 as? F }.first
    }

    // MARK: Session

    /// Restores tabs/spaces; returns saved window records for the shell to reopen.
    @discardableResult
    public func loadSession() -> [SessionSnapshot.WindowRecord] {
        guard let snapshot = persistence?.load() else {
            if tabs.spaces.isEmpty { tabs.addSpace(name: "Personal", icon: "person.fill") }
            return []
        }
        tabs.restore(snapshot.tabs)
        return snapshot.windows
    }

    public func sessionSnapshot() -> SessionSnapshot {
        SessionSnapshot(
            tabs: tabs.snapshot(),
            windows: windows.filter { !$0.isPrivate }.map {
                .init(id: $0.id, spaceID: $0.spaceID, selectedTabID: $0.selectedTabID, frame: $0.frameDescriptor,
                      isSidebarVisible: $0.isSidebarVisible, sidebarWidth: Double($0.sidebarWidth))
            }
        )
    }

    public func saveSessionNow() { persistence?.saveNow(sessionSnapshot()) }

    // MARK: Windows

    @discardableResult
    public func makeWindowState(spaceID: UUID? = nil, isPrivate: Bool = false, id: UUID = UUID()) -> BrowserWindowState {
        if tabs.spaces.isEmpty { tabs.addSpace(name: "Personal", icon: "person.fill") }
        let space = spaceID.flatMap { tabs.space($0) }?.id ?? tabs.spaces[0].id
        let w = BrowserWindowState(id: id, spaceID: space, isPrivate: isPrivate)
        windows.append(w)
        events.publish(WindowOpened(windowID: w.id))
        return w
    }

    public func removeWindow(_ window: BrowserWindowState) {
        window.viewport?.present(nil)
        windows.removeAll { $0.id == window.id }
        events.publish(WindowClosed(windowID: window.id))
        // Private tabs die with their window.
        if window.isPrivate {
            for t in tabs.allTabs where t.isPrivate { tabs.close(t.id, includingDescendants: true) }
        }
    }

    public var keyWindow: BrowserWindowState? { shell?.keyWindowState ?? windows.first }

    public func window(_ id: UUID) -> BrowserWindowState? { windows.first { $0.id == id } }

    public func switchSpace(_ spaceID: UUID, in window: BrowserWindowState) {
        guard window.spaceID != spaceID, let target = tabs.space(spaceID) else { return }
        let from = tabs.spaces.firstIndex { $0.id == window.spaceID } ?? 0
        let to = tabs.spaces.firstIndex { $0.id == spaceID } ?? 0
        window.spaceID = target.id
        // Re-select the most recent tab of that space (or nothing → start page).
        let candidate = window.mru.first { tabs.spaceID(of: $0) == spaceID }
            ?? tabs.orderedTabs(in: spaceID).first?.id
        select(candidate, in: window)
        events.publish(SpaceSwitched(windowID: window.id, spaceID: spaceID, direction: to == from ? 0 : (to > from ? 1 : -1)))
    }

    // MARK: Tabs

    public func selectedTab(in window: BrowserWindowState) -> BrowserTab? { window.selectedTabID.flatMap { tabs.tab($0) } }

    /// Creates a tab (and its live page when `url` is given) and optionally selects it.
    @discardableResult
    public func openTab(_ url: URL?, in window: BrowserWindowState, placement: TabPlacement = .automatic, select shouldSelect: Bool = true) -> BrowserTab {
        let tab = BrowserTab(url: url, isPrivate: window.isPrivate)
        insert(tab, placement: placement, window: window)
        events.publish(TabOpened(tabID: tab.id, openerID: nil, disposition: nil))
        if shouldSelect { select(tab.id, in: window) } else if url != nil { _ = live(tab) }
        return tab
    }

    private func insert(_ tab: BrowserTab, placement: TabPlacement, window: BrowserWindowState) {
        switch placement {
        case .automatic: tabs.insert(tab, into: .section(window.spaceID, .today), at: 0)
        case .childOf(let parent): tabs.insertChild(tab, of: parent)
        case .after(let sibling): tabs.insert(tab, after: sibling)
        case .container(let c, let i): tabs.insert(tab, into: c, at: i)
        }
    }

    /// Shows a tab in a window, waking it if discarded.
    public func select(_ id: NodeID?, in window: BrowserWindowState) {
        let previous = window.selectedTabID
        guard let id, let tab = tabs.tab(id) else {
            window.selectedTabID = nil
            window.viewport?.present(nil)
            events.publish(TabSelected(windowID: window.id, tabID: nil, previousTabID: previous))
            return
        }
        // A page can only be shown in one window at a time.
        for other in windows where other !== window && other.selectedTabID == id {
            select(other.mru.first { $0 != id && tabs.tab($0) != nil }, in: other)
        }
        if let s = tabs.spaceID(of: id), s != window.spaceID { window.spaceID = s }
        window.selectedTabID = id
        window.noteSelected(id)
        tab.lastActiveAt = Date()
        let engineTab = tab.url == nil && tab.engineTab == nil ? nil : live(tab)
        window.viewport?.present(engineTab)
        events.publish(TabSelected(windowID: window.id, tabID: id, previousTabID: previous))
    }

    /// Selects the tab `offset` rows away in the window's space order (⌘⌥↓ / ⌘⌥↑).
    public func selectAdjacent(_ offset: Int, in window: BrowserWindowState) {
        let ordered = tabs.orderedTabs(in: window.spaceID, includeFavorites: true)
        guard !ordered.isEmpty else { return }
        let i = window.selectedTabID.flatMap { id in ordered.firstIndex { $0.id == id } } ?? -1
        let next = ((i + offset) % ordered.count + ordered.count) % ordered.count
        select(ordered[next].id, in: window)
    }

    /// Closes a tab (children promoted unless `includingDescendants`) and picks the next selection.
    public func close(_ id: NodeID, includingDescendants: Bool = false) {
        guard tabs.contains(id) else { return }
        let removing = Set([id] + (includingDescendants || tabs.isCollapsed(id) ? tabs.descendants(of: id) : []))
        // Decide the next selection before the tree changes.
        var nextSelection: [UUID: NodeID?] = [:]
        for w in windows where w.selectedTabID.map(removing.contains) == true {
            nextSelection[w.id] = nextTab(afterClosing: id, removing: removing, in: w)
        }
        tabs.close(id, includingDescendants: includingDescendants)
        for w in windows {
            w.forget(removing)
            if let next = nextSelection[w.id] { select(next, in: w) }
        }
    }

    private func nextTab(afterClosing id: NodeID, removing: Set<NodeID>, in window: BrowserWindowState) -> NodeID? {
        // Prefer where the user came from (usually the parent that opened it), within the same space.
        if let recent = window.mru.first(where: { !removing.contains($0) && tabs.tab($0) != nil
            && (tabs.spaceID(of: $0) == window.spaceID || tabs.isFavorite($0)) }) {
            return recent
        }
        let ordered = tabs.orderedTabs(in: window.spaceID).map(\.id)
        guard let i = ordered.firstIndex(of: id) else { return ordered.first { !removing.contains($0) } }
        return ordered[(i + 1)...].first { !removing.contains($0) } ?? ordered[..<i].last { !removing.contains($0) }
    }

    public func reopenLastClosed(in window: BrowserWindowState) {
        guard let tab = tabs.reopenLastClosed() else { return }
        select(tab.id, in: window)
    }

    public func navigate(_ tab: BrowserTab, to url: URL) {
        tab.url = url
        if let live = tab.engineTab { live.load(url) } else { _ = live(tab) }
        for w in windows where w.selectedTabID == tab.id { w.viewport?.present(tab.engineTab) }
    }

    /// The live engine page for a tab, created on demand.
    @discardableResult
    public func live(_ tab: BrowserTab) -> EngineTab {
        if let e = tab.engineTab { return e }
        let e = engine.makeTab(EngineTabRequest(url: tab.restorationData == nil ? tab.url : nil, restorationData: tab.restorationData, isPrivate: tab.isPrivate))
        attach(e, to: tab)
        if tab.restorationData != nil, e.restorationData() == nil, let url = tab.url { e.load(url) }
        return e
    }

    private func attach(_ e: EngineTab, to tab: BrowserTab) {
        let binding = LiveTabBinding(tabID: tab.id, runtime: self)
        bindings[tab.id] = binding
        // The model must know the page before its first delegate callback (engines may commit synchronously).
        tab.engineTab = e
        events.publish(TabLiveChanged(tabID: tab.id, isLive: true))
        e.delegate = binding
    }

    /// Frees the engine page; the tab keeps its URL/title/history and wakes on selection.
    public func discard(_ tab: BrowserTab) {
        guard let e = tab.engineTab, !windows.contains(where: { $0.selectedTabID == tab.id }) else { return }
        tab.restorationData = e.restorationData()
        if let u = e.state.url { tab.url = u }
        if !e.state.title.isEmpty { tab.title = e.state.title }
        tab.engineTab = nil
        bindings[tab.id] = nil
        e.close()
        events.publish(TabLiveChanged(tabID: tab.id, isLive: false))
    }

    private func tabsRemoved(_ removed: [BrowserTab]) {
        for t in removed {
            if let e = t.engineTab {
                for w in windows where w.viewport?.presentedTab === e { w.viewport?.present(nil) }
                e.close()
            }
            t.engineTab = nil
            bindings[t.id] = nil
        }
        if !removed.isEmpty { events.publish(TabsClosed(tabIDs: removed.map(\.id))) }
    }

    // MARK: Engine callbacks

    fileprivate func tab(_ id: NodeID, didOpen newTab: EngineTab, url: URL?, disposition: OpenDisposition, gesture: Bool) {
        guard let source = tabs.tab(id) else { newTab.close(); return }
        let window = windows.first { $0.selectedTabID == id } ?? keyWindow ?? makeWindowState()
        if disposition == .newWindow, let shell {
            let w = shell.openWindow(spaceID: window.spaceID, isPrivate: window.isPrivate, initialURL: nil)
            let t = BrowserTab(url: url, isPrivate: w.isPrivate)
            tabs.insert(t, into: .section(w.spaceID, .today), at: 0)
            attach(newTab, to: t)
            events.publish(TabOpened(tabID: t.id, openerID: id, disposition: disposition))
            select(t.id, in: w)
            return
        }
        let child = BrowserTab(url: url, isPrivate: source.isPrivate)
        if source.opensLinksInPlace {
            tabs.insert(child, after: id)
        } else {
            tabs.insertChild(child, of: id)
        }
        attach(newTab, to: child)
        events.publish(TabOpened(tabID: child.id, openerID: id, disposition: disposition))
        if disposition != .backgroundTab { select(child.id, in: window) }
    }

    fileprivate func tab(_ id: NodeID, didCommit url: URL) {
        guard let t = tabs.tab(id) else { return }
        t.url = url
        events.publish(TabNavigated(tabID: id, url: url, isPrivate: t.isPrivate))
        persistence?.scheduleSave { [weak self] in self?.sessionSnapshot() }
    }

    fileprivate func tabDidFinishLoad(_ id: NodeID) {
        if let t = tabs.tab(id), let live = t.engineTab?.state {
            if !live.title.isEmpty { t.title = live.title }
            if let f = live.faviconURL { t.faviconURL = f }
        }
        events.publish(TabFinishedLoading(tabID: id))
    }

    fileprivate func tabDidRequestClose(_ id: NodeID) { close(id) }
}

/// Routes engine delegate calls to the runtime with the tab's id.
private final class LiveTabBinding: EngineTabDelegate {
    let tabID: NodeID
    weak var runtime: BrowserRuntime?

    init(tabID: NodeID, runtime: BrowserRuntime) {
        self.tabID = tabID
        self.runtime = runtime
    }

    func engineTab(_ tab: EngineTab, didOpen newTab: EngineTab, url: URL?, disposition: OpenDisposition, userGesture: Bool) {
        runtime?.tab(tabID, didOpen: newTab, url: url, disposition: disposition, gesture: userGesture)
    }
    func engineTab(_ tab: EngineTab, didCommit url: URL) { runtime?.tab(tabID, didCommit: url) }
    func engineTabDidFinishLoad(_ tab: EngineTab) { runtime?.tabDidFinishLoad(tabID) }
    func engineTabDidRequestClose(_ tab: EngineTab) { runtime?.tabDidRequestClose(tabID) }
}
