import BrowserCore
import SwiftUI

/// The Settings window's pages, built from the manifests: each feature's settings go on the page its `settingsPage`
/// names, as a section titled after the feature (or the setting's own `section`, which several features can share).
struct SettingsPageModel: Identifiable {
    enum Content { case settings, keyboard, features, pane(SettingsPane) }

    struct Section: Identifiable {
        var id: String { title }
        var title: String
        var order: Int
        var settings: [SettingDescriptor]
    }

    var id: String
    var title: String
    var systemImage: String
    var sections: [Section] = []
    var content: Content = .settings

    /// Pages known by name get their place and icon; a page only a fork's feature names comes after them.
    static let known: [(title: String, systemImage: String)] = [
        ("General", "switch.2"),
        ("Appearance", "paintbrush"),
        ("Tabs", "square.on.square"),
        ("Search", "magnifyingglass"),
        ("Privacy & Security", "hand.raised"),
        ("Integrations", "link"),
        ("Keyboard", "keyboard"),
    ]

    static func id(of title: String) -> String {
        title.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).joined(separator: "-")
    }

    /// The pages in sidebar order (the second list is the window's "Advanced" group).
    static func build(manifests: [FeatureManifest], panes: [SettingsPane]) -> (main: [SettingsPageModel], advanced: [SettingsPageModel]) {
        var pages: [String: SettingsPageModel] = [:]
        for m in manifests where !m.settings.isEmpty {
            let title = m.settingsPage ?? "General"
            let known = Self.known.first { $0.title == title }
            var page = pages[title] ?? SettingsPageModel(id: id(of: title), title: title, systemImage: known?.systemImage ?? "puzzlepiece")
            for d in m.settings {
                let section = d.section ?? m.name
                if let i = page.sections.firstIndex(where: { $0.title == section }) {
                    page.sections[i].settings.append(d)
                    page.sections[i].order = min(page.sections[i].order, m.settingsOrder)
                } else {
                    page.sections.append(Section(title: section, order: m.settingsOrder, settings: [d]))
                }
            }
            pages[title] = page
        }
        for title in pages.keys { pages[title]?.sections.sort { ($0.order, $0.title) < ($1.order, $1.title) } }
        if pages["Keyboard"] == nil {
            pages["Keyboard"] = SettingsPageModel(id: "keyboard", title: "Keyboard", systemImage: "keyboard")
        }
        pages["Keyboard"]?.content = .keyboard

        let order = known.map(\.title)
        let main = pages.values.sorted { a, b in
            let (i, j) = (order.firstIndex(of: a.title) ?? order.count, order.firstIndex(of: b.title) ?? order.count)
            return (i, a.title) < (j, b.title)
        } + panes.map { SettingsPageModel(id: $0.id, title: $0.title, systemImage: $0.systemImage, content: .pane($0)) }
        let features = SettingsPageModel(id: "features", title: "Features", systemImage: "puzzlepiece.extension", content: .features)
        return (main, [features])
    }

    /// A search hit in the sidebar: a page, a setting or a command, with where it lives.
    struct SearchResult: Identifiable, Equatable {
        var id: String
        var title: String
        var breadcrumb: String
        var pageID: String
        var systemImage: String
    }

    /// Pages, then settings, then commands whose words contain `query`.
    static func results(for query: String, in pages: [SettingsPageModel], commands: [CommandDescriptor]) -> [SearchResult] {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return [] }
        func hit(_ words: String?...) -> Bool { words.contains { $0?.localizedCaseInsensitiveContains(query) == true } }
        var out = pages.filter { hit($0.title) }.map {
            SearchResult(id: "page:\($0.id)", title: $0.title, breadcrumb: "Settings", pageID: $0.id, systemImage: $0.systemImage)
        }
        for page in pages {
            for section in page.sections {
                for d in section.settings where hit(d.title, d.description, section.title) || d.optionTitles.contains(where: { hit($0) }) {
                    out.append(SearchResult(id: "setting:\(d.key)", title: d.title, breadcrumb: "\(page.title) › \(section.title)",
                                            pageID: page.id, systemImage: page.systemImage))
                }
            }
        }
        if let keyboard = pages.first(where: { if case .keyboard = $0.content { true } else { false } }) {
            for c in commands where hit(c.title) || c.keywords.contains(where: { hit($0) }) {
                out.append(SearchResult(id: "command:\(c.id)", title: c.title, breadcrumb: "\(keyboard.title) › Shortcuts",
                                        pageID: keyboard.id, systemImage: keyboard.systemImage))
            }
        }
        return out
    }
}
