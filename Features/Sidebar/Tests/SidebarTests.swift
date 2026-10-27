import BrowserCore
import BrowserTesting
import Foundation
import Testing
@testable import FeatureSidebar

@MainActor
struct SidebarLogicTests {
    let store = TabStore()
    let space: Space
    init() { space = store.normalSpace }
    var today: Container { .section(space.id, .today) }
    func tab(_ s: String) -> BrowserTab { BrowserTab(url: URL(string: "https://\(s).example")!, title: s) }
    func titles() -> [String] { store.rows(in: today).map { store.tab($0.id)!.title } }

    @Test func hitboxUsesTargetLayout() {
        let a = store.insert(tab("a"), into: today, at: 0)
        let b = store.insert(tab("b"), into: today, at: 1)
        let rows = store.rows(in: today)
        #expect(SidebarLogic.row(at: 5, rows: rows, rowHeight: 32, spacing: 2)?.id == a.id)
        #expect(SidebarLogic.row(at: 40, rows: rows, rowHeight: 32, spacing: 2)?.id == b.id)
        #expect(SidebarLogic.row(at: 33, rows: rows, rowHeight: 32, spacing: 2) == nil)  // in the gap
        #expect(SidebarLogic.row(at: 200, rows: rows, rowHeight: 32, spacing: 2) == nil)
    }

    /// Pointer over a row's icon column at `depth`, `dy` into row `r` (rows 32 high, 2 apart).
    func at(_ r: Int, _ dy: CGFloat, depth: Int = 9) -> CGPoint {
        CGPoint(x: Design.Grid.iconInset + CGFloat(depth) * SidebarLogic.indent + 1, y: CGFloat(r) * 34 + dy)
    }
    func place(_ dragged: BrowserTab, _ p: CGPoint) -> SidebarLogic.DropPlacement? {
        SidebarLogic.placement(at: p, rows: store.rows(in: today), in: today, dragged: [dragged.id], rowHeight: 32, spacing: 2, store: store)
    }

    @Test func dropsBetweenAndIntoRows() throws {
        let a = store.insert(tab("a"), into: today, at: 0)
        let b = store.insert(tab("b"), into: today, at: 1)
        let c = store.insert(tab("c"), into: today, at: 2)
        #expect(place(c, at(1, 16))?.mark == .into(b.id))
        // Next to where it already is: nothing to show.
        #expect(place(c, at(2, 2)) == nil)
        #expect(place(c, at(1, 30)) == nil)
        let top = try #require(place(c, at(0, 2)))
        #expect(top.mark == .line(gap: 0, depth: 0))
        #expect(SidebarLogic.drop([c.id], at: top, store: store))
        #expect(titles() == ["c", "a", "b"])
        #expect(SidebarLogic.drop([a.id], at: try #require(place(a, at(2, 30))), store: store))
        #expect(titles() == ["c", "b", "a"])
        #expect(SidebarLogic.drop([a.id], at: try #require(place(a, at(0, 16))), store: store))
        #expect(store.parent(of: a.id) == c.id)
        // Never into its own branch.
        #expect(place(c, at(1, 16)) == nil)
    }

    /// Under an open parent the line is its first child's; under a branch's end, moving left lands after an ancestor.
    @Test func theLineFollowsTheTree() throws {
        let a = store.insert(tab("a"), into: today, at: 0)
        let a1 = store.insertChild(tab("a1"), of: a.id)
        store.insertChild(tab("a2"), of: a1.id)
        let z = store.insert(tab("z"), into: today, at: 1)  // rows: a, a1, a2, z
        let firstChild = try #require(place(z, at(0, 30, depth: 0)))
        #expect(firstChild.mark == .line(gap: 1, depth: 1))
        #expect(firstChild.container == .node(a.id) && firstChild.index == 0)

        #expect(place(z, at(2, 30))?.mark == .line(gap: 3, depth: 2))
        let afterA1 = try #require(place(z, at(2, 30, depth: 1)))
        #expect(afterA1.mark == .line(gap: 3, depth: 1))
        #expect(SidebarLogic.drop([z.id], at: afterA1, store: store))
        #expect(store.parent(of: z.id) == a.id && store.children(of: a.id) == [a1.id, z.id])
    }

