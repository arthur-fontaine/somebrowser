import BrowserCore
import BrowserTesting
import Foundation
import Testing
@testable import FeatureHibernation

@MainActor
struct HibernationFeatureTests {
    let h: TestHarness
    let feature: HibernationFeature

    init() throws {
        h = try TestHarness(features: [HibernationFeature.self], manifestDirectory: #filePath)
        feature = try #require(h.runtime.feature(HibernationFeature.self))
    }

    /// Opens a background tab last looked at `minutes` ago.
    func idleTab(_ host: String, minutes: Double) -> BrowserTab {
        let tab = h.openTab("https://\(host)/", select: false)
        h.runtime.live(tab)
        tab.lastActiveAt = Date().addingTimeInterval(-minutes * 60)
        return tab
    }

    @Test func idleBackgroundTabsHibernateAndWakeOnSelect() {
        let shown = h.openTab("https://shown.example/")
        shown.lastActiveAt = .distantPast
        let old = idleTab("old.example", minutes: 90)
        let recent = idleTab("recent.example", minutes: 10)
        feature.tick()  // default: after 1h
        #expect(!old.isLoaded)
        #expect(recent.isLoaded)
        #expect(shown.isLoaded)
        #expect(old.url?.host() == "old.example")
        h.runtime.select(old.id, in: h.window)
        #expect(old.isLoaded)
    }

    @Test func busyOrHeldTabsStayAwake() {
        let music = idleTab("music.example", minutes: 300)
        h.fakeTab(music).simulateMedia(audio: true, video: false)
        let call = idleTab("call.example", minutes: 300)
        h.fakeTab(call).state.isCapturingMicrophone = true
        let held = idleTab("held.example", minutes: 300)
        h.runtime.holdAwake(held.id, reason: "test")
        #expect(feature.hibernate(idleFor: 0) == 0)
        #expect(music.isLoaded && call.isLoaded && held.isLoaded)
    }

    /// A tab with typed input isn't discarded until it navigates.
    @Test func editedTabsStayAwakeUntilTheyNavigate() {
        let form = idleTab("form.example", minutes: 300)
        h.fakeTab(form).simulateScriptMessage("hibernation.edited", body: [:])
        #expect(feature.hibernate(idleFor: 0) == 0)
        #expect(form.isLoaded)
        h.fakeTab(form).load(URL(string: "https://form.example/sent")!)
        feature.hibernate(idleFor: 0)
        #expect(!form.isLoaded)
    }

    @Test func settingsChooseWhen() {
        let tab = idleTab("a.example", minutes: 20)
        h.runtime.settings.set("hibernation.after", .string("never"))
        feature.tick()
        #expect(tab.isLoaded)
        h.runtime.settings.set("hibernation.after", .string("15m"))
        feature.tick()
        #expect(!tab.isLoaded)
    }

    @Test func memoryPressureFreesMoreAsItGetsWorse() {
        let idle = idleTab("idle.example", minutes: 6)
        let fresh = idleTab("fresh.example", minutes: 1)
        feature.memoryPressure(critical: false)
        #expect(!idle.isLoaded)
        #expect(fresh.isLoaded)
        feature.memoryPressure(critical: true)
        #expect(!fresh.isLoaded)

        let again = idleTab("again.example", minutes: 60)
        h.runtime.settings.set("hibernation.memoryPressure", false)
        feature.memoryPressure(critical: true)
        #expect(again.isLoaded)
    }

    @Test func commandHibernatesEveryBackgroundTab() throws {
        _ = idleTab("a.example", minutes: 0)
        _ = idleTab("b.example", minutes: 0)
        try h.run("hibernation.hibernate-background")
        #expect(h.notifications.last == "Hibernated 2 background tabs")
        try h.run("hibernation.hibernate-background")
        #expect(h.notifications.last == "No background tabs to hibernate")
    }
}
