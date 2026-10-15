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

/// Brave's resources.json format: a redirect stand-in and a scriptlet template.
nonisolated let resourcesJSON = """
[{"name":"noop.js","aliases":["noopjs"],"kind":{"mime":"application/javascript"},"content":"\(Data("(function(){})();".utf8).base64EncodedString())"},
 {"name":"set-flag.js","aliases":["set-flag"],"kind":"template","content":"\(Data("window.flag = '{{1}}';".utf8).base64EncodedString())"}]
"""
nonisolated let resourceList = """
||ads.example/ima.js$script,redirect=noop.js
news.example##+js(set-flag, on)
"""

struct ResourceTests {
    @Test func redirectsAnswerWithStandInsAndScriptletsRun() throws {
        let engine = AdBlockEngine(lists: resourceList)
        // Without resources a redirect filter still blocks.
        #expect(engine.check(url: "https://ads.example/ima.js", source: "https://news.example/", type: "script") == .block)
        #expect(engine.useResources(json: resourcesJSON) == 2)
        #expect(engine.check(url: "https://ads.example/ima.js", source: "https://news.example/", type: "script")
            == .respond(mimeType: "application/javascript", body: Data("(function(){})();".utf8)))
        let cosmetic = try #require(engine.cosmetic(for: "https://news.example/a"))
        #expect(cosmetic.injected_script.contains("window.flag = 'on'"))
        #expect(engine.useResources(json: "not json") == nil)
    }

    @Test func parsesDataURLs() {
        #expect(AdBlockEngine.parseDataURL("data:text/plain;base64,aGk=")?.body == Data("hi".utf8))
        #expect(AdBlockEngine.parseDataURL("data:text/html,%3Cp%3E")! == (mimeType: "text/html", body: Data("<p>".utf8)))
        #expect(AdBlockEngine.parseDataURL("https://x.example/") == nil)
    }
}

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

    @Test func contentRulesFitWebKitsLimit() throws {
        let rule = { (type: String) -> [String: Any] in ["trigger": ["url-filter": "x"], "action": ["type": type]] }
        let rules = [rule("block"), rule("css-display-none"), rule("block"), rule("block"), rule("ignore-previous-rules")]
        let json = String(decoding: try JSONSerialization.data(withJSONObject: rules), as: UTF8.self)
        let fitted = try #require(try JSONSerialization.jsonObject(with: Data(AdBlockEngine.fitContentRules(json, limit: 3).utf8)) as? [[String: Any]])
        let types = fitted.compactMap { ($0["action"] as? [String: Any])?["type"] as? String }
        #expect(types == ["block", "block", "ignore-previous-rules"])
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

    /// Navigations are cleaned of tracking parameters, never blocked.
    @Test func navigationsAreCleanedNotBlocked() {
        let s = shield()
        #expect(s.verdict(for: WebRequest(url: URL(string: "https://shop.example/?utm_source=x&id=1")!, documentURL: nil, type: .document))
            == .redirect(URL(string: "https://shop.example/?id=1")!))
        #expect(s.verdict(for: WebRequest(url: URL(string: "https://tracker.example/")!, documentURL: nil, type: .document)) == .allow)
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
        // Resources come with the lists and are loaded again with the cache.
        let withResources = try await store.update(contentRules: false) { url in
            Data((url == store.resourcesURL ? resourcesJSON : url.absoluteString.contains("privacy") ? privacyList : adsList + "\n" + resourceList).utf8)
        }
        let stub = AdBlockEngine.Verdict.respond(mimeType: "application/javascript", body: Data("(function(){})();".utf8))
        #expect(withResources.ads.check(url: "https://ads.example/ima.js", source: "https://x.example/", type: "script") == stub)
        #expect(store.loadCached(contentRules: false)?.ads.check(url: "https://ads.example/ima.js", source: "https://x.example/", type: "script") == stub)
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
        let ads = AdBlockEngine(lists: adsList + "\n" + resourceList)
        ads.useResources(json: resourcesJSON)
        feature.install(.init(ads: ads, privacy: AdBlockEngine(lists: privacyList), contentRules: nil))
        #expect(h.engine.simulateRequest(URL(string: "https://ads.example/x.js")!, documentURL: URL(string: "https://news.example/")) == .block)
        #expect(h.engine.simulateRequest(URL(string: "https://ads.example/ima.js")!, documentURL: URL(string: "https://news.example/"))
            == .respond(mimeType: "application/javascript", body: Data("(function(){})();".utf8)))
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
        let tab = h.fakeTab(h.openTab("https://www.blog.example/post"))
        // An ad iframe can't speak for the page…
        tab.simulateScriptMessage("adblock.creator", body: [:], mainFrame: false, frameURL: URL(string: "https://ads.example/f"))
        #expect(h.engine.simulateRequest(URL(string: "https://ads.example/x.js")!, documentURL: URL(string: "https://www.blog.example/")) == .block)
        // …the top document can.
        tab.simulateScriptMessage("adblock.creator", body: ["host": "elsewhere.example"])
        #expect(h.runtime.siteSettings.bool("adblock.creator", for: "blog.example") == true)
        #expect(h.runtime.siteSettings.bool("adblock.creator", for: "elsewhere.example") == nil)
        #expect(h.engine.simulateRequest(URL(string: "https://ads.example/x.js")!, documentURL: URL(string: "https://www.blog.example/")) == .allow)
    }

    @Test func localServersDontTriggerListDownloads() {
        #expect(AdBlockFeature.isLocal(URL(string: "http://127.0.0.1:8080/")!))
        #expect(AdBlockFeature.isLocal(URL(string: "http://localhost:3000/")!))
        #expect(AdBlockFeature.isLocal(URL(string: "http://printer.local/")!))
        #expect(!AdBlockFeature.isLocal(URL(string: "https://news.example/")!))
    }

    @Test func navigationInjectsCosmeticFilters() throws {
        let h = try TestHarness(features: [AdBlockFeature.self], manifestDirectory: #filePath)
        let feature = try #require(h.runtime.feature(AdBlockFeature.self))
        feature.install(.init(ads: AdBlockEngine(lists: adsList), privacy: AdBlockEngine(lists: privacyList), contentRules: nil))
        let tab = h.fakeTab(h.openTab("https://news.example/story"))
        #expect(tab.evaluatedScripts.contains { $0.contains(".sponsored") })
    }
}
