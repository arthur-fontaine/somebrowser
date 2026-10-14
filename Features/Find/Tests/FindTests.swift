import BrowserCore
import BrowserTesting
import Foundation
import Testing
@testable import FeatureFind

@MainActor
struct FindTests {
    @Test func findShowsSearchesAndHides() throws {
        let h = try TestHarness(features: [FindFeature.self], manifestDirectory: #filePath)
        let model = try #require(h.runtime.feature(FindFeature.self)?.model)
        #expect(!h.runtime.commands.canRun("find.show"))
        let tab = h.openTab("https://a.example")
        try h.run("find.show")
        #expect(h.window.flags.contains(FindModel.flag))
        model.setQuery("swift", in: h.window)
        #expect(model.result(in: h.window) == FindResult(matches: 3, activeIndex: 1))
        try h.run("find.previous")
        #expect(model.result(in: h.window)?.activeIndex == 3)
        try h.run("find.hide")
        #expect(!h.window.flags.contains(FindModel.flag))
        #expect(h.fakeTab(tab).state.findResult == nil)
    }

    @Test func switchingTabsClosesTheBar() throws {
        let h = try TestHarness(features: [FindFeature.self], manifestDirectory: #filePath)
        let a = h.openTab("https://a.example")
        h.openTab("https://b.example")
        try h.run("find.show")
        h.runtime.select(a.id, in: h.window)
        #expect(!h.window.flags.contains(FindModel.flag))
    }
}
