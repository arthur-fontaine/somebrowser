import Darwin
import Foundation
import Testing
@testable import BrowserCore

@MainActor
struct TabStoreTests {
    let store = TabStore()
    let space: Space

    init() { space = store.addSpace(name: "Work") }

    func tab(_ s: String) -> BrowserTab { BrowserTab(url: URL(string: "https://\(s).example")!, title: s) }
    func titles(_ c: Container) -> [String] { store.rows(in: c).map { store.tab($0.id)?.title ?? store.folder($0.id)!.name } }
    var today: Container { .section(space.id, .today) }

    @Test func newTodayTabsGoOnTop() {
        store.insert(tab("a"), into: today)
        store.insert(tab("b"), into: today)
        #expect(titles(today) == ["b", "a"])
    }

    @Test func linksBecomeChildrenWithDepth() {
        let a = store.insert(tab("a"), into: today)
        let b = store.insertChild(tab("b"), of: a.id)
        store.insertChild(tab("c"), of: b.id)
        store.insertChild(tab("d"), of: a.id)
        let rows = store.rows(in: today)
        #expect(rows.map { store.tab($0.id)!.title } == ["a", "b", "c", "d"])
        #expect(rows.map(\.depth) == [0, 1, 2, 1])
        #expect(store.parent(of: b.id) == a.id)
        #expect(store.rootContainer(of: b.id) == today)
    }

    @Test func closingPromotesChildrenInOrder() {
        let a = store.insert(tab("a"), into: today)
        let b = store.insertChild(tab("b"), of: a.id)
        store.insertChild(tab("c"), of: b.id)
        store.insertChild(tab("d"), of: b.id)
        store.close(b.id)
        #expect(titles(today) == ["a", "c", "d"])
        #expect(store.rows(in: today).map(\.depth) == [0, 1, 1])
    }

    @Test func closingWithDescendantsRemovesSubtree() {
        let a = store.insert(tab("a"), into: today)
        let b = store.insertChild(tab("b"), of: a.id)
        store.insertChild(tab("c"), of: b.id)
        let closed = store.close(a.id, includingDescendants: true)
        #expect(closed.count == 3)
        #expect(store.tabCount == 0)
    }

    @Test func closingCollapsedParentFollowsVisibleHierarchy() {
        let a = store.insert(tab("a"), into: today)
        store.insertChild(tab("b"), of: a.id)
        store.setCollapsed(a.id, true)
        #expect(titles(today) == ["a"])
        store.close(a.id)
        #expect(store.tabCount == 0)
    }

    @Test func reopenRestoresWholeSubtreeAtPosition() {
        store.insert(tab("z"), into: today)
        let a = store.insert(tab("a"), into: today)
        let b = store.insertChild(tab("b"), of: a.id)
        store.insertChild(tab("c"), of: b.id)
        store.close(a.id, includingDescendants: true)
        let restored = store.reopenLastClosed()
        #expect(restored?.id == a.id)
        #expect(titles(today) == ["a", "b", "c", "z"])
        #expect(store.rows(in: today).map(\.depth) == [0, 1, 2, 0])
    }

    @Test func moveRejectsCycles() {
        let a = store.insert(tab("a"), into: today)
        let b = store.insertChild(tab("b"), of: a.id)
        #expect(throws: TabStore.MoveError.cycle) { try store.move(a.id, to: .node(b.id)) }
    }

    @Test func indentOutdentAndShift() {
        let a = store.insert(tab("a"), into: today, at: 0)
        let b = store.insert(tab("b"), into: today, at: 1)
        let c = store.insert(tab("c"), into: today, at: 2)
        store.indent(b.id)
        #expect(store.parent(of: b.id) == a.id)
        store.outdent(b.id)
        #expect(titles(today) == ["a", "b", "c"])
        store.shift(c.id, by: -1)
        #expect(titles(today) == ["a", "c", "b"])
        store.shift(a.id, by: 1)
        #expect(titles(today) == ["c", "a", "b"])
    }

    @Test func favoritesAreFlat() {
        let a = store.insert(tab("a"), into: today)
        store.insertChild(tab("b"), of: a.id)
        store.favorite(a.id)
        #expect(store.favorites == [a.id])
        #expect(titles(today) == ["b"])
        #expect(a.pinnedURL == a.url)
    }

    @Test func pinAndUnpin() {
        let a = store.insert(tab("a"), into: today)
        store.pin(a.id, in: space.id)
        #expect(store.isPinned(a.id))
        a.url = URL(string: "https://elsewhere.example")
        #expect(a.hasNavigatedAwayFromPin)
        store.unpin(a.id, in: space.id)
        #expect(!store.isPinned(a.id))
        #expect(a.pinnedURL == nil)
    }

    @Test func dedupMatchesNormalizedURLs() {
        let t = BrowserTab(url: URL(string: "https://www.Example.com/path/#frag")!)
        store.insert(t, into: today)
        #expect(store.tabs(matching: URL(string: "http://example.com/path")!).map(\.id) == [t.id])
    }

    @Test func snapshotRoundTrip() throws {
        let a = store.insert(tab("a"), into: today)
        store.insertChild(tab("b"), of: a.id)
        store.insertFolder(Folder(name: "F"), into: .section(space.id, .pinned))
        let data = try JSONEncoder().encode(store.snapshot())
        let copy = TabStore()
        copy.restore(try JSONDecoder().decode(TabStore.Snapshot.self, from: data))
        #expect(copy.rows(in: today).map(\.depth) == [0, 1])
        #expect(copy.rows(in: .section(space.id, .pinned)).first?.isFolder == true)
    }

    @Test func rowsAreCachedUntilStructureChanges() {
        store.insert(tab("a"), into: today)
        let v = store.structureVersion
        _ = store.rows(in: today)
        #expect(store.structureVersion == v)
        store.insert(tab("b"), into: today)
        #expect(store.rows(in: today).count == 2)
    }
}

extension TabStoreTests {
    @Test func reopenReNestsPromotedChildren() {
        let a = store.insert(tab("a"), into: today)
        let b = store.insertChild(tab("b"), of: a.id)
        store.close(a.id)
        #expect(store.parent(of: b.id) == nil)
        store.reopenLastClosed()
        #expect(store.parent(of: b.id) == a.id)
        #expect(titles(today) == ["a", "b"])
    }

    /// Performance budget: 500 tabs (as trees, with titles and URLs) cost under 20 MB, and the sidebar rows are rebuilt
    /// in well under a frame.
    @Test func fiveHundredTabsStayCheap() {
        func footprint() -> Int {
            var info = task_vm_info_data_t()
            var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
            _ = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
            }
            return Int(info.phys_footprint)
        }
        let before = footprint()
        var parent: BrowserTab?
        for i in 0..<500 {
            let t = BrowserTab(url: URL(string: "https://site\(i).example/a/rather/long/path?query=\(i)")!, title: "A page title number \(i) of the session")
            if i % 5 != 0, let p = parent { store.insertChild(t, of: p.id) } else { parent = store.insert(t, into: today) }
        }
        let grown = footprint() - before
        let start = DispatchTime.now()
        let rows = store.rows(in: today)
        let ms = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1e6
        print("500 tabs: \(grown >> 10) KB, rows in \(ms) ms")
        #expect(rows.count == 500)
        #expect(grown < 20 << 20)
        #expect(ms < 8)
    }
}
