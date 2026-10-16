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

    @Test func dropZones() {
        #expect(SidebarLogic.zone(atY: 2, rowHeight: 32, canNest: true) == .before)
        #expect(SidebarLogic.zone(atY: 16, rowHeight: 32, canNest: true) == .inside)
        #expect(SidebarLogic.zone(atY: 30, rowHeight: 32, canNest: true) == .after)
        #expect(SidebarLogic.zone(atY: 16, rowHeight: 32, canNest: false) == .after)
    }

    @Test func dropReordersAndNests() {
        let a = store.insert(tab("a"), into: today, at: 0)
        let b = store.insert(tab("b"), into: today, at: 1)
        let c = store.insert(tab("c"), into: today, at: 2)
        #expect(SidebarLogic.drop(c.id, on: a.id, zone: .before, store: store))
        #expect(titles() == ["c", "a", "b"])
        #expect(SidebarLogic.drop(c.id, on: b.id, zone: .after, store: store))
        #expect(titles() == ["a", "b", "c"])
        #expect(SidebarLogic.drop(a.id, on: b.id, zone: .after, store: store))
        #expect(titles() == ["b", "a", "c"])
        #expect(SidebarLogic.drop(c.id, on: a.id, zone: .inside, store: store))
        #expect(store.parent(of: c.id) == a.id)
        // Cannot drop a node into its own descendant.
        #expect(!SidebarLogic.drop(a.id, on: c.id, zone: .inside, store: store))
    }

    @Test func dropIntoFavoritesAndPinned() {
        let a = store.insert(tab("a"), into: today)
        #expect(SidebarLogic.drop(a.id, into: .favorites, store: store))
        #expect(store.isFavorite(a.id))
        #expect(SidebarLogic.drop(a.id, into: .section(space.id, .pinned), store: store))
        #expect(store.isPinned(a.id))
    }

    @Test func markdownExport() {
        let a = store.insert(tab("a"), into: today)
        store.insertChild(tab("b"), of: a.id)
        #expect(SidebarLogic.markdown(for: a.id, store: store) == "- [a](https://a.example)\n  - [b](https://b.example)")
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
        try h.run("sidebar.focus-mode")
        #expect(h.window.flags.contains(SidebarModel.focusFlag))
    }

    @Test func everyCommandIsHandled() throws {
        let h = try TestHarness(features: [SidebarFeature.self], manifestDirectory: #filePath)
        for d in h.runtime.manifests[0].commands { #expect(h.runtime.commands.isHandled(d.id)) }
    }
}
