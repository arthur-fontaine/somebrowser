import BrowserCore
import BrowserTesting
import Foundation
import Testing
@testable import FeatureTabs

@MainActor
struct TabsFeatureTests {
    func harness() throws -> TestHarness { try TestHarness(features: [TabsFeature.self], manifestDirectory: #filePath) }

    @Test func everyDeclaredCommandHasAHandler() throws {
        let h = try harness()
        for d in h.runtime.manifests[0].commands {
            #expect(h.runtime.commands.isHandled(d.id), "\(d.id) has no handler")
        }
    }

    @Test func closeKeepsChildrenByDefaultAndSubtreeClosesAll() throws {
        let h = try harness()
        let parent = h.openTab("https://a.example")
        let child = h.fakeTab(parent).simulateOpen(URL(string: "https://b.example")!)
        _ = child
        h.runtime.select(parent.id, in: h.window)
        try h.run("tabs.close")
        #expect(h.runtime.tabs.tabCount == 1)
        try h.run("tabs.reopen")
        #expect(h.runtime.tabs.tabCount == 2)
        h.runtime.select(parent.id, in: h.window)
        try h.run("tabs.close-subtree")
        #expect(h.runtime.tabs.tabCount == 0)
    }

    @Test func numberShortcutsFollowSidebarOrder() throws {
        let h = try harness()
        let a = h.openTab("https://a.example")
        let b = h.openTab("https://b.example")
        // Today lists newest first: b, a.
        try h.run("tabs.select-1")
        #expect(h.selectedTab?.id == b.id)
        try h.run("tabs.select-last")
        #expect(h.selectedTab?.id == a.id)
        try h.run("tabs.next")
        #expect(h.selectedTab?.id == b.id)
    }

    @Test func treeNavigationCollapsesThenSelectsParent() throws {
        let h = try harness()
        let parent = h.openTab("https://a.example")
        h.fakeTab(parent).simulateOpen(URL(string: "https://b.example")!)
        h.runtime.select(parent.id, in: h.window)
        try h.run("tabs.select-parent")  // expanded parent → collapse
        #expect(h.runtime.tabs.isCollapsed(parent.id))
        try h.run("tabs.select-child")  // collapsed → expand
        #expect(!h.runtime.tabs.isCollapsed(parent.id))
        try h.run("tabs.select-child")  // expanded → first child
        #expect(h.runtime.tabs.parent(of: h.selectedTab!.id) == parent.id)
        try h.run("tabs.select-parent")  // leaf → parent
        #expect(h.selectedTab?.id == parent.id)
    }

    @Test func indentAndOutdent() throws {
        let h = try harness()
        let a = h.openTab("https://a.example")
        let b = h.openTab("https://b.example")
        // order: b, a — select a and nest it under b
        h.runtime.select(a.id, in: h.window)
        try h.run("tabs.indent")
        #expect(h.runtime.tabs.parent(of: a.id) == b.id)
        try h.run("tabs.outdent")
        #expect(h.runtime.tabs.parent(of: a.id) == nil)
    }

    @Test func pinToggles() throws {
        let h = try harness()
        let a = h.openTab("https://a.example")
        try h.run("tabs.pin")
        #expect(h.runtime.tabs.isPinned(a.id))
        try h.run("tabs.pin")
        #expect(!h.runtime.tabs.isPinned(a.id))
    }

    @Test func clearTodayIsUndoable() throws {
        let h = try harness()
        h.openTab("https://a.example")
        h.openTab("https://b.example")
        try h.run("tabs.clear-today")
        #expect(h.runtime.tabs.tabCount == 0)
        #expect(h.notifications.last == "Cleared 2 tabs")
    }

    @Test func openInPlaceToggleMakesLinksSiblings() throws {
        let h = try harness()
        let a = h.openTab("https://a.example")
        try h.run("tabs.toggle-open-in-place")
        #expect(a.opensLinksInPlace)
        h.fakeTab(a).simulateOpen(URL(string: "https://b.example")!)
        #expect(h.runtime.tabs.children(of: a.id).isEmpty)
    }

    @Test func duplicateOpensAfterCurrent() throws {
        let h = try harness()
        let a = h.openTab("https://a.example")
        try h.run("tabs.duplicate")
        #expect(h.runtime.tabs.tabCount == 2)
        #expect(h.selectedTab?.id != a.id)
        #expect(h.selectedTab?.url == a.url)
    }
}
