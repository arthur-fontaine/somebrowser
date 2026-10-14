import BrowserCore
import BrowserTesting
import Foundation
import Testing
@testable import FeatureToolbar

@MainActor
struct ToolbarTests {
    func harness() throws -> (TestHarness, ToolbarModel) {
        let h = try TestHarness(features: [ToolbarFeature.self], manifestDirectory: #filePath)
        return (h, try #require(h.runtime.feature(ToolbarFeature.self)?.model))
    }

    @Test func placementFollowsModeAndSidebar() throws {
        let (h, model) = try harness()
        #expect(model.placement(for: h.window) == .hidden)
        h.window.isSidebarVisible = false
        #expect(model.placement(for: h.window) == .overlay)
        h.runtime.settings.set("toolbar.mode", .string("always"))
        #expect(model.placement(for: h.window) == .layout)
        h.runtime.settings.set("toolbar.mode", .string("never"))
        #expect(model.placement(for: h.window) == .hidden)
        try h.run("toolbar.toggle")
        #expect(model.placement(for: h.window) == .layout)
    }

    @Test func scrollingDownHidesAndUpShows() throws {
        let (h, _) = try harness()
        let tab = h.openTab("https://a.example")
        let page = h.fakeTab(tab)
        page.simulateScriptMessage("toolbar.scroll", body: ["dir": 1])
        #expect(!h.window.isToolbarVisible)
        page.simulateScriptMessage("toolbar.scroll", body: ["dir": -1])
        #expect(h.window.isToolbarVisible)
        #expect(h.window.titlebarRequests.contains("toolbar"))
        h.runtime.settings.set("toolbar.hideOnScroll", false)
        page.simulateScriptMessage("toolbar.scroll", body: ["dir": 1])
        #expect(h.window.isToolbarVisible)
    }

    @Test func injectsTheScrollObserver() throws {
        let (h, _) = try harness()
        #expect(h.engine.hooks.userScripts.contains { $0.source.contains("toolbar.scroll") })
    }
}
