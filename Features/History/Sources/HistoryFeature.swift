import AppKit
import BrowserCore
import SwiftUI

public final class HistoryFeature: BrowserFeature {
    let context: FeatureContext
    lazy var store = HistoryStore(path: context.dataDirectory.appendingPathComponent("history.sqlite").path)
    static let panelFlag = "history.panel"

    public init(context: FeatureContext) { self.context = context }

    public func activate() {
        context.capabilities.provide(HistoryService.self, store)
        context.capabilities.contribute(OmniboxProvider.self, HistoryOmnibox(feature: self))
        context.events.subscribe(TabNavigated.self) { [weak self] e in
            guard let self, !e.isPrivate, self.context.settings.bool("history.enabled") else { return }
            self.store.record(url: e.url, title: self.context.tabs.tab(e.tabID)?.live?.title)
        }
        context.events.subscribe(TabFinishedLoading.self) { [weak self] e in
            guard let self, let tab = self.context.tabs.tab(e.tabID), !tab.isPrivate, let live = tab.live, let url = live.url else { return }
            self.store.updateTitle(url: url, title: live.title)
        }
        context.commands.handle("history.show") { inv in inv.window?.toggle(flag: Self.panelFlag) }
        context.commands.handle("history.clear-today") { [weak self] inv in
            self?.store.clear(since: Calendar.current.startOfDay(for: Date()))
            self?.context.notify("Cleared today's history", systemImage: "clock.arrow.circlepath", window: inv.window)
        }
        context.commands.handle("history.clear-all") { [weak self] inv in
            self?.store.clear(since: nil)
            self?.context.notify("Cleared all history", systemImage: "clock.arrow.circlepath", window: inv.window)
        }
        let store = self.store
        let runtime = context.runtime
        context.ui.contribute(.overlay, id: "history.panel", order: 70) { window in
            HistoryPanelOverlay(window: window, store: store, runtime: runtime)
        }
        context.ui.contribute("sidebar.footer", id: "history.button", order: 10) { window in
            ChromeButton(systemImage: "clock", help: "History (⌘Y)") { window.toggle(flag: Self.panelFlag) }
        }
        context.ui.contribute("start-page.extras", id: "history.frequent", order: 1) { window in
            FrequentSites(window: window, store: store, runtime: runtime)
        }
        // Retention runs off the launch path.
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in
            guard let self else { return }
            self.store.prune(olderThan: max(1, self.context.settings.int("history.retentionDays")))
        }
    }
}

final class HistoryOmnibox: OmniboxProvider {
    weak var feature: HistoryFeature?
    init(feature: HistoryFeature) { self.feature = feature }

    func items(for query: String, in window: BrowserWindowState) -> [OmniboxItem] {
        guard let feature, query.count >= 2 else { return [] }
        let runtime = feature.context.runtime
        return feature.store.search(query, limit: 5).enumerated().map { i, e in
            OmniboxItem(id: "history:\(e.url.absoluteString)", title: e.title.isEmpty ? e.url.absoluteString : e.title,
                        subtitle: e.url.host(), icon: .favicon(e.url), kind: "History", score: 0.7 - Double(i) * 0.02,
                        fill: e.url.absoluteString) { w in
                runtime.open(e.url, fillingBlankTabIn: w)
            }
        }
    }
}

struct HistoryPanelOverlay: View {
    let window: BrowserWindowState
    let store: HistoryStore
    let runtime: BrowserRuntime
    @State private var query = ""
    /// The store isn't observed (SQLite): a removal or a clear bumps this to list again.
    @State private var revision = 0

    var body: some View {
        let shown = window.flags.contains(HistoryFeature.panelFlag)
        let _ = revision
        ListPopover("history", in: window, isShown: shown, title: "History", query: $query,
                    sections: shown ? sections() : [],
                    empty: PanelEmptyState(symbol: "clock", title: "No History",
                                           detail: window.isPrivate ? "Private windows don't keep history." : "The pages you visit show up here."),
                    close: { window.flags.remove(HistoryFeature.panelFlag) }) {
            Button("Clear Today's History") { clear(since: Calendar.current.startOfDay(for: Date())) }
            Button("Clear All History") { clear(since: nil) }
        }
        .onChange(of: shown) { if !shown { query = "" } }
    }

    private func sections() -> [PanelSection] {
        PanelSection.byDay(store.search(query, limit: 300), date: \.lastVisit) { e in
            PanelItem(id: e.url.absoluteString, icon: runtime.favicons.image(for: e.url),
                      title: e.title.isEmpty ? e.url.absoluteString : e.title, subtitle: Self.address(e.url),
                      detail: e.lastVisit.formatted(date: .omitted, time: .shortened), url: e.url,
                      open: { runtime.openTab(e.url, in: window) },
                      remove: ("Remove from History", { store.remove(url: e.url); revision += 1 }))
        }
    }

    private func clear(since date: Date?) {
        store.clear(since: date)
        revision += 1
    }

    /// The address without its scheme or "www.", as Safari's history lists it.
    static func address(_ url: URL) -> String {
        var s = url.absoluteString
        for prefix in ["https://", "http://"] where s.hasPrefix(prefix) { s.removeFirst(prefix.count) }
        if s.hasPrefix("www.") { s.removeFirst(4) }
        return s.hasSuffix("/") && s.filter({ $0 == "/" }).count == 1 ? String(s.dropLast()) : s
    }
}

/// The start page's "Frequently Visited": the sites visited most, favorites aside (they have their own section).
struct FrequentSites: View {
    let window: BrowserWindowState
    let store: HistoryStore
    let runtime: BrowserRuntime

    var body: some View {
        let favorites = Set(runtime.tabs.favorites.compactMap { runtime.tabs.tab($0).flatMap { ($0.pinnedURL ?? $0.url).flatMap(HistoryStore.site) } })
        let sites = window.isPrivate ? [] : store.frequentSites(limit: 14, excluding: favorites)
        if !sites.isEmpty {
            PageSection("Frequently Visited") {
                LazyVGrid(columns: SiteTile.columns, alignment: .leading, spacing: 16) {
                    ForEach(sites, id: \.url) { page in
                        SiteTile(icon: runtime.favicons.image(for: page.url), title: SiteTile.name(for: page.url) ?? page.title,
                                 help: page.title.isEmpty ? page.url.absoluteString : page.title) {
                            runtime.open(page.url, fillingBlankTabIn: window)
                        }
                    }
                }
            }
        }
    }
}
