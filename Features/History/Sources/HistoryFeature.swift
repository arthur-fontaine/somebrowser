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
                        subtitle: e.url.host(), icon: .favicon(e.url), kind: "History", score: 0.7 - Double(i) * 0.02) { w in
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

    var body: some View {
        if window.flags.contains(HistoryFeature.panelFlag) {
            ZStack {
                Color.black.opacity(0.12).contentShape(Rectangle()).onTapGesture { window.flags.remove(HistoryFeature.panelFlag) }
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("History").font(.title3.bold())
                        Spacer()
                        Button { window.flags.remove(HistoryFeature.panelFlag) } label: { Image(systemName: "xmark") }.buttonStyle(.borderless)
                    }
                    TextField("Search history", text: $query).textFieldStyle(.roundedBorder)
                    List(grouped(store.search(query, limit: 300)), id: \.0) { day, entries in
                        Section(day) {
                            ForEach(entries) { e in
                                HStack {
                                    Text(e.title.isEmpty ? e.url.absoluteString : e.title).lineLimit(1)
                                    Spacer()
                                    Text(e.url.host() ?? "").foregroundStyle(.secondary).lineLimit(1)
                                    Text(e.lastVisit, style: .time).foregroundStyle(.tertiary).monospacedDigit()
                                }
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    runtime.openTab(e.url, in: window)
                                    window.flags.remove(HistoryFeature.panelFlag)
                                }
                                .contextMenu { Button("Remove from History") { store.remove(url: e.url); query += "" } }
                            }
                        }
                    }
                    .listStyle(.inset)
                }
                .padding(20)
                .frame(width: 720, height: 520)
                .overlayKeyboardFocus("history", in: window)
                .glassSurface(in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .shadow(color: .black.opacity(0.25), radius: 24, y: 10)
            }
            .onKeyPress(.escape) { window.flags.remove(HistoryFeature.panelFlag); return .handled }
        }
    }

    private func grouped(_ entries: [HistoryEntry]) -> [(String, [HistoryEntry])] {
        let f = DateFormatter()
        f.dateStyle = .full
        f.doesRelativeDateFormatting = true
        var order: [String] = []
        var map: [String: [HistoryEntry]] = [:]
        for e in entries.sorted(by: { $0.lastVisit > $1.lastVisit }) {
            let key = f.string(from: e.lastVisit)
            if map[key] == nil { order.append(key) }
            map[key, default: []].append(e)
        }
        return order.map { ($0, map[$0]!) }
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
