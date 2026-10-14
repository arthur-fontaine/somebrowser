import BrowserCore
import BrowserTesting
import Foundation
import Testing
@testable import FeatureAdblock

nonisolated let adsList = """
||ads.example^
##.ad-banner
news.example##.sponsored
@@||ads.example/allowed.js
"""
nonisolated let privacyList = """
||tracker.example^
$removeparam=utm_source
"""

struct EngineTests {
    @Test func blocksAllowsAndExcepts() {
        let engine = AdBlockEngine(lists: adsList)
        #expect(engine.check(url: "https://ads.example/banner.js", source: "https://news.example/", type: "script") == .block)
        #expect(engine.check(url: "https://ads.example/allowed.js", source: "https://news.example/", type: "script") == .allow)
        #expect(engine.check(url: "https://cdn.example/app.js", source: "https://news.example/", type: "script") == .allow)
    }

    @Test func cleansTrackingParameters() {
        let engine = AdBlockEngine(lists: privacyList)
        #expect(engine.check(url: "https://shop.example/?utm_source=x&id=1", source: "https://shop.example/", type: "document")
            == .rewrite(URL(string: "https://shop.example/?id=1")!))
    }

    @Test func cosmeticResources() throws {
        let engine = AdBlockEngine(lists: adsList)
        let c = try #require(engine.cosmetic(for: "https://news.example/a"))
        #expect(c.hide_selectors.contains(".sponsored"))
        #expect(engine.hiddenSelectors(classes: ["ad-banner", "content"], ids: [], exceptions: []) == [".ad-banner"])
    }

    @Test func serializedEnginesRestore() throws {
        let data = AdBlockEngine(lists: adsList).serialized
        let restored = try #require(AdBlockEngine(serialized: data))
        #expect(restored.check(url: "https://ads.example/x.js", source: "https://a.example/", type: "script") == .block)
        #expect(AdBlockEngine(serialized: Data("garbage".utf8)) == nil)
    }

    @Test func contentBlockingRulesForWebKit() throws {
        let json = AdBlockEngine.contentBlockingRules(lists: adsList)
        let rules = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]])
        #expect(!rules.isEmpty)
    }
}

struct ShieldTests {
    func shield() -> Shield {
        let s = Shield()
        s.install(.init(ads: AdBlockEngine(lists: adsList), privacy: AdBlockEngine(lists: privacyList), contentRules: nil))
        return s
    }
    func request(_ url: String, on page: String, _ type: WebRequest.ResourceType = .script) -> WebRequest {
        WebRequest(url: URL(string: url)!, documentURL: URL(string: page)!, type: type)
    }

    @Test func blocksAdsAndTrackersAndCounts() {
        let s = shield()
        #expect(s.verdict(for: request("https://ads.example/a.js", on: "https://news.example/")) == .block)
        #expect(s.verdict(for: request("https://tracker.example/t.gif", on: "https://news.example/", .image)) == .block)
        #expect(s.verdict(for: request("https://news.example/app.js", on: "https://news.example/")) == .allow)
        #expect(s.blockedCount(for: "news.example") == 2)
        #expect(s.verdict(for: request("https://ads.example/", on: "https://news.example/", .document)) == .allow)
    }

    @Test func siteSwitchAndCreatorMode() {
        let s = shield()
        s.configure(enabled: true, supportCreators: true, disabledSites: ["off.example"], creatorSites: ["blog.example"])
        #expect(s.verdict(for: request("https://ads.example/a.js", on: "https://off.example/")) == .allow)
        // A creator-friendly site keeps its ads, but trackers stay blocked.
        #expect(s.verdict(for: request("https://ads.example/a.js", on: "https://blog.example/")) == .allow)
        #expect(s.verdict(for: request("https://tracker.example/t.js", on: "https://blog.example/")) == .block)
        s.configure(enabled: true, supportCreators: false, disabledSites: [], creatorSites: ["blog.example"])
        #expect(s.verdict(for: request("https://ads.example/a.js", on: "https://blog.example/")) == .block)
        s.configure(enabled: false, supportCreators: true, disabledSites: [], creatorSites: [])
        #expect(s.verdict(for: request("https://ads.example/a.js", on: "https://news.example/")) == .allow)
    }
}

struct ListStoreTests {
    @Test func downloadsCompilesAndCaches() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("adblock-\(UUID().uuidString.prefix(6))")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = FilterListStore(directory: dir)
        #expect(store.isStale)
        #expect(store.loadCached(contentRules: false) == nil)
        let engines = try await store.update(contentRules: true) { url in
            Data((url.absoluteString.contains("privacy") ? privacyList : adsList).utf8)
        }
        #expect(engines.ads.check(url: "https://ads.example/a.js", source: "https://x.example/", type: "script") == .block)
        #expect(engines.contentRules?.isEmpty == false)
        #expect(!store.isStale)
        let cached = try #require(store.loadCached(contentRules: true))
        #expect(cached.privacy.check(url: "https://tracker.example/", source: "https://x.example/", type: "image") == .block)
        // A failing download keeps the previous copy.
        let again = try await store.update(contentRules: false) { _ in throw URLError(.notConnectedToInternet) }
        #expect(again.ads.check(url: "https://ads.example/a.js", source: "https://x.example/", type: "script") == .block)
    }
}

@MainActor
struct FeatureTests {
    @Test func requestsGoThroughTheEngineHook() throws {
        let h = try TestHarness(features: [AdBlockFeature.self], manifestDirectory: #filePath)
        let feature = try #require(h.runtime.feature(AdBlockFeature.self))
        feature.install(.init(ads: AdBlockEngine(lists: adsList), privacy: AdBlockEngine(lists: privacyList), contentRules: nil))
        #expect(h.engine.simulateRequest(URL(string: "https://ads.example/x.js")!, documentURL: URL(string: "https://news.example/")) == .block)
        let tab = h.openTab("https://news.example/")
        try h.run("adblock.toggle-site")
        #expect(h.runtime.siteSettings.bool("adblock.enabled", for: "news.example") == false)
        #expect(h.engine.simulateRequest(URL(string: "https://ads.example/x.js")!, documentURL: URL(string: "https://news.example/")) == .allow)
        _ = tab
    }

    @Test func creatorDeclarationIsRemembered() throws {
        let h = try TestHarness(features: [AdBlockFeature.self], manifestDirectory: #filePath)
        let feature = try #require(h.runtime.feature(AdBlockFeature.self))
        feature.install(.init(ads: AdBlockEngine(lists: adsList), privacy: AdBlockEngine(lists: privacyList), contentRules: nil))
        feature.creatorDeclared(["host": "www.blog.example"])
        #expect(h.engine.simulateRequest(URL(string: "https://ads.example/x.js")!, documentURL: URL(string: "https://www.blog.example/")) == .allow)
    }

    @Test func navigationInjectsCosmeticFilters() throws {
        let h = try TestHarness(features: [AdBlockFeature.self], manifestDirectory: #filePath)
        let feature = try #require(h.runtime.feature(AdBlockFeature.self))
        feature.install(.init(ads: AdBlockEngine(lists: adsList), privacy: AdBlockEngine(lists: privacyList), contentRules: nil))
        let tab = h.fakeTab(h.openTab("https://news.example/story"))
        #expect(tab.evaluatedScripts.contains { $0.contains(".sponsored") })
    }
}
