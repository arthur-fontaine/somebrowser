import BrowserCore
import BrowserTesting
import Foundation
import Testing
@testable import FeatureTabSwitcher

@MainActor
struct TabSwitcherTests {
    func harness() throws -> (TestHarness, SwitcherModel) {
        let h = try TestHarness(features: [TabSwitcherFeature.self], manifestDirectory: #filePath)
        return (h, try #require(h.runtime.feature(TabSwitcherFeature.self)?.model))
    }

    @Test func cyclesMostRecentlyUsedAndCommitsOnRelease() throws {
        let (h, model) = try harness()
        let a = h.openTab("https://a.example")
        let b = h.openTab("https://b.example")
        let c = h.openTab("https://c.example")
        // MRU: c, b, a
        try h.run("tab-switcher.next")
        #expect(model.cycles[h.window.id]?.tabs == [c.id, b.id, a.id])
        try h.run("tab-switcher.next")
        model.commit(in: h.window)
        #expect(h.selectedTab?.id == a.id)
        // Quick ⌃⇥ toggles between the two most recent tabs.
        try h.run("tab-switcher.next")
        model.commit(in: h.window)
        #expect(h.selectedTab?.id == c.id)
        _ = b
    }

    @Test func backwardsAndCloseHighlighted() throws {
        let (h, model) = try harness()
        let a = h.openTab("https://a.example")
        h.openTab("https://b.example")
        h.openTab("https://c.example")
        try h.run("tab-switcher.previous")
        #expect(model.cycles[h.window.id]?.tabs[model.cycles[h.window.id]!.index] == a.id)
        model.closeHighlighted(in: h.window)
        #expect(h.runtime.tabs.tab(a.id) == nil)
        model.cancel(in: h.window)
        #expect(model.cycles[h.window.id] == nil)
    }

    @Test func singleTabDoesNothing() throws {
        let (h, model) = try harness()
        h.openTab("https://a.example")
        try h.run("tab-switcher.next")
        #expect(model.cycles[h.window.id] == nil)
    }
}
