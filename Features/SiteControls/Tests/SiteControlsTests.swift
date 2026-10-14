import BrowserCore
import BrowserTesting
import Foundation
import Testing
@testable import FeatureSiteControls

@MainActor
struct SiteControlsTests {
    func harness() throws -> (TestHarness, SiteControlsFeature) {
        let h = try TestHarness(features: [SiteControlsFeature.self], manifestDirectory: #filePath)
        return (h, try #require(h.runtime.feature(SiteControlsFeature.self)))
    }

    @Test func showsOnlyWithAPage() throws {
        let (h, _) = try harness()
        #expect(!h.runtime.commands.canRun("site-controls.show"))
        h.openTab("https://a.example")
        try h.run("site-controls.show")
        #expect(h.window.flags.contains(SiteControlsFeature.flag))
        h.openTab("https://b.example")
        #expect(!h.window.flags.contains(SiteControlsFeature.flag))
    }

    @Test func soundIsRememberedPerSite() throws {
        let (h, feature) = try harness()
        let a = h.openTab("https://noisy.example/1")
        feature.setMuted(true, site: "noisy.example")
        #expect(h.fakeTab(a).isMuted)
        let b = h.openTab("https://noisy.example/2")
        #expect(h.fakeTab(b).isMuted)
        feature.setMuted(false, site: "noisy.example")
        #expect(!h.fakeTab(a).isMuted)
        #expect(h.runtime.siteSettings.all(for: "noisy.example").isEmpty)
    }
}
