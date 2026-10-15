import BrowserCore
import BrowserTesting
import Foundation
import JavaScriptCore
import Testing
@testable import FeatureBoosts

@MainActor
struct BoostsFeatureTests {
    let h: TestHarness
    let feature: BoostsFeature

    init() throws {
        h = try TestHarness(features: [BoostsFeature.self], manifestDirectory: #filePath)
        feature = try #require(h.runtime.feature(BoostsFeature.self))
    }

    @Test func boostsRunAtDocumentStartOnTheirSiteOnly() throws {
        feature.save(Boost(css: "body { color: red }", js: "document.title = 'mine'", zapped: [".promo"]), site: "news.example")
        let script = try #require(h.engine.hooks.documentStartScript(for: URL(string: "https://www.news.example/a")!))
        #expect(script.contains("body { color: red }") && script.contains(".promo { display: none !important; }"))
        #expect(script.contains("document.title = 'mine'"))
        #expect(h.engine.hooks.documentStartScript(for: URL(string: "https://other.example/")!) == nil)
        // Off keeps it but doesn't run it.
        var off = try #require(feature.boost(site: "news.example"))
        off.enabled = false
        feature.save(off, site: "news.example")
        #expect(h.engine.hooks.documentStartScript(for: URL(string: "https://news.example/")!) == nil)
    }

    @Test func scriptsMustParse() throws {
        #expect(Boost.syntaxError(in: "document.title = 'ok'") == nil)
        #expect(Boost.syntaxError(in: "document.title = (") != nil)
        // A broken script never reaches the page (it would break other features' injections).
        let script = try #require(Boost(css: "p { margin: 0 }", js: "brokenScript(").documentStartScript)
        #expect(!script.contains("brokenScript"))
        let context = try #require(JSContext())
        var error: String?
        context.exceptionHandler = { _, e in error = e?.toString() }
        context.evaluateScript("(function () {\n" + script + "\n})")
        #expect(error == nil)
    }

    @Test func editorSavesAndRejectsBrokenScripts() throws {
        let tab = h.fakeTab(h.openTab("https://news.example/story"))
        try h.run("boosts.edit")
        #expect(h.window.flags.contains(BoostsFeature.editorFlag))
        feature.model.draft.js = "let x = "
        feature.saveDraft(in: h.window)
        #expect(feature.model.error?.hasPrefix("JavaScript:") == true)
        #expect(feature.boost(site: "news.example") == nil)
        feature.model.draft.js = ""
        feature.model.draft.css = "h1 { color: teal }"
        feature.saveDraft(in: h.window)
        #expect(feature.boost(site: "news.example")?.css == "h1 { color: teal }")
        #expect(!h.window.flags.contains(BoostsFeature.editorFlag))
        _ = tab
    }

    /// Only a tab in zap mode adds zapped elements (any page could post the message).
    @Test func zapsOnlyInZapMode() throws {
        let tab = h.fakeTab(h.openTab("https://news.example/story"))
        tab.simulateScriptMessage("boosts.zap", body: ["selector": "#ad"])
        #expect(feature.boost(site: "news.example") == nil)
        try h.run("boosts.zap")
        #expect(tab.evaluatedScripts.last?.contains("__browserZap") == true)
        tab.simulateScriptMessage("boosts.zap", body: ["selector": "#ad"])
        tab.simulateScriptMessage("boosts.zap", body: ["selector": "div.banner"], mainFrame: false)
        #expect(feature.boost(site: "news.example")?.zapped == ["#ad"])
        tab.simulateScriptMessage("boosts.zap-end", body: [:])
        tab.simulateScriptMessage("boosts.zap", body: ["selector": "#more"])
        #expect(feature.boost(site: "news.example")?.zapped == ["#ad"])
    }

    @Test func zapScriptParses() throws {
        let context = try #require(JSContext())
        var error: String?
        context.exceptionHandler = { _, e in error = e?.toString() }
        context.evaluateScript("(function () { return; \n" + ZapScript.start + "\n})")
        #expect(error == nil)
    }
}
