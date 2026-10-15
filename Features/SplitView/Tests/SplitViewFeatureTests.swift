import BrowserCore
import BrowserTesting
import Testing
@testable import FeatureSplitView

@MainActor
struct SplitViewFeatureTests {
    let h: TestHarness
    let feature: SplitViewFeature

    init() throws {
        h = try TestHarness(features: [SplitViewFeature.self], manifestDirectory: #filePath)
        feature = try #require(h.runtime.feature(SplitViewFeature.self))
    }

    @Test func splitsWithThePreviousTabAndSwaps() throws {
        let a = h.openTab("https://a.example/")
        let b = h.openTab("https://b.example/")
        #expect(h.context.commands.canRun("split-view.open", in: h.window))
        try h.run("split-view.open")
        #expect(feature.model.secondary[h.window.id] == a.id)
        #expect(h.runtime.isHeldAwake(a.id) && a.isLoaded)
        #expect(!h.context.commands.canRun("split-view.open", in: h.window))
        try h.run("split-view.swap")
        #expect(h.selectedTab?.id == a.id)
        #expect(feature.model.secondary[h.window.id] == b.id)
        #expect(h.runtime.isHeldAwake(b.id) && !h.runtime.isHeldAwake(a.id))
    }

    @Test func anotherTabEndsTheSplit() throws {
        let a = h.openTab("https://a.example/")
        _ = h.openTab("https://b.example/")
        try h.run("split-view.open")
        _ = h.openTab("https://c.example/")
        #expect(feature.model.secondary[h.window.id] == nil)
        #expect(!h.runtime.isHeldAwake(a.id))
    }

    @Test func closingThePaneTabOrTheSplit() throws {
        let a = h.openTab("https://a.example/")
        _ = h.openTab("https://b.example/")
        try h.run("split-view.open")
        h.runtime.close(a.id, includingDescendants: false)
        #expect(feature.model.secondary[h.window.id] == nil)
        _ = h.openTab("https://c.example/")
        try h.run("split-view.open")
        #expect(feature.model.secondary[h.window.id] != nil)
        try h.run("split-view.close")
        #expect(feature.model.secondary[h.window.id] == nil)
    }
}
