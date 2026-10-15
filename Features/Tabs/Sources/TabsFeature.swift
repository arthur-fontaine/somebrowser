import AppKit
import BrowserCore

/// Tab commands: creation, closing (Horse tree semantics), switching, tree navigation and moves,
/// pinning, duplication. Pure command glue over `BrowserRuntime` / `TabStore`; the sidebar UI lives in
/// the sidebar feature.
public final class TabsFeature: BrowserFeature {
    private let context: FeatureContext
    private var runtime: BrowserRuntime { context.runtime }
    private var store: TabStore { context.tabs }

    public init(context: FeatureContext) {
        self.context = context
    }

    public func activate() {
        let c = context.commands
        let hasTab: (CommandInvocation) -> Bool = { [weak self] inv in
            guard let self, let w = inv.window else { return false }
            return self.runtime.selectedTab(in: w) != nil
        }

        c.handle("tabs.new-window") { [weak self] _ in self?.context.shell?.openWindow(spaceID: nil, isPrivate: false, initialURL: nil) }
        c.handle("tabs.new-private-window") { [weak self] _ in self?.context.shell?.openWindow(spaceID: nil, isPrivate: true, initialURL: nil) }
        c.handle("tabs.close-window") { [weak self] inv in if let w = inv.window { self?.context.shell?.closeWindow(w) } }

        c.handle("tabs.new-blank") { [weak self] inv in
            guard let self, let w = inv.window else { return }
            self.runtime.openTab(nil, in: w)
        }
        c.handle("tabs.new-child", isEnabled: hasTab) { [weak self] inv in
            guard let self, let w = inv.window, let current = w.selectedTabID else { return }
            self.runtime.openTab(nil, in: w, placement: .childOf(current))
        }
        c.handle("tabs.new-sibling", isEnabled: hasTab) { [weak self] inv in
            guard let self, let w = inv.window, let current = w.selectedTabID else { return }
            self.runtime.openTab(nil, in: w, placement: .after(current))
        }

        c.handle("tabs.close", isEnabled: hasTab) { [weak self] inv in
            guard let self, let w = inv.window, let id = w.selectedTabID else { return }
            self.runtime.sidebarHistory.close([id], includingDescendants: !self.context.settings.bool("tabs.closeKeepsChildren"))
        }
        c.handle("tabs.close-subtree", isEnabled: hasTab) { [weak self] inv in
            guard let self, let w = inv.window, let id = w.selectedTabID else { return }
            self.runtime.sidebarHistory.close([id], includingDescendants: true)
        }
        c.handle("tabs.reopen", isEnabled: { [weak self] _ in !(self?.store.recentlyClosed.isEmpty ?? true) }) { [weak self] inv in
            guard let self, let w = inv.window else { return }
            self.runtime.reopenLastClosed(in: w)
        }

        c.handle("tabs.next") { [weak self] inv in if let w = inv.window { self?.runtime.selectAdjacent(1, in: w) } }
        c.handle("tabs.previous") { [weak self] inv in if let w = inv.window { self?.runtime.selectAdjacent(-1, in: w) } }
        for i in 1...8 {
            c.handle("tabs.select-\(i)") { [weak self] inv in self?.selectIndex(i - 1, inv.window) }
        }
        c.handle("tabs.select-last") { [weak self] inv in self?.selectIndex(-1, inv.window) }

        c.handle("tabs.select-parent", isEnabled: hasTab) { [weak self] inv in self?.parentOrCollapse(inv.window) }
        c.handle("tabs.select-child", isEnabled: hasTab) { [weak self] inv in self?.childOrExpand(inv.window) }
        c.handle("tabs.select-above") { [weak self] inv in self?.selectRow(offset: -1, inv.window) }
        c.handle("tabs.select-below") { [weak self] inv in self?.selectRow(offset: 1, inv.window) }

        c.handle("tabs.move-up", isEnabled: hasTab) { [weak self] inv in self?.recordingMove(inv) { self?.store.shift($0, by: -1) } }
        c.handle("tabs.move-down", isEnabled: hasTab) { [weak self] inv in self?.recordingMove(inv) { self?.store.shift($0, by: 1) } }
        c.handle("tabs.indent", isEnabled: hasTab) { [weak self] inv in self?.recordingMove(inv) { self?.store.indent($0) } }
        c.handle("tabs.outdent", isEnabled: hasTab) { [weak self] inv in self?.recordingMove(inv) { self?.store.outdent($0) } }
        c.handle("tabs.collapse-others") { [weak self] inv in self?.store.collapseAll(except: inv.window?.selectedTabID) }
        c.handle("tabs.toggle-open-in-place", isEnabled: hasTab) { [weak self] inv in
            self?.withSelected(inv) { tab in
                tab.opensLinksInPlace.toggle()
                self?.context.notify(tab.opensLinksInPlace ? "Links open in this tab" : "Links open as child tabs",
                                     systemImage: "arrow.triangle.branch", window: inv.window)
            }
        }

        c.handle("tabs.pin", isEnabled: hasTab) { [weak self] inv in
            guard let self, let w = inv.window, let tab = self.runtime.selectedTab(in: w) else { return }
            self.runtime.sidebarHistory.move(tab.id) {
                if self.store.isPinned(tab.id) || self.store.isFavorite(tab.id) { self.store.unpin(tab.id, in: w.spaceID) }
                else { self.store.pin(tab.id, in: w.spaceID) }
            }
        }
        c.handle("tabs.favorite", isEnabled: hasTab) { [weak self] inv in self?.recordingMove(inv) { self?.store.favorite($0) } }
        c.handle("tabs.duplicate", isEnabled: hasTab) { [weak self] inv in
            guard let self, let w = inv.window, let tab = self.runtime.selectedTab(in: w), let url = tab.live?.url ?? tab.url else { return }
            self.runtime.openTab(url, in: w, placement: .after(tab.id))
        }
        c.handle("tabs.reset-pinned", isEnabled: { [weak self] inv in
            guard let self, let w = inv.window else { return false }
            return self.runtime.selectedTab(in: w)?.hasNavigatedAwayFromPin ?? false
        }) { [weak self] inv in
            self?.withSelected(inv) { tab in if let home = tab.pinnedURL { self?.runtime.navigate(tab, to: home) } }
        }
        c.handle("tabs.rename", isEnabled: hasTab) { [weak self] inv in
            self?.withSelected(inv) { tab in inv.window?.flags.insert("rename:\(tab.id.uuidString)") }
        }
        c.handle("tabs.mute", isEnabled: hasTab) { [weak self] inv in
            self?.withSelected(inv) { tab in tab.engineTab?.isMuted.toggle() }
        }
        c.handle("tabs.clear-today") { [weak self] inv in
            guard let self, let w = inv.window, let space = self.store.space(w.spaceID) else { return }
            let roots = space.today
            guard !roots.isEmpty else { return }
            self.runtime.sidebarHistory.close(roots, includingDescendants: true)
            self.context.notify("Cleared \(roots.count) tab\(roots.count == 1 ? "" : "s")", systemImage: "wind", window: w,
                                actionTitle: "Undo") { [weak self] in self?.runtime.sidebarHistory.undo(in: w) }
        }
        c.handle("tabs.new-folder") { [weak self] inv in
            guard let self, let w = inv.window else { return }
            let folder = self.store.insertFolder(Folder(name: "New Folder"), into: .section(w.spaceID, .pinned))
            w.flags.insert("rename:\(folder.id.uuidString)")
        }
    }

