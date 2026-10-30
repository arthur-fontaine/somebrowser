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
    func searchURL(for input: String) -> URL? { URL(string: "https://search.example/?q=\(input.replacingOccurrences(of: " ", with: "+"))") }
    func suggestions(for query: String) async -> [String] { [] }
    func searchTerms(in url: URL) -> String? {
        url.host() == "search.example" ? URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first?.value : nil
    }
}

final class StubHistory: HistoryService {
    var entries: [HistoryEntry] = []
    func search(_ query: String, limit: Int) -> [HistoryEntry] { [] }
    func recent(limit: Int) -> [HistoryEntry] { entries }
    func remove(url: URL) {}
    func clear(since date: Date?) {}
    func importEntries(_ entries: [HistoryEntry]) {}
}

final class StubTopHits: OmniboxProvider {
    let sites: [TopHit.Site]
    init(_ entries: [HistoryEntry]) { sites = TopHit.sites(from: entries) }
    func items(for query: String, in window: BrowserWindowState) -> [OmniboxItem] {
        TopHit.best(query, in: sites).map { [.topHit($0.site.url, score: $0.score) { _, _ in }] } ?? []
    }
}

final class StubNewTabPage: NewTabPageProvider {
    var page: URL?
    func newTabPage(in window: BrowserWindowState) -> URL? { page }
}

