import AppKit
import BrowserCore
import BrowserTesting
import Foundation
import Testing
@testable import FeaturePeek

@MainActor
struct PeekTests {
    func harness() throws -> (TestHarness, PeekFeature) {
        let h = try TestHarness(features: [PeekFeature.self], manifestDirectory: #filePath)
        let feature = try #require(h.runtime.feature(PeekFeature.self))
        feature.model.growDuration = 0.02
        feature.model.expandDuration = 0.15
        feature.model.closeDuration = 0.15
        feature.model.fadeDuration = 0.02
        feature.model.hideDelay = 0.01
        return (h, feature)
    }

    func click(_ tab: BrowserTab, to url: String, shift: Bool = false, h: TestHarness) -> NavigationPolicy {
        h.engine.hooks.decide(NavigationAction(url: URL(string: url)!, sourceTab: tab.engineTab, isMainFrame: true,
                                               userGesture: true, modifiers: shift ? [.shift] : []))
    }

    @Test func pinnedTabsPreviewOtherSites() async throws {
        let (h, feature) = try harness()
        let mail = h.openTab("https://mail.example/inbox")
        h.runtime.tabs.pin(mail.id, in: h.window.spaceID)
        #expect(click(mail, to: "https://mail.example/other", h: h) == .allow)  // same site navigates
        #expect(click(mail, to: "https://news.example/story", h: h) == .handled)
        try await Task.sleep(for: .milliseconds(50))
        #expect(feature.model.session(for: h.window) != nil)
        #expect(h.runtime.commands.canRun("peek.expand"))
    }

    @Test func todayTabsNavigateUnlessShiftClicked() async throws {
        let (h, feature) = try harness()
        let page = h.openTab("https://a.example")
        #expect(click(page, to: "https://b.example", h: h) == .allow)
        #expect(click(page, to: "https://b.example", shift: true, h: h) == .handled)
        try await Task.sleep(for: .milliseconds(50))
        #expect(feature.model.session(for: h.window)?.engineTab.state.url?.host() == "b.example")
    }

    @Test func expandAdoptsThePageAsAChildTab() async throws {
        let (h, feature) = try harness()
        let page = h.openTab("https://a.example")
        feature.model.open(URL(string: "https://b.example")!, in: h.window)
        let preview = try #require(feature.model.session(for: h.window)?.engineTab as? FakeEngineTab)
        preview.snapshotImage = NSImage(size: NSSize(width: 10, height: 10))
        try h.run("peek.expand")
        // The page is put away under its snapshot before the card moves; the snapshot grows into the page's place.
        #expect(feature.model.session(for: h.window)?.hidesPage == true)
        #expect(feature.model.session(for: h.window)?.phase != .expanding)
        try await Task.sleep(for: .milliseconds(60))
        #expect(feature.model.session(for: h.window)?.phase == .expanding)
        #expect(feature.model.session(for: h.window)?.snapshot != nil)
        #expect(h.selectedTab?.id == page.id)
        try await Task.sleep(for: .milliseconds(300))
        #expect(feature.model.session(for: h.window) == nil)
        #expect(h.selectedTab?.engineTab === preview)
        #expect(h.runtime.tabs.parent(of: h.selectedTab!.id) == page.id)
        #expect(!(preview as! FakeEngineTab).isClosed)
    }

    @Test func closeReleasesThePage() async throws {
        let (h, feature) = try harness()
        h.openTab("https://a.example")
        feature.model.open(URL(string: "https://b.example")!, in: h.window)
        let preview = try #require(feature.model.session(for: h.window)?.engineTab as? FakeEngineTab)
        try h.run("peek.close")
        try await Task.sleep(for: .milliseconds(500))
        #expect(preview.isClosed)
    }

    @Test func growsBeforeThePageShowsFromTheClick() async throws {
        let (h, feature) = try harness()
        h.openTab("https://a.example")
        feature.model.open(URL(string: "https://b.example")!, in: h.window, from: CGPoint(x: 300, y: 200))
        #expect(feature.model.session(for: h.window)?.phase == .growing)
        #expect(feature.model.session(for: h.window)?.origin == CGPoint(x: 300, y: 200))
        try await Task.sleep(for: .milliseconds(100))
        #expect(feature.model.session(for: h.window)?.phase == .live)
    }

    @Test func withoutASnapshotTheBareCardLeaves() async throws {
        let (h, feature) = try harness()
        h.openTab("https://a.example")
        feature.model.snapshotTimeout = 0.02
        feature.model.open(URL(string: "https://b.example")!, in: h.window)
        let preview = try #require(feature.model.session(for: h.window)?.engineTab as? FakeEngineTab)
        preview.snapshotImage = nil
        try h.run("peek.close")
        try await Task.sleep(for: .milliseconds(60))
        #expect(feature.model.session(for: h.window)?.phase == .closing)  // no snapshot: the stand-in leaves
        try await Task.sleep(for: .milliseconds(300))
        #expect(feature.model.session(for: h.window) == nil)
        #expect(preview.isClosed)
    }
}
