import BrowserCore
import BrowserTesting
import JavaScriptCore
import Testing
@testable import FeatureReader

@MainActor
struct ReaderFeatureTests {
    @Test func togglesTheReaderInThePage() throws {
        let h = try TestHarness(features: [ReaderFeature.self], manifestDirectory: #filePath)
        #expect(!h.context.commands.canRun("reader.toggle", in: h.window))
        let tab = h.fakeTab(h.openTab("https://news.example/story"))
        tab.scriptResult = #"{"open":true,"title":"Story"}"#
        try h.run("reader.toggle")
        #expect(tab.evaluatedScripts.last?.contains("new Readability(document.cloneNode(true)") == true)
        #expect(h.notifications.isEmpty)
    }

    @Test func saysWhenThereIsNoArticle() throws {
        let h = try TestHarness(features: [ReaderFeature.self], manifestDirectory: #filePath)
        let tab = h.fakeTab(h.openTab("https://app.example/"))
        tab.scriptResult = #"{"open":false,"unavailable":true}"#
        try h.run("reader.toggle")
        #expect(h.notifications.last == "This page has no article to show in Reader")
    }

    /// The injected script is valid JavaScript (it's assembled from Readability and our view).
    @Test func scriptParses() throws {
        let context = try #require(JSContext())
        var error: String?
        context.exceptionHandler = { _, e in error = e?.toString() }
        context.evaluateScript("(function () { return; \n" + ReaderScripts.toggle + "\n})")
        #expect(error == nil)
    }
}