    // MARK: Helpers

    /// A sidebar change to the selected tab, undoable with ⌘Z.
    private func recordingMove(_ inv: CommandInvocation, _ body: (NodeID) -> Void) {
        guard let w = inv.window, let tab = runtime.selectedTab(in: w) else { return }
        runtime.sidebarHistory.move(tab.id) { body(tab.id) }
    }

    private func withSelected(_ inv: CommandInvocation, _ body: (BrowserTab) -> Void) {
        guard let w = inv.window, let tab = runtime.selectedTab(in: w) else { return }
        body(tab)
    }

    /// ⌘1…⌘8 count favorites, then pinned, then today (Arc); ⌘9 is the last tab.
    func selectIndex(_ index: Int, _ window: BrowserWindowState?) {
        guard let w = window else { return }
        let ordered = store.orderedTabs(in: w.spaceID, includeFavorites: true)
        guard !ordered.isEmpty else { return }
        let i = index < 0 ? ordered.count - 1 : index
        guard i < ordered.count else { return }
        runtime.select(ordered[i].id, in: w)
    }

    /// Visible rows in sidebar order: favorites, then pinned and today trees (collapse respected).
    func visibleTabRows(_ w: BrowserWindowState) -> [NodeID] {
        var ids = store.favorites
        for section in SidebarSection.allCases {
            ids += store.rows(in: .section(w.spaceID, section)).filter { !$0.isFolder }.map(\.id)
        }
        return ids
    }

    func selectRow(offset: Int, _ window: BrowserWindowState?) {
        guard let w = window else { return }
        let rows = visibleTabRows(w)
        guard !rows.isEmpty else { return }
        let i = w.selectedTabID.flatMap { rows.firstIndex(of: $0) } ?? (offset > 0 ? -1 : rows.count)
        let j = max(0, min(rows.count - 1, i + offset))
        runtime.select(rows[j], in: w)
    }

    /// Horse ⌘⇧←: collapse if expanded, else select the parent.
    func parentOrCollapse(_ window: BrowserWindowState?) {
        guard let w = window, let id = w.selectedTabID else { return }
        if !store.children(of: id).isEmpty && !store.isCollapsed(id) {
            store.setCollapsed(id, true)
        } else if let p = store.parent(of: id), store.tab(p) != nil {
            runtime.select(p, in: w)
        }
    }

    /// Horse ⌘⇧→: expand if collapsed, else select the first child.
    func childOrExpand(_ window: BrowserWindowState?) {
        guard let w = window, let id = w.selectedTabID else { return }
        let kids = store.children(of: id)
        guard let first = kids.first else { return }
        if store.isCollapsed(id) { store.setCollapsed(id, false) } else { runtime.select(first, in: w) }
    }
}