    @Test func newTabRowPinsAboveAndStartsTodayBelow() throws {
        let a = store.insert(tab("a"), into: today, at: 0)
        let b = store.insert(tab("b"), into: today, at: 1)
        let pin = try #require(SidebarLogic.newTabPlacement(atY: 4, rowHeight: 32, space: space.id, dragged: [b.id], store: store))
        #expect(SidebarLogic.drop([b.id], at: pin, store: store))
        #expect(store.isPinned(b.id) && store.tab(b.id)?.pinnedURL != nil)
        #expect(SidebarLogic.newTabPlacement(atY: 28, rowHeight: 32, space: space.id, dragged: [a.id], store: store) == nil)  // already first
        let back = try #require(SidebarLogic.newTabPlacement(atY: 28, rowHeight: 32, space: space.id, dragged: [b.id], store: store))
        #expect(SidebarLogic.drop([b.id], at: back, store: store))
        #expect(titles() == ["b", "a"] && store.tab(b.id)?.pinnedURL == nil)
        store.pin(a.id, in: space.id)
        // With tabs pinned, they end at the divider: the whole row begins Today.
        #expect(SidebarLogic.newTabPlacement(atY: 4, rowHeight: 32, space: space.id, dragged: [b.id], store: store) == nil)
    }

    @Test func dropIntoFavoritesAndPinned() {
        let a = store.insert(tab("a"), into: today)
        #expect(SidebarLogic.drop([a.id], into: .favorites, store: store))
        #expect(store.isFavorite(a.id))
        #expect(SidebarLogic.drop([a.id], into: .section(space.id, .pinned), store: store))
        #expect(store.isPinned(a.id))
    }

    @Test func markdownExport() {
        let a = store.insert(tab("a"), into: today)
        store.insertChild(tab("b"), of: a.id)
        #expect(SidebarLogic.markdown(for: a.id, store: store) == "- [a](https://a.example)\n  - [b](https://b.example)")
    }

    /// ⇧-click picks from the tab shown to the clicked one, either way, folders left out; moves act on branch roots.
    @Test func shiftClickPicksARange() {
        let a = store.insert(tab("a"), into: today, at: 0)
        let a1 = store.insertChild(tab("a1"), of: a.id)
        let folder = store.insertFolder(Folder(name: "f"), into: today, at: 1)
        let b = store.insert(tab("b"), into: today, at: 2)
        let c = store.insert(tab("c"), into: today, at: 3)
        let rows = store.rows(in: today)  // a, a1, f, b, c
        #expect(SidebarLogic.range(from: a1.id, to: c.id, in: rows, store: store) == [a1.id, b.id, c.id])
        #expect(SidebarLogic.range(from: c.id, to: a.id, in: rows, store: store) == [a.id, a1.id, b.id, c.id])
        // The tab shown isn't listed (a favorite): only the clicked one.
        #expect(SidebarLogic.range(from: UUID(), to: b.id, in: rows, store: store) == [b.id])
        #expect(SidebarLogic.roots([a.id, a1.id, b.id], store: store) == [a.id, b.id])
        _ = folder
    }

