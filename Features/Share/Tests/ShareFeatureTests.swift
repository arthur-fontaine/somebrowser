import BrowserCore
import BrowserTesting
import Foundation
import Testing
@testable import FeatureShare

@MainActor
struct ShareFeatureTests {
    @Test func sharesWebPagesOnly() throws {
        let h = try TestHarness(features: [ShareFeature.self], manifestDirectory: #filePath)
        let feature = try #require(h.runtime.feature(ShareFeature.self))
        #expect(!h.context.commands.canRun("share.page"))  // a blank window
        h.runtime.openTab(URL(string: "https://example.com/a"), in: h.window)
        #expect(feature.url(in: h.window)?.absoluteString == "https://example.com/a")
        #expect(h.context.commands.canRun("share.page"))
        h.runtime.openTab(URL(string: "about:blank"), in: h.window)
        #expect(feature.url(in: h.window) == nil)
    }
}
