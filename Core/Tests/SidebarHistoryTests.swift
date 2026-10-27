import BrowserTesting
import Foundation
import Testing
@testable import BrowserCore

@MainActor
struct SidebarHistoryTests {
    func harness() throws -> TestHarness { try TestHarness(registrations: []) }

    @Test func movesUndoAndRedo() throws {
        let h = try harness()
        let a = h.openTab("https://a.example"), b = h.openTab("https://b.example")
        let history = h.runtime.sidebarHistory
        let before = h.runtime.tabs.container(of: b.id)
        history.move(b.id) { h.runtime.tabs.pin(b.id, in: h.window.spaceID) }
        #expect(h.runtime.tabs.isPinned(b.id) && b.pinnedURL != nil)
        history.undo(in: h.window)
        #expect(h.runtime.tabs.container(of: b.id) == before && b.pinnedURL == nil)
        history.redo(in: h.window)
        #expect(h.runtime.tabs.isPinned(b.id))
        #expect(h.runtime.tabs.container(of: a.id) == before)
    }

    @Test func closedTabsComeBackWithTheirIdentity() throws {
        let h = try harness()
        _ = h.openTab("https://a.example")
        let b = h.openTab("https://b.example")
        let history = h.runtime.sidebarHistory
        history.close([b.id], includingDescendants: false)
        #expect(!h.runtime.tabs.contains(b.id))
        history.undo(in: h.window)
        #expect(h.runtime.tabs.tab(b.id)?.url?.host() == "b.example")
        #expect(h.selectedTab?.id == b.id)
        history.redo(in: h.window)
        #expect(!h.runtime.tabs.contains(b.id))
    }

    /// Several tabs pinned then closed in one group: one ⌘Z brings back and unpins them all.
    @Test func aGroupUndoesAsOneStep() throws {
        let h = try harness()
        let a = h.openTab("https://a.example"), b = h.openTab("https://b.example"), c = h.openTab("https://c.example")
        let tabs = h.runtime.tabs, history = h.runtime.sidebarHistory
        let today = tabs.container(of: a.id)
        history.group {
            for id in [a.id, b.id] { history.move(id) { tabs.pin(id, in: h.window.spaceID) } }
        }
        history.group { history.close([c.id], includingDescendants: false) }
        history.undo(in: h.window)
        #expect(tabs.contains(c.id))
        #expect(tabs.isPinned(a.id) && tabs.isPinned(b.id))
        history.undo(in: h.window)
        #expect(tabs.container(of: a.id) == today && tabs.container(of: b.id) == today)
        #expect(!history.canUndo)
        history.redo(in: h.window)
        #expect(tabs.isPinned(a.id) && tabs.isPinned(b.id))
    }

    /// A reorder within one list, either way: Undo puts the tab back where it was, Redo where it went.
    @Test func reordersUndoToTheirPlace() throws {
        let h = try harness()
        let a = h.openTab("https://a.example")
        _ = (h.openTab("https://b.example"), h.openTab("https://c.example"))
        let tabs = h.runtime.tabs, history = h.runtime.sidebarHistory
        let today = try #require(tabs.container(of: a.id))
        let start = tabs.nodes(in: today)
        for (id, index) in [(start[0], 3), (start[2], 0)] {
            history.move(id) { try? tabs.move(id, to: today, at: index) }
            let moved = tabs.nodes(in: today)
            history.undo(in: h.window)
            #expect(tabs.nodes(in: today) == start)
            history.redo(in: h.window)
            #expect(tabs.nodes(in: today) == moved)
            history.undo(in: h.window)
        }
    }

    /// Reopened another way in between (⇧⌘T): the closed list moved on, so Undo stops rather than reopen something else.
    @Test func staleStepsAreDropped() throws {
        let h = try harness()
        let a = h.openTab("https://a.example"), b = h.openTab("https://b.example")
        let history = h.runtime.sidebarHistory
        history.close([a.id], includingDescendants: false)
        h.runtime.close(b.id)
        history.undo(in: h.window)
        #expect(!h.runtime.tabs.contains(a.id))
        #expect(!history.canUndo)
    }
}
