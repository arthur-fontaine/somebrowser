import AppKit
import BrowserTesting
import Foundation
import Testing
@testable import BrowserCore

final class ProbeFeature: BrowserFeature {
    static var activated: [String] = []
    let context: FeatureContext
    init(context: FeatureContext) { self.context = context }
    func activate() {
        Self.activated.append(context.featureID)
        if context.manifest.commands.contains(where: { $0.id == "probe.ping" }) {
            context.commands.handle("probe.ping") { _ in self.context.notify("pong") }
        }
    }
}

@MainActor
struct RuntimeTests {
    func harness() throws -> TestHarness {
        let manifest = FeatureManifest(
            id: "probe", name: "Probe",
            commands: [CommandDescriptor(id: "probe.ping", title: "Ping", shortcut: "cmd+shift+p")],
            settings: [SettingDescriptor(key: "probe.flag", title: "Flag", kind: .bool, defaultValue: .bool(true))]
        )
        return try TestHarness(registrations: [FeatureRegistration(manifest: manifest) { ProbeFeature(context: $0) }],
                               settingOverrides: ["probe.flag": .bool(false)])
    }

    @Test func featuresActivateAndCommandsRun() throws {
        let h = try harness()
        #expect(h.runtime.activationOrder == ["probe"])
        #expect(h.runtime.commands.shortcut(for: "probe.ping") == KeyShortcut("cmd+shift+p"))
        try h.run("probe.ping")
        #expect(h.notifications == ["pong"])
        #expect(h.runtime.commands.recent.first == "probe.ping")
    }

    @Test func forkSettingOverridesBecomeDefaults() throws {
        let h = try harness()
        #expect(h.runtime.settings.bool("probe.flag") == false)
        h.runtime.settings.set("probe.flag", true)
        #expect(h.runtime.settings.bool("probe.flag"))
        h.runtime.settings.reset("probe.flag")
        #expect(h.runtime.settings.bool("probe.flag") == false)
    }

    @Test func unknownCommandsThrow() throws {
        let h = try harness()
        #expect(throws: CommandError.self) { try h.run("nope.nothing") }
    }

    @Test func openingSelectsAndPresents() throws {
        let h = try harness()
        let t = h.openTab("https://a.example")
        #expect(h.selectedTab?.id == t.id)
        #expect(h.viewport.presentedTab === t.engineTab)
        #expect(t.engineTab?.state.url?.host() == "a.example")
    }

    @Test func pagePopupsBecomeChildrenAndForegroundOnesAreSelected() throws {
        let h = try harness()
        let parent = h.openTab("https://a.example")
        let child = h.fakeTab(parent).simulateOpen(URL(string: "https://b.example")!)
        let childTab = h.runtime.tabs.allTabs.first { $0.engineTab === child }!
        #expect(h.runtime.tabs.parent(of: childTab.id) == parent.id)
        #expect(h.selectedTab?.id == childTab.id)
        h.fakeTab(parent).simulateOpen(URL(string: "https://c.example")!, disposition: .backgroundTab)
        #expect(h.selectedTab?.id == childTab.id)
        #expect(h.runtime.tabs.children(of: parent.id).count == 2)
    }

    @Test func openLinksInPlaceMakesSiblings() throws {
        let h = try harness()
        let parent = h.openTab("https://a.example")
        parent.opensLinksInPlace = true
        h.fakeTab(parent).simulateOpen(URL(string: "https://b.example")!)
        #expect(h.runtime.tabs.children(of: parent.id).isEmpty)
    }

    @Test func closingReturnsToPreviousTab() throws {
        let h = try harness()
        let a = h.openTab("https://a.example")
        _ = h.openTab("https://b.example")
        let c = h.openTab("https://c.example")
        h.runtime.select(a.id, in: h.window)
        h.runtime.select(c.id, in: h.window)
        h.runtime.close(c.id)
        #expect(h.selectedTab?.id == a.id)
        #expect((c.engineTab as? FakeEngineTab) == nil)
    }

    @Test func closedEnginePagesAreReleased() throws {
        let h = try harness()
        let a = h.openTab("https://a.example")
        let page = h.fakeTab(a)
        h.runtime.close(a.id)
        #expect(page.isClosed)
        #expect(h.viewport.presentedTab == nil)
    }

    @Test func discardKeepsStateAndWakesOnSelect() throws {
        let h = try harness()
        let a = h.openTab("https://a.example")
        let b = h.openTab("https://b.example")
        h.runtime.discard(a)
        #expect(!a.isLoaded)
        #expect(a.url?.host() == "a.example")
        h.runtime.discard(b)  // selected: refused
        #expect(b.isLoaded)
        h.runtime.select(a.id, in: h.window)
        #expect(a.isLoaded)
    }

    @Test func heldTabsStayAwakeAndIdleCountsFromLeaving() throws {
        let h = try harness()
        let a = h.openTab("https://a.example")
        let selectedAt = a.lastActiveAt
        _ = h.openTab("https://b.example")
        #expect(a.lastActiveAt > selectedAt)  // stamped when left, not only when selected
        h.runtime.holdAwake(a.id, reason: "pip")
        h.runtime.holdAwake(a.id, reason: "other")
        h.runtime.discard(a)
        #expect(a.isLoaded)
        h.runtime.releaseAwake(a.id, reason: "pip")
        h.runtime.discard(a)
        #expect(a.isLoaded)
        h.runtime.releaseAwake(a.id, reason: "other")
        #expect(!h.runtime.isHeldAwake(a.id))
        h.runtime.discard(a)
        #expect(!a.isLoaded)
    }

    @Test func spacesSwitchSelection() throws {
        let h = try harness()
        let first = h.openTab("https://a.example")
        let work = h.runtime.tabs.addSpace(name: "Work")
        let events = h.record(SpaceSwitched.self)
        h.runtime.switchSpace(work.id, in: h.window)
        #expect(h.selectedTab == nil)
        #expect(events.last?.direction == 1)
        h.runtime.switchSpace(h.runtime.tabs.spaces[0].id, in: h.window)
        #expect(h.selectedTab?.id == first.id)
    }

    @Test func requestFiltersRunInOrder() throws {
        let h = try harness()
        h.engine.hooks.addRequestFilter { $0.url.host() == "ads.example" ? .block : .allow }
        #expect(h.engine.simulateRequest(URL(string: "https://ads.example/x.js")!) == .block)
        #expect(h.engine.simulateRequest(URL(string: "https://ok.example/x.js")!) == .allow)
    }
}

struct KeyShortcutTests {
    @Test func parsesAndDisplays() {
        let s = KeyShortcut("cmd+shift+t")!
        #expect(s.modifiers == [.command, .shift])
        #expect(s.displayString == "⇧⌘T")
        #expect(KeyShortcut("ctrl+tab")?.displayString == "⌃⇥")
        #expect(KeyShortcut("cmd+opt+left")?.keyEquivalent == String(Character(UnicodeScalar(NSLeftArrowFunctionKey)!)))
        #expect(KeyShortcut("hyper+t") == nil)
        #expect(KeyShortcut("cmd++")?.key == "+")
    }
}
