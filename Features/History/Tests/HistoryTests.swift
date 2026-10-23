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

    @Test func importMergesWithExistingHistory() throws {
        let h = try harness()
        let service = try #require(h.runtime.capabilities.history)
        h.openTab("https://swift.org/")
        let old = Date(timeIntervalSince1970: 1_000_000)
        service.importEntries([
            HistoryEntry(url: URL(string: "https://swift.org/")!, title: "Old title", lastVisit: old, visitCount: 5),
            HistoryEntry(url: URL(string: "https://imported.example/a")!, title: "Imported", lastVisit: old, visitCount: 3),
            HistoryEntry(url: URL(string: "chrome://settings")!, title: "Settings", lastVisit: old, visitCount: 1),
        ])
        let swift = try #require(service.search("swift.org", limit: 5).first)
        #expect(swift.visitCount == 6)
        #expect(swift.lastVisit > old)  // the newer local visit wins
        let imported = try #require(service.search("imported", limit: 5).first)
        #expect(imported.title == "Imported" && imported.visitCount == 3 && imported.lastVisit == old)
        #expect(service.search("settings", limit: 5).isEmpty)
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

    /// The editor opens on the page's address: found by prefix, and a prefix shared by many pages still finds the latest.
    @Test func addressesAreFoundByPrefix() throws {
        let store = HistoryStore(path: ":memory:")
        let now = Date()
        store.importEntries((0..<500).map { i in
            HistoryEntry(url: URL(string: "https://busy.example/page/\(i)")!, title: "", lastVisit: now.addingTimeInterval(Double(i)), visitCount: 1)
        })
        store.record(url: URL(string: "https://claude.example/new")!, title: "New chat")
        #expect(store.search("https://claude.example/new", limit: 5).map(\.title) == ["New chat"])
        #expect(store.search("https://claude.example/n", limit: 5).count == 1)
        #expect(store.search("https://nowhere.example/", limit: 5).isEmpty)
        #expect(store.search("https://busy.example/page/", limit: 1).first?.url.lastPathComponent == "499")
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

    @Test func frequentSitesAddUpTheirPagesAndLeaveFavoritesOut() throws {
        let h = try harness()
        let feature = try #require(h.runtime.feature(HistoryFeature.self))
        let old = Date(timeIntervalSince1970: 1_000_000)
        feature.store.importEntries([
            HistoryEntry(url: URL(string: "https://www.a.example/1")!, title: "A1", lastVisit: old, visitCount: 3),
            HistoryEntry(url: URL(string: "https://a.example/2")!, title: "A2", lastVisit: old, visitCount: 4),
            HistoryEntry(url: URL(string: "https://b.example/")!, title: "B", lastVisit: old, visitCount: 6),
            HistoryEntry(url: URL(string: "https://fav.example/")!, title: "Fav", lastVisit: old, visitCount: 50),
        ])
        let sites = feature.store.frequentSites(limit: 5, excluding: ["fav.example"])
        // a.example's two pages (7 visits) outrank b.example (6); each site shows its most visited page.
        #expect(sites.map(\.url.absoluteString) == ["https://a.example/2", "https://b.example/"])
    }
}