    /// Picked tabs dragged together land together, in the order shown, whichever way they go; a picked child goes in its
    /// picked parent's branch.
    @Test func pickedTabsDropTogether() throws {
        let a = store.insert(tab("a"), into: today, at: 0)
        let b = store.insert(tab("b"), into: today, at: 1)
        let c = store.insert(tab("c"), into: today, at: 2)
        let d = store.insert(tab("d"), into: today, at: 3)
        func place(_ dragged: [BrowserTab], _ p: CGPoint) -> SidebarLogic.DropPlacement? {
            SidebarLogic.placement(at: p, rows: store.rows(in: today), in: today, dragged: dragged.map(\.id), rowHeight: 32, spacing: 2,
                                   store: store)
        }
        #expect(SidebarLogic.drop([a.id, c.id], at: try #require(place([a, c], at(3, 30, depth: 0))), store: store))
        #expect(titles() == ["b", "d", "a", "c"])
        #expect(SidebarLogic.drop([d.id, c.id], at: try #require(place([d, c], at(0, 2))), store: store))
        #expect(titles() == ["d", "c", "b", "a"])
        // Already together beside the gap: nothing to show. Never into one of them.
        #expect(place([d, c], at(2, 2)) == nil)
        #expect(place([b, d], at(0, 16))?.mark != .into(d.id))
        #expect(SidebarLogic.newTabPlacement(atY: 28, rowHeight: 32, space: space.id, dragged: [d.id, c.id], store: store) == nil)
        #expect(SidebarLogic.endPlacement(rows: store.rows(in: today), in: today, dragged: [b.id, a.id], store: store) == nil)

        let b1 = store.insertChild(tab("b1"), of: b.id)  // rows: d, c, b, b1, a
        #expect(SidebarLogic.drop([b.id, b1.id, a.id], at: try #require(place([b, b1, a], at(0, 16))), store: store))
        #expect(store.children(of: d.id) == [b.id, a.id] && store.children(of: b.id) == [b1.id])
    }

    @Test func focusModeKeepsOnlyTheBranch() {
        let a = store.insert(tab("a"), into: today, at: 0)
        let b = store.insertChild(tab("b"), of: a.id)
        store.insert(tab("z"), into: today, at: 1)
        let rows = SidebarLogic.focusRows(store.rows(in: today), selected: b.id, store: store)
        #expect(rows.map { store.tab($0.id)!.title } == ["a", "b"])
    }
}

@MainActor
struct SidebarFeatureTests {
    @Test func contributesSidebarAndTogglesIt() throws {
        let h = try TestHarness(features: [SidebarFeature.self], manifestDirectory: #filePath)
        #expect(!h.runtime.ui.views(for: .sidebar).isEmpty)
        #expect(h.window.isSidebarVisible)
        try h.run("sidebar.toggle")
        #expect(!h.window.isSidebarVisible)
        try h.run("sidebar.toggle")
        #expect(h.window.isSidebarVisible && !h.window.isSidebarLeaving)
        try h.run("sidebar.focus-mode")
        #expect(h.window.flags.contains(SidebarModel.focusFlag))
    }

    /// A window without a sidebar (a Quick Look window) never shows it.
    @Test func windowsWithoutASidebarKeepItHidden() throws {
        let h = try TestHarness(features: [SidebarFeature.self], manifestDirectory: #filePath)
        h.window.isSidebarVisible = false
        h.window.allowsSidebar = false
        #expect(!h.runtime.commands.canRun("sidebar.toggle", in: h.window))
        #expect(throws: CommandError.self) { try h.run("sidebar.toggle") }
        #expect(!h.window.isSidebarVisible)
    }

    /// One ⌘Z puts back every tab a drag moved, in its old place.
    @Test func aGroupDragUndoesAsOne() throws {
        let h = try TestHarness(features: [SidebarFeature.self], manifestDirectory: #filePath)
        for s in ["a", "b", "c", "d"] { h.openTab("https://\(s).example") }
        let tabs = h.runtime.tabs, history = h.runtime.sidebarHistory
        let today = Container.section(h.window.spaceID, .today)
        let start = tabs.nodes(in: today)
        let placement = SidebarLogic.DropPlacement(mark: .line(gap: 4, depth: 0), container: today, index: nil)
        history.group { SidebarLogic.drop([start[0], start[2]], at: placement, store: tabs, record: history.move) }
        #expect(tabs.nodes(in: today) == [start[1], start[3], start[0], start[2]])
        history.undo(in: h.window)
        #expect(tabs.nodes(in: today) == start)
        history.redo(in: h.window)
        #expect(tabs.nodes(in: today) == [start[1], start[3], start[0], start[2]])
    }

    @Test func everyCommandIsHandled() throws {
        let h = try TestHarness(features: [SidebarFeature.self], manifestDirectory: #filePath)
        for d in h.runtime.manifests[0].commands { #expect(h.runtime.commands.isHandled(d.id)) }
    }
}
