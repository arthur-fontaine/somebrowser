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

    struct Session {
        var mode: Mode
        var query: String
        var selection = 0
        var suggestions: [String] = []
    }

    @ObservationIgnored let runtime: BrowserRuntime
    private(set) var sessions: [UUID: Session] = [:]

    init(runtime: BrowserRuntime) { self.runtime = runtime }

    static let flag = "command-bar"
    static let maxItems = 9

    var search: SearchService? { runtime.capabilities.search }

    // MARK: Lifecycle

    func open(_ window: BrowserWindowState, mode: Mode) {
        var query = ""
        if mode == .editURL, let tab = runtime.selectedTab(in: window) {
            query = (tab.live?.url ?? tab.url)?.absoluteString ?? ""
        }
        sessions[window.id] = Session(mode: mode, query: query)
        window.flags.insert(Self.flag)
    }

    func close(_ window: BrowserWindowState) {
        sessions[window.id] = nil
        window.flags.remove(Self.flag)
    }

    func session(_ window: BrowserWindowState) -> Session? { sessions[window.id] }

    func setQuery(_ q: String, in window: BrowserWindowState) {
        guard var s = sessions[window.id] else { return }
        s.query = q
        s.selection = 0
        s.suggestions = s.suggestions.filter { $0.lowercased().hasPrefix(q.lowercased()) }
        sessions[window.id] = s
    }

    func setSuggestions(_ list: [String], for query: String, in window: BrowserWindowState) {
        guard var s = sessions[window.id], s.query == query else { return }
        s.suggestions = list
        sessions[window.id] = s
    }

    func moveSelection(_ delta: Int, in window: BrowserWindowState) {
        guard var s = sessions[window.id] else { return }
        let count = items(for: window).count
        guard count > 0 else { return }
        s.selection = (s.selection + delta + count) % count
        sessions[window.id] = s
    }

    // MARK: Results

    func items(for window: BrowserWindowState) -> [OmniboxItem] {
        guard let s = sessions[window.id] else { return [] }
        let q = s.query.trimmingCharacters(in: .whitespacesAndNewlines)
        if q.isEmpty { return recentItems(window) }

        var items: [OmniboxItem] = []
        if let primary = primaryItem(q, mode: s.mode) { items.append(primary) }
        for (i, suggestion) in s.suggestions.enumerated() where suggestion.lowercased() != q.lowercased() {
            items.append(openItem(id: "suggest:\(suggestion)", title: suggestion, subtitle: nil, input: suggestion,
                                  icon: .system("magnifyingglass"), kind: "Search", score: 0.55 - Double(i) * 0.01, mode: s.mode))
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
                          score: Double, mode: Mode) -> OmniboxItem {
        OmniboxItem(id: id, title: title, subtitle: subtitle, icon: icon, kind: kind, score: score) { [weak self] window in
            guard let self, let url = self.search?.url(for: input) ?? URL(string: input) else { return }
            self.open(url, in: window, mode: mode)
        }
    }

    private func tabItems(_ q: String, window: BrowserWindowState) -> [OmniboxItem] {
        runtime.tabs.allTabs.compactMap { tab in
            guard tab.id != window.selectedTabID else { return nil }
            let url = tab.live?.url ?? tab.url
            let score = max(FuzzyMatch.score(q, in: tab.displayTitle), FuzzyMatch.score(q, in: url?.host() ?? "") * 0.95)
            guard score > 0 else { return nil }
            return OmniboxItem(id: "tab:\(tab.id)", title: tab.displayTitle, subtitle: url?.host(), icon: .favicon(url),
                               kind: "Switch to Tab", score: score + 0.05) { [weak self] w in
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

    /// Empty query: paste-and-go, then recently used tabs (Arc).
    private func recentItems(_ window: BrowserWindowState) -> [OmniboxItem] {
        var items: [OmniboxItem] = []
        if let s = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
           s.count < 2048, search?.looksLikeURL(s) == true, let url = search?.url(for: s) {
            let mode = sessions[window.id]?.mode ?? .newTab
            items.append(OmniboxItem(id: "paste", title: "Paste and Go", subtitle: url.absoluteString, icon: .system("doc.on.clipboard"),
                                     kind: "Open", score: 2) { [weak self] w in self?.open(url, in: w, mode: mode) })
        }
        for id in window.mru where id != window.selectedTabID {
            guard let tab = runtime.tabs.tab(id) else { continue }
            let url = tab.live?.url ?? tab.url
            items.append(OmniboxItem(id: "tab:\(id)", title: tab.displayTitle, subtitle: url?.host(), icon: .favicon(url),
                                     kind: "Switch to Tab", score: 1) { [weak self] w in self?.runtime.select(id, in: w) })
            if items.count >= 6 { break }
        }
        return items
    }

    // MARK: Execution

    func execute(_ window: BrowserWindowState, index: Int? = nil) {
        let list = items(for: window)
        let i = index ?? sessions[window.id]?.selection ?? 0
        guard list.indices.contains(i) else { return }
        let item = list[i]
        close(window)
        item.action(window)
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
