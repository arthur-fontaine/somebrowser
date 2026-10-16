import BrowserCore
import BrowserTesting
import Foundation
import Testing
@testable import FeatureCommandBar

/// Minimal stand-in for the search feature (tests never import other features).
final class StubSearch: SearchService {
    var engineName = "Stub"
    func looksLikeURL(_ input: String) -> Bool { input.contains(".") && !input.contains(" ") }
    func url(for input: String) -> URL? {
        looksLikeURL(input) ? URL(string: "https://\(input)") : URL(string: "https://search.example/?q=\(input.replacingOccurrences(of: " ", with: "+"))")
    }
    func suggestions(for query: String) async -> [String] { [] }
}

final class StubNewTabPage: NewTabPageProvider {
    var page: URL?
    func newTabPage(in window: BrowserWindowState) -> URL? { page }
}

final class StubProvider: OmniboxProvider {
    func items(for query: String, in window: BrowserWindowState) -> [OmniboxItem] {
        [OmniboxItem(id: "hist", title: "History hit", icon: .system("clock"), kind: "History", score: 0.7) { _ in }]
    }
}

@MainActor
struct CommandBarTests {
    func harness() throws -> (TestHarness, CommandBarModel) {
        let h = try TestHarness(features: [CommandBarFeature.self], manifestDirectory: #filePath, activate: false)
        h.runtime.capabilities.provide(SearchService.self, StubSearch())
        h.activate()
        let model = try #require(h.runtime.feature(CommandBarFeature.self)?.model)
        return (h, model)
    }

    @Test func openAndCloseWithTheSameShortcut() throws {
        let (h, model) = try harness()
        try h.run("command-bar.open")
        #expect(h.window.flags.contains(CommandBarModel.flag))
        #expect(model.session(h.window)?.mode == .newTab)
        try h.run("command-bar.open")
        #expect(!h.window.flags.contains(CommandBarModel.flag))
    }

    /// An extension's new tab page replaces the command bar for new tabs, as in Chrome.
    @Test func newTabsOpenOnAReplacementNewTabPage() throws {
        let h = try TestHarness(features: [CommandBarFeature.self], manifestDirectory: #filePath, activate: false)
        let stub = StubNewTabPage()
        h.runtime.capabilities.provide(NewTabPageProvider.self, stub)
        h.activate()
        stub.page = URL(string: "chrome-extension://abc/tab.html")
        try h.run("command-bar.open")
        #expect(h.selectedTab?.url == stub.page)
        #expect(!h.window.flags.contains(CommandBarModel.flag))
        stub.page = nil
        try h.run("command-bar.open")
        #expect(h.window.flags.contains(CommandBarModel.flag))
    }

    @Test func typingAURLOpensANewTab() throws {
        let (h, model) = try harness()
        try h.run("command-bar.open")
        model.setQuery("example.com", in: h.window)
        #expect(model.items(for: h.window).first?.kind == "Open")
        model.execute(h.window)
        #expect(h.selectedTab?.url?.absoluteString == "https://example.com")
        #expect(!h.window.flags.contains(CommandBarModel.flag))
    }

    @Test func typingWordsSearches() throws {
        let (h, model) = try harness()
        try h.run("command-bar.open")
        model.setQuery("swift ui", in: h.window)
        #expect(model.items(for: h.window).first?.kind == "Search")
        model.execute(h.window)
        #expect(h.selectedTab?.url?.host() == "search.example")
    }

    @Test func editURLNavigatesTheCurrentTab() throws {
        let (h, model) = try harness()
        let tab = h.openTab("https://a.example")
        try h.run("command-bar.edit-url")
        #expect(model.session(h.window)?.query == "https://a.example")
        model.setQuery("b.example", in: h.window)
        model.execute(h.window)
        #expect(h.runtime.tabs.tabCount == 1)
        #expect(tab.url?.host() == "b.example")
    }

    @Test func openTabsRankAsSwitchTargets() throws {
        let (h, model) = try harness()
        let docs = h.openTab("https://docs.example")
        h.fakeTab(docs).simulateTitle("Swift Documentation")
        h.openTab("https://other.example")
        try h.run("command-bar.open")
        model.setQuery("swift doc", in: h.window)
        let switchItem = model.items(for: h.window).first { $0.kind == "Switch to Tab" }
        #expect(switchItem?.title == "Swift Documentation")
        model.execute(h.window, index: model.items(for: h.window).firstIndex { $0.kind == "Switch to Tab" })
        #expect(h.selectedTab?.id == docs.id)
    }

    @Test func providersAndActionsAreListed() throws {
        let (h, model) = try harness()
        h.runtime.capabilities.contribute(OmniboxProvider.self, StubProvider())
        try h.run("command-bar.open")
        model.setQuery("paste", in: h.window)
        let kinds = Set(model.items(for: h.window).map(\.kind))
        #expect(kinds.contains("History"))
        #expect(kinds.contains("Action"))  // "Paste and Go"
    }

    @Test func blankTabIsFilledInsteadOfOpeningAnother() throws {
        let (h, model) = try harness()
        h.runtime.openTab(nil, in: h.window)
        model.open(URL(string: "https://x.example")!, in: h.window, mode: .newTab)
        #expect(h.runtime.tabs.tabCount == 1)
        #expect(h.selectedTab?.url?.host() == "x.example")
    }

    @Test func existingTabIsReused() throws {
        let (h, model) = try harness()
        let a = h.openTab("https://a.example")
        h.openTab("https://b.example")
        model.open(URL(string: "https://a.example")!, in: h.window, mode: .newTab)
        #expect(h.selectedTab?.id == a.id)
        #expect(h.runtime.tabs.tabCount == 2)
    }

    @Test func selectionWraps() throws {
        let (h, model) = try harness()
        try h.run("command-bar.open")
        model.setQuery("example.com", in: h.window)
        let count = model.items(for: h.window).count
        model.moveSelection(-1, in: h.window)
        #expect(model.session(h.window)?.selection == count - 1)
    }

    /// Inline (the default): ⌘T opens the new tab, then its address is typed in the sidebar's field.
    @Test func newTabOpensFirstThenItsAddressIsTyped() throws {
        let (h, model) = try harness()
        h.openTab("https://a.example/")
        let before = h.runtime.tabs.allTabs.count
        try h.run("command-bar.open")
        #expect(h.runtime.tabs.allTabs.count == before + 1)
        #expect(h.selectedTab?.url == nil)
        #expect(model.session(h.window)?.style == .inline)
        model.setQuery("example.com", in: h.window)
        model.execute(h.window)
        #expect(h.selectedTab?.url?.absoluteString == "https://example.com")
        #expect(h.runtime.tabs.allTabs.count == before + 1)  // the new tab was filled
    }

    /// Switching to an open tab from ⌘T leaves no untouched blank tab behind.
    @Test func switchingFromANewTabClosesIt() throws {
        let (h, model) = try harness()
        let a = h.openTab("https://a.example/")
        h.openTab("https://b.example/")
        let before = h.runtime.tabs.allTabs.count
        try h.run("command-bar.open")
        let i = try #require(model.items(for: h.window).firstIndex { $0.id == "tab:\(a.id)" })
        model.execute(h.window, index: i)
        #expect(h.window.selectedTabID == a.id)
        #expect(h.runtime.tabs.allTabs.count == before)
    }

    /// Esc first reverts what was typed, then closes; ⌥↩ opens in a new tab even while editing the address.
    @Test func escapeRevertsThenClosesAndOptionReturnOpensANewTab() throws {
        let (h, model) = try harness()
        h.openTab("https://a.example/")
        try h.run("command-bar.edit-url")
        let initial = model.session(h.window)?.query
        model.setQuery("b.example", in: h.window)
        model.escape(h.window)
        #expect(model.session(h.window)?.query == initial)
        model.escape(h.window)
        #expect(model.session(h.window) == nil)

        try h.run("command-bar.edit-url")
        model.setQuery("c.example", in: h.window)
        let before = h.runtime.tabs.allTabs.count
        model.execute(h.window, inNewTab: true)
        #expect(h.runtime.tabs.allTabs.count == before + 1)
        #expect(h.selectedTab?.url?.absoluteString == "https://c.example")
    }

    /// The palette style keeps Arc's: ⌘T opens nothing until something is chosen.
    @Test func paletteStyleOpensNoTabFirst() throws {
        let (h, model) = try harness()
        h.runtime.settings.set("command-bar.style", .string("palette"))
        let before = h.runtime.tabs.allTabs.count
        try h.run("command-bar.open")
        #expect(h.runtime.tabs.allTabs.count == before)
        #expect(model.session(h.window)?.style == .palette)
    }
}

