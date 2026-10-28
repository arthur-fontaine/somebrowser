import BrowserCore
import BrowserTesting
import Foundation
import Testing
@testable import FeatureStartPage

@MainActor
struct StartPageTests {
    @Test func submitFillsTheBlankTabOrOpensOne() throws {
        let h = try TestHarness(features: [StartPageFeature.self], manifestDirectory: #filePath)
        #expect(h.runtime.ui.views(for: .emptyContent).count == 1)
        StartPageFeature.submit("https://a.example", window: h.window, runtime: h.runtime)
        #expect(h.runtime.tabs.tabCount == 1)
        h.runtime.openTab(nil, in: h.window)
        StartPageFeature.submit("https://b.example", window: h.window, runtime: h.runtime)
        #expect(h.runtime.tabs.tabCount == 2)
        #expect(h.selectedTab?.url?.host() == "b.example")
        StartPageFeature.submit("   ", window: h.window, runtime: h.runtime)
        #expect(h.runtime.tabs.tabCount == 2)
    }

    @Test func sectionsKeepTheirArrangementAndNewOnesLandByDefault() {
        // Saved: Safari's tabs above favorites; archive.recent is new, history.frequent gone.
        let saved = ["safari.tabs", "start-page.favorites", "history.frequent"]
        let available = ["start-page.favorites", "archive.recent", "safari.favorites", "safari.tabs"]
        #expect(StartPageLayout.arrange(saved, available) == ["safari.tabs", "start-page.favorites", "archive.recent", "safari.favorites"])
        #expect(StartPageLayout.arrange([], available) == available)
    }

    @Test func movesSkipEmptySectionsAndPersist() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("layout-\(UUID().uuidString).json")
        let available = ["a", "b", "c", "d"]
        let layout = StartPageLayout(file: file)
        layout.visible = ["a", "c", "d"]  // b shows nothing
        #expect(layout.neighbour(of: "c", -1, in: available) == "a")
        #expect(layout.neighbour(of: "a", -1, in: available) == nil)
        layout.move("c", to: "a", in: available)
        #expect(layout.order == ["c", "a", "b", "d"])
        layout.move("c", to: "d", in: available)  // dragged down past the others
        #expect(layout.order == ["a", "b", "d", "c"])
        layout.save()
        #expect(StartPageLayout(file: file).order == ["a", "b", "d", "c"])
    }
}
