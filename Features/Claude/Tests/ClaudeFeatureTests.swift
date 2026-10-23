import BrowserCore
import BrowserTesting
import Foundation
import Testing
@testable import FeatureClaude

@MainActor
struct ClaudeFeatureTests {
    func harness() throws -> TestHarness { try TestHarness(features: [ClaudeFeature.self], manifestDirectory: #filePath) }

    func claudeMarks(_ tab: BrowserTab, in h: TestHarness, mainFrame: Bool = true) {
        h.runtime.engine.hooks.dispatch(ClaudeFeature.message, from: h.fakeTab(tab),
                                        ScriptMessage(body: [String: Any](), isMainFrame: mainFrame, frameURL: tab.url))
    }

    /// A tab Claude acts on moves to the Claude space (made for it), and the window showing it follows.
    @Test func claudesTabsGatherInTheirSpace() throws {
        let h = try harness()
        let mine = h.openTab("https://a.example")
        let worked = h.openTab("https://b.example")
        claudeMarks(worked, in: h)
        let claude = try #require(h.runtime.tabs.space(kind: .claude))
        #expect(h.runtime.tabs.spaceID(of: worked.id) == claude.id)
        #expect(h.runtime.tabs.spaceID(of: mine.id) == h.runtime.tabs.normalSpace.id)
        #expect(h.window.spaceID == claude.id && h.selectedTab?.id == worked.id)
        claudeMarks(worked, in: h)  // marked again: stays put
        #expect(h.runtime.tabs.space(kind: .claude)?.today == [worked.id])
    }

    /// A session's tab (the extension opens Chrome's new-tab page in the background) is Claude's from the start; a page's
    /// background tab stays with its opener.
    @Test func claudesNewTabsStartInTheirSpace() throws {
        let h = try harness()
        let mine = h.openTab("https://a.example")
        let page = h.fakeTab(mine)
        page.simulateOpen(URL(string: "https://b.example")!, disposition: .backgroundTab)
        #expect(h.runtime.tabs.space(kind: .claude) == nil)
        page.simulateOpen(URL(string: "chrome://newtab/")!, disposition: .backgroundTab, userGesture: false)
        h.runtime.engine.hooks.onEngineOpenedPage?(h.engine.makeTab(EngineTabRequest(url: nil)), nil, .backgroundTab)
        let claude = try #require(h.runtime.tabs.space(kind: .claude))
        #expect(claude.today.count == 2)
        #expect(h.selectedTab?.id == mine.id && h.window.spaceID == h.runtime.tabs.normalSpace.id)
    }

    /// Private tabs stay private; marks from frames don't count; the setting turns it off.
    @Test func privateFramesAndTheSettingAreLeftAlone() throws {
        let h = try harness()
        let secret = h.runtime.openPrivateTab(URL(string: "https://secret.example")!, in: h.window)
        claudeMarks(secret, in: h)
        h.runtime.switchSpace(h.runtime.tabs.normalSpace.id, in: h.window)
        let page = h.openTab("https://a.example")
        claudeMarks(page, in: h, mainFrame: false)
        h.runtime.settings.set("claude.space", .bool(false))
        claudeMarks(page, in: h)
        #expect(h.runtime.tabs.space(kind: .claude) == nil)
    }
}
