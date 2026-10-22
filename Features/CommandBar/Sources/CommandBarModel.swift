import AppKit
import BrowserCore
import Observation

/// State and ranking for the command bar, independent of SwiftUI (unit-tested).
@Observable
final class CommandBarModel {
    enum Mode: Equatable {
        /// ⌘T: results open in a new tab (or fill the selected blank tab).
        case newTab
        /// ⌘L: results replace the current page.
        case editURL
    }

    /// Where it's drawn: in the sidebar's address field (grown from it), or as a centered palette (Arc's).
    enum Style: String {
        case inline, palette
    }

    struct Session {
        var mode: Mode
        /// What the field shows: what was typed, or the selected result's text (`OmniboxItem.fill`).
        var query: String
        /// What was typed: the results and suggestions are for this.
        var typed: String
        var selection = 0
        var suggestions: [String] = []
        var style: Style = .palette
        /// The text it opened with: Esc first reverts to it.
        var initialQuery = ""
    }

    @ObservationIgnored let runtime: BrowserRuntime
    private(set) var sessions: [UUID: Session] = [:]

    init(runtime: BrowserRuntime) { self.runtime = runtime }

    static let flag = "command-bar"
    static let maxItems = 9

    var search: SearchService? { runtime.capabilities.search }

    // MARK: Lifecycle

    /// The blank tab ⌘T opened for an inline session, closed again if the session switches to another tab instead.
    @ObservationIgnored var openedBlankTab: [UUID: NodeID] = [:]
    /// Windows whose floating sidebar the session showed (the sidebar was hidden), to put away on close.
    @ObservationIgnored var peeked: Set<UUID> = []

    func open(_ window: BrowserWindowState, mode: Mode, style: Style = .palette) {
        var query = ""
        if mode == .editURL, let tab = runtime.selectedTab(in: window) {
            let url = tab.live?.url ?? tab.url
            query = url.flatMap { search?.searchTerms(in: $0) } ?? url?.absoluteString ?? ""
        }
        sessions[window.id] = Session(mode: mode, query: query, typed: query, style: style, initialQuery: query)
        window.flags.insert(Self.flag)
    }

    func close(_ window: BrowserWindowState) {
        sessions[window.id] = nil
        window.flags.remove(Self.flag)
        if peeked.remove(window.id) != nil {
            // Put away unless the pointer is over it (then it hides as the pointer leaves, as a hover peek does).
            let frame = runtime.shell?.nsWindow(for: window)?.frame ?? .zero
            if !frame.contains(NSEvent.mouseLocation) || NSEvent.mouseLocation.x > frame.minX + window.sidebarWidth + 16 {
                window.isSidebarPeeking = false
            }
        }
    }

    /// Esc: back to what was typed from a selected result, then reverts what was typed, then closes (Chrome's).
    func escape(_ window: BrowserWindowState) {
        guard var s = sessions[window.id] else { return }
        if s.query != s.typed {
            s.query = s.typed
            s.selection = 0
            sessions[window.id] = s
        } else if s.query != s.initialQuery {
            s.query = s.initialQuery
            s.typed = s.initialQuery
            s.selection = 0
            sessions[window.id] = s
        } else {
            close(window)
        }
    }

    func session(_ window: BrowserWindowState) -> Session? { sessions[window.id] }

    func setQuery(_ q: String, in window: BrowserWindowState) {
        guard var s = sessions[window.id] else { return }
        s.query = q
        s.typed = q
        s.selection = 0
        s.suggestions = s.suggestions.filter { $0.lowercased().hasPrefix(q.lowercased()) }
        sessions[window.id] = s
    }

    func setSuggestions(_ list: [String], for query: String, in window: BrowserWindowState) {
        guard var s = sessions[window.id], s.typed == query else { return }
        s.suggestions = list
        sessions[window.id] = s
    }

    func moveSelection(_ delta: Int, in window: BrowserWindowState) {
        guard var s = sessions[window.id] else { return }
        let list = items(for: window)
        guard !list.isEmpty else { return }
        s.selection = (s.selection + delta + list.count) % list.count
        s.query = list[s.selection].fill ?? s.typed
        sessions[window.id] = s
    }

    // MARK: Results

    func items(for window: BrowserWindowState) -> [OmniboxItem] {
        guard let s = sessions[window.id] else { return [] }
        let q = s.typed.trimmingCharacters(in: .whitespacesAndNewlines)
        if q.isEmpty { return recentItems(window) }

        var items: [OmniboxItem] = []
        if let primary = primaryItem(q, mode: s.mode) { items.append(primary) }
        for (i, suggestion) in s.suggestions.enumerated() where suggestion.lowercased() != q.lowercased() {
            items.append(openItem(id: "suggest:\(suggestion)", title: suggestion, subtitle: nil, input: suggestion,
                                  icon: .system("magnifyingglass"), kind: "Search", score: 0.55 - Double(i) * 0.01, mode: s.mode,
                                  fill: suggestion))
        }
        items += tabItems(q, window: window)
        for provider in runtime.capabilities.all(OmniboxProvider.self) { items += provider.items(for: q, in: window) }
        if runtime.settings.bool("command-bar.showActions") { items += actionItems(q) }

        // Primary stays first; the rest by score, deduplicated by title+subtitle.
        let head = items.prefix(1)
        var seen = Set<String>()
        let rest = items.dropFirst().sorted { $0.score > $1.score }.filter { seen.insert("\($0.title)|\($0.subtitle ?? "")").inserted }
        return Array((head + rest).prefix(Self.maxItems))
    }

