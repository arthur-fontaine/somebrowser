import BrowserCore
import BrowserTesting
import Foundation
import Testing
@testable import FeatureHistory

@MainActor
struct HistoryTests {
    func harness() throws -> TestHarness { try TestHarness(features: [HistoryFeature.self], manifestDirectory: #filePath) }

    @Test func recordsVisitsAndRanksByFrecency() throws {
        let h = try harness()
        let service = try #require(h.runtime.capabilities.history)
        let tab = h.openTab("https://swift.org/documentation")
        h.fakeTab(tab).load(URL(string: "https://swift.org/documentation")!)
        h.openTab("https://swiftui.example/")
        let results = service.search("swift", limit: 10)
        #expect(results.first?.url.absoluteString == "https://swift.org/documentation")
        #expect(results.first?.visitCount == 2)
        #expect(service.recent(limit: 1).first?.url.host() == "swiftui.example")
    }

    @Test func privateTabsAndDisabledHistoryAreNotRecorded() throws {
        let h = try harness()
        let service = try #require(h.runtime.capabilities.history)
        let privateWindow = h.runtime.makeWindowState(isPrivate: true)
        h.runtime.openTab(URL(string: "https://secret.example")!, in: privateWindow)
        h.runtime.settings.set("history.enabled", false)
        h.openTab("https://off.example")
        #expect(service.recent(limit: 10).isEmpty)
    }

    @Test func commandBarProviderAndClearing() throws {
        let h = try harness()
        h.openTab("https://kittens.example/cute")
        let provider = try #require(h.runtime.capabilities.all(OmniboxProvider.self).first)
        #expect(provider.items(for: "kitt", in: h.window).first?.kind == "History")
        try h.run("history.clear-all")
        #expect(provider.items(for: "kitt", in: h.window).isEmpty)
    }

    @Test func frecencyDecays() {
        let now = Date()
        let fresh = HistoryEntry(url: URL(string: "https://a.example")!, title: "", lastVisit: now, visitCount: 1)
        let old = HistoryEntry(url: URL(string: "https://b.example")!, title: "", lastVisit: now.addingTimeInterval(-30 * 86_400), visitCount: 8)
        #expect(HistoryStore.frecency(fresh, now: now) > HistoryStore.frecency(old, now: now))
    }

    @Test func panelToggles() throws {
        let h = try harness()
        try h.run("history.show")
        #expect(h.window.flags.contains(HistoryFeature.panelFlag))
    }
}