final class StubProvider: OmniboxProvider {
    var calls = 0
    func items(for query: String, in window: BrowserWindowState) -> [OmniboxItem] {
        calls += 1
        return [OmniboxItem(id: "hist", title: "History hit", icon: .system("clock"), kind: "History", score: 0.7) { _ in }]
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

    /// What looks like an address may be a query: its search comes right under it (Chrome).
    @Test func anAddressCanBeSearchedToo() throws {
        let (h, model) = try harness()
        try h.run("command-bar.open")
        model.setQuery("node.js", in: h.window)
        let items = model.items(for: h.window)
        #expect(items.prefix(2).map(\.id) == ["open", "search"])
        #expect(items[1].title == "node.js" && items[1].subtitle == "Search Stub")
        model.execute(h.window, index: 1)
        #expect(h.selectedTab?.url?.absoluteString == "https://search.example/?q=node.js")
    }

    /// A past search is listed as one: the arrows fill the field with its terms, to be edited, not its results page's
    /// address. The same search twice (two pages of results) is listed once.
    @Test func pastSearchesFillTheirTerms() throws {
        let h = try TestHarness(features: [CommandBarFeature.self], manifestDirectory: #filePath, activate: false)
        h.runtime.capabilities.provide(SearchService.self, StubSearch())
        let history = StubHistory()
        history.entries = ["https://search.example/?q=cats", "https://search.example/?q=cats&page=2", "https://a.example/"].map {
            HistoryEntry(url: URL(string: $0)!, title: "Page", lastVisit: Date(), visitCount: 1)
        }
        h.runtime.capabilities.provide(HistoryService.self, history)
        h.activate()
        let model = try #require(h.runtime.feature(CommandBarFeature.self)?.model)
        model.clipboard = { (nil, 0) }  // an address copied would add Paste and Go first
        try h.run("command-bar.open")
        let items = model.items(for: h.window)
        #expect(items.map(\.title) == ["cats", "Page"])
        #expect(items[0].kind == "History" && items[0].fill == "cats")
        model.moveSelection(1, in: h.window)
        model.moveSelection(-1, in: h.window)
        #expect(model.session(h.window)?.query == "cats")
    }

    @Test func typingWordsSearches() throws {
        let (h, model) = try harness()
        try h.run("command-bar.open")
        model.setQuery("swift ui", in: h.window)
        #expect(model.items(for: h.window).first?.kind == "Search")
        model.execute(h.window)
        #expect(h.selectedTab?.url?.host() == "search.example")
    }

    @Test func aSiteItSurelyNamesGoesBeforeTheSearch() throws {
        let (h, model) = try harness()
        h.runtime.capabilities.contribute(OmniboxProvider.self, StubTopHits([
            HistoryEntry(url: URL(string: "https://x.com/home")!, title: "Home / X", lastVisit: Date(), visitCount: 20),
        ]))
        try h.run("command-bar.open")
        model.setQuery("x", in: h.window)
        #expect(model.items(for: h.window).map(\.kind).prefix(2) == ["Top Hit", "Search"])
        model.setQuery("gmail", in: h.window)  // no history: a known brand
        #expect(model.items(for: h.window).first?.title == "mail.google.com")
        model.execute(h.window)
        #expect(h.selectedTab?.url?.host() == "mail.google.com")
        try h.run("command-bar.open")
        model.setQuery("x.com", in: h.window)  // an address typed stays first
        #expect(model.items(for: h.window).first?.kind == "Open")
        model.setQuery("swift ui", in: h.window)
        #expect(model.items(for: h.window).first?.kind == "Search")
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

    /// On a results page the address is edited as what was searched (Chrome's).
    @Test func editURLOnAResultsPageEditsTheSearchTerms() throws {
        let (h, model) = try harness()
        h.openTab("https://search.example/?q=cats")
        try h.run("command-bar.edit-url")
        #expect(model.session(h.window)?.query == "cats")
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

    /// A window without a sidebar has no address to edit, and a new tab's is typed in the palette (no floating sidebar).
    @Test func windowsWithoutASidebarDontEditTheAddress() throws {
        let (h, model) = try harness()
        h.openTab("https://a.example/")
        h.window.isSidebarVisible = false
        h.window.allowsSidebar = false
        #expect(!h.runtime.commands.canRun("command-bar.edit-url", in: h.window))
        #expect(throws: CommandError.self) { try h.run("command-bar.edit-url") }
        #expect(model.session(h.window) == nil)
        try h.run("command-bar.open")
        #expect(model.session(h.window)?.style == .palette)
        #expect(!h.window.isSidebarPeeking)
    }

    /// Claude's tabs are Claude's to drive: their address can't be edited.
    @Test func claudesSpaceDoesntEditTheAddress() throws {
        let (h, model) = try harness()
        let tab = h.openTab("https://a.example/")
        try h.runtime.tabs.move(tab.id, to: .section(h.runtime.tabs.ensureSpace(.claude).id, .today), at: 0)
        h.runtime.select(tab.id, in: h.window)
        #expect(!h.runtime.commands.canRun("command-bar.edit-url", in: h.window))
        #expect(throws: CommandError.self) { try h.run("command-bar.edit-url") }
        #expect(model.session(h.window) == nil)
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
        model.setQuery("a.example", in: h.window)  // open tabs are offered once typing matches them
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

    /// Chrome's: an arrowed-to suggestion fills the field and typing goes on from it; Esc goes back to what was typed.
    @Test func arrowsFillTheFieldAndTypingGoesOnFromIt() throws {
        let (h, model) = try harness()
        try h.run("command-bar.open")
        model.setQuery("hel", in: h.window)
        model.setSuggestions(["hello", "help"], for: "hel", in: h.window)
        let results = model.items(for: h.window).map(\.id)
        model.moveSelection(1, in: h.window)
        #expect(model.session(h.window)?.query == "hello")
        #expect(model.items(for: h.window).map(\.id) == results)  // the list stays for what was typed
        model.moveSelection(1, in: h.window)
        #expect(model.session(h.window)?.query == "help")
        model.moveSelection(-2, in: h.window)
        #expect(model.session(h.window)?.query == "hel")

        model.moveSelection(1, in: h.window)
        model.escape(h.window)
        #expect(model.session(h.window)?.query == "hel")
        #expect(model.session(h.window)?.selection == 0)

        model.moveSelection(1, in: h.window)
        model.setQuery("hello world", in: h.window)  // what the field sends as " world" is typed after the fill
        model.execute(h.window)
        #expect(h.selectedTab?.url?.absoluteString == "https://search.example/?q=hello+world")
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

    /// The views ask for the results on every redraw; providers (history over a large profile) run once per change.
    @Test func resultsAreRankedOncePerQuery() throws {
        let h = try TestHarness(features: [CommandBarFeature.self], manifestDirectory: #filePath, activate: false)
        h.runtime.capabilities.provide(SearchService.self, StubSearch())
        let provider = StubProvider()
        h.runtime.capabilities.contribute(OmniboxProvider.self, provider)
        h.activate()
        let model = try #require(h.runtime.feature(CommandBarFeature.self)?.model)
        h.openTab("https://claude.example/new")
        try h.run("command-bar.edit-url")
        _ = model.items(for: h.window)
        _ = model.items(for: h.window)
        #expect(provider.calls == 1)
        model.setQuery("claude", in: h.window)
        _ = model.items(for: h.window)
        #expect(provider.calls == 2)
        try h.run("command-bar.edit-url")
        try h.run("command-bar.edit-url")
        _ = model.items(for: h.window)
        #expect(provider.calls == 3)  // a new session ranks afresh
    }
}
