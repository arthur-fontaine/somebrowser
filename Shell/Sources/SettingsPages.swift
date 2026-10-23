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
    var color: Color
    var sections: [Section] = []
    var content: Content = .settings

    /// Pages known by name get their place and icon; a page only a fork's feature names comes after them.
    static let known: [(title: String, systemImage: String, color: Color)] = [
        ("General", "gearshape.fill", .gray),
        ("Appearance", "paintbrush.fill", .blue),
        ("Tabs", "square.on.square.fill", .orange),
        ("Search", "magnifyingglass", .purple),
        ("Privacy & Security", "hand.raised.fill", .blue),
        ("Integrations", "app.connected.to.app.below.fill", .green),
        ("Keyboard", "keyboard.fill", .gray),
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
            var page = pages[title] ?? SettingsPageModel(id: id(of: title), title: title, systemImage: known?.systemImage ?? "puzzlepiece.fill",
                                                         color: known?.color ?? .gray)
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
            pages["Keyboard"] = SettingsPageModel(id: "keyboard", title: "Keyboard", systemImage: "keyboard.fill", color: .gray)
        }
        pages["Keyboard"]?.content = .keyboard

        let order = known.map(\.title)
        let main = pages.values.sorted { a, b in
            let (i, j) = (order.firstIndex(of: a.title) ?? order.count, order.firstIndex(of: b.title) ?? order.count)
            return (i, a.title) < (j, b.title)
        } + panes.map { SettingsPageModel(id: $0.id, title: $0.title, systemImage: $0.systemImage, color: .gray, content: .pane($0)) }
        let features = SettingsPageModel(id: "features", title: "Features", systemImage: "shippingbox.fill", color: .brown, content: .features)
        return (main, [features])
    }

    /// The page's sections narrowed to settings matching `query` (all of them when the page's title matches).
    func sections(matching query: String) -> [Section] {
        guard !query.isEmpty, !title.localizedCaseInsensitiveContains(query) else { return sections }
        return sections.compactMap { s in
            if s.title.localizedCaseInsensitiveContains(query) { return s }
            var s = s
            s.settings = s.settings.filter { Self.matches($0, query) }
            return s.settings.isEmpty ? nil : s
        }
    }

    static func matches(_ d: SettingDescriptor, _ query: String) -> Bool {
        [d.title, d.description ?? ""].contains { $0.localizedCaseInsensitiveContains(query) }
            || d.optionTitles.contains { $0.localizedCaseInsensitiveContains(query) }
    }

    static func matches(_ c: CommandDescriptor, _ query: String) -> Bool {
        query.isEmpty || c.title.localizedCaseInsensitiveContains(query) || c.keywords.contains { $0.localizedCaseInsensitiveContains(query) }
    }
}