    private func primaryItem(_ q: String, mode: Mode) -> OmniboxItem? {
        guard let search else {
            guard let url = URL(string: q), url.scheme != nil else { return nil }
            return openItem(id: "open", title: q, subtitle: nil, input: q, icon: .system("globe"), kind: "Open", score: 2, mode: mode)
        }
        if search.looksLikeURL(q), let url = search.url(for: q) {
            return openItem(id: "open", title: url.absoluteString.replacingOccurrences(of: "https://", with: ""),
                            subtitle: "Open address", input: q, icon: .favicon(url), kind: "Open", score: 2, mode: mode)
        }
        return openItem(id: "search", title: q, subtitle: "Search \(search.engineName)", input: q,
                        icon: .system("magnifyingglass"), kind: "Search", score: 2, mode: mode)
    }

    private func openItem(id: String, title: String, subtitle: String?, input: String, icon: OmniboxItem.Icon, kind: String,
                          score: Double, mode: Mode, fill: String? = nil) -> OmniboxItem {
        OmniboxItem(id: id, title: title, subtitle: subtitle, icon: icon, kind: kind, score: score, fill: fill) { [weak self] window in
            guard let self, let url = self.search?.url(for: input) ?? URL(string: input) else { return }
            self.open(url, in: window, mode: mode)
        }
    }

    private func tabItems(_ q: String, window: BrowserWindowState) -> [OmniboxItem] {
        runtime.tabs.allTabs.compactMap { tab in
            guard tab.id != window.selectedTabID, tab.url != nil || tab.isLoaded else { return nil }
            let url = tab.live?.url ?? tab.url
            let score = max(FuzzyMatch.score(q, in: tab.displayTitle), FuzzyMatch.score(q, in: url?.host() ?? "") * 0.95)
            guard score > 0 else { return nil }
            return OmniboxItem(id: "tab:\(tab.id)", title: tab.displayTitle, subtitle: url?.host(), icon: .favicon(url),
                               kind: "Switch to Tab", score: score + 0.05, fill: url?.absoluteString) { [weak self] w in
                self?.runtime.select(tab.id, in: w)
            }
        }
    }

    private func actionItems(_ q: String) -> [OmniboxItem] {
        runtime.commands.paletteCommands.compactMap { d in
            guard d.id != "command-bar.open", d.id != "command-bar.edit-url" else { return nil }
            let score = ([d.title] + d.keywords).map { FuzzyMatch.score(q, in: $0) }.max() ?? 0
            guard score >= 0.6 || (score > 0 && q.count >= 3) else { return nil }
            return OmniboxItem(id: "cmd:\(d.id)", title: d.title, subtitle: nil, icon: .system("command"), kind: "Action",
                               score: score * 0.9, accessory: runtime.commands.shortcut(for: d.id)?.displayString) { [weak self] w in
                try? self?.runtime.commands.run(d.id, window: w)
            }
        }
    }

    /// Empty query: paste-and-go (a URL on the clipboard), then recent pages that aren't open (the sidebar lists those).
    private func recentItems(_ window: BrowserWindowState) -> [OmniboxItem] {
        var items: [OmniboxItem] = []
        let mode = sessions[window.id]?.mode ?? .newTab
        if let s = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
           s.count < 2048, search?.looksLikeURL(s) == true, let url = search?.url(for: s) {
            items.append(OmniboxItem(id: "paste", title: "Paste and Go", subtitle: url.absoluteString, icon: .system("doc.on.clipboard"),
                                     kind: "Open", score: 2, fill: url.absoluteString) { [weak self] w in self?.open(url, in: w, mode: mode) })
        }
        let open = Set(runtime.tabs.allTabs.compactMap { ($0.live?.url ?? $0.url).map(URLNormalizer.key(for:)) })
        for entry in runtime.capabilities.history?.recent(limit: 40) ?? [] where !open.contains(URLNormalizer.key(for: entry.url)) {
            items.append(OmniboxItem(id: "recent:\(entry.url.absoluteString)", title: entry.title.isEmpty ? entry.url.absoluteString : entry.title,
                                     subtitle: entry.url.host(), icon: .favicon(entry.url), kind: "History", score: 1,
                                     fill: entry.url.absoluteString) { [weak self] w in
                self?.open(entry.url, in: w, mode: mode)
            })
            if items.count >= 6 { break }
        }
        return items
    }

    // MARK: Execution

    /// Runs the selected result (`index`, else the selection); `inNewTab` (⌥↩) opens an address or search in a new tab.
    func execute(_ window: BrowserWindowState, index: Int? = nil, inNewTab: Bool = false) {
        if inNewTab, var s = sessions[window.id], s.mode != .newTab {
            s.mode = .newTab
            sessions[window.id] = s
        }
        let list = items(for: window)
        let i = index ?? sessions[window.id]?.selection ?? 0
        guard list.indices.contains(i) else { return }
        let item = list[i]
        let blank = openedBlankTab.removeValue(forKey: window.id)
        close(window)
        item.action(window)
        // ⌘T's blank tab, left untouched because the result switched to another tab.
        if let blank, window.selectedTabID != blank, let tab = runtime.tabs.tab(blank), tab.url == nil, !tab.isLoaded {
            runtime.close(blank)
        }
        runtime.shell?.focusContent(in: window)
    }

    func open(_ url: URL, in window: BrowserWindowState, mode: Mode) {
        if runtime.settings.bool("command-bar.switchToOpenTabs"),
           let existing = runtime.tabs.tabs(matching: url, in: window.spaceID).first(where: { $0.id != window.selectedTabID }) {
            runtime.select(existing.id, in: window)
            return
        }
        let current = runtime.selectedTab(in: window)
        if mode == .editURL, let current {
            runtime.navigate(current, to: url)
        } else if let current, current.url == nil, !current.isLoaded {
            runtime.navigate(current, to: url)  // fill the blank tab (⌘⌥T child, new window)
        } else {
            runtime.openTab(url, in: window)
        }
    }
}
