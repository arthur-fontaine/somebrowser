import AppKit
import BrowserCore
import BrowserTesting
import Foundation
import Testing
@testable import FeatureNavigation

@MainActor
struct NavigationTests {
    func harness() throws -> TestHarness { try TestHarness(features: [NavigationFeature.self], manifestDirectory: #filePath) }

    @Test func backForwardFollowHistory() throws {
        let h = try harness()
        let tab = h.openTab("https://a.example")
        h.fakeTab(tab).load(URL(string: "https://b.example")!)
        #expect(h.runtime.commands.canRun("navigation.back"))
        #expect(!h.runtime.commands.canRun("navigation.forward"))
        try h.run("navigation.back")
        #expect(tab.live?.url?.host() == "a.example")
        try h.run("navigation.forward")
        #expect(tab.live?.url?.host() == "b.example")
    }

    @Test func commandsAreDisabledWithoutAPage() throws {
        let h = try harness()
        #expect(!h.runtime.commands.canRun("navigation.reload"))
        #expect(throws: CommandError.self) { try h.run("navigation.reload") }
    }

    @Test func developerToolsOpenOnTheAskedPanelAndPagesSave() throws {
        let h = try harness()
        let page = h.fakeTab(h.openTab("https://a.example"))
        for command in ["navigation.devtools", "navigation.console", "navigation.inspect-element"] { try h.run(command) }
        #expect(page.devToolsPanels == [.default, .console, .inspectElement])
        try h.run("navigation.save-page")
        #expect(page.savePageCount == 1)
    }

    @Test func zoomStepsAndIsRememberedPerHost() throws {
        let h = try harness()
        let tab = h.openTab("https://a.example")
        try h.run("navigation.zoom-in")
        #expect(h.fakeTab(tab).zoomFactor == 1.1)
        try h.run("navigation.zoom-in")
        #expect(h.fakeTab(tab).zoomFactor == 1.25)
        try h.run("navigation.zoom-reset")
        #expect(h.fakeTab(tab).zoomFactor == 1)
        try h.run("navigation.zoom-out")
        let other = h.openTab("https://a.example/page")
        #expect(h.fakeTab(other).zoomFactor == 0.9)
    }

    @Test func copyURLStripsTrackers() throws {
        let h = try harness()
        h.openTab("https://shop.example/item?id=4&utm_source=x&fbclid=abc&ref=keep")
        try h.run("navigation.copy-url")
        #expect(NSPasteboard.general.string(forType: .string) == "https://shop.example/item?id=4&ref=keep")
        try h.run("navigation.copy-markdown")
        #expect(NSPasteboard.general.string(forType: .string) == "[shop.example](https://shop.example/item?id=4&ref=keep)")
    }

    @Test func cleanerKeepsURLsWithoutQuery() {
        #expect(URLCleaner.clean(URL(string: "https://a.example/p#x")!).absoluteString == "https://a.example/p#x")
        #expect(URLCleaner.clean(URL(string: "https://a.example/?utm_medium=a")!).absoluteString == "https://a.example/")
    }
}
