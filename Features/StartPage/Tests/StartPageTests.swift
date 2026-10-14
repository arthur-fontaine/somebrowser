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
}
