import BrowserCore
import Testing
@testable import BrowserShell

@MainActor
struct SettingsPagesTests {
    func setting(_ key: String, _ title: String, section: String? = nil) -> SettingDescriptor {
        SettingDescriptor(key: key, title: title, kind: .bool, defaultValue: .bool(true), section: section)
    }

    @Test func featuresGoOnTheirPagesInOrder() {
        let manifests = [
            FeatureManifest(id: "b", name: "Beta", settings: [setting("b.x", "Bx")], settingsPage: "Tabs", settingsOrder: 20),
            FeatureManifest(id: "a", name: "Alpha", settings: [setting("a.x", "Ax")], settingsPage: "Tabs", settingsOrder: 10),
            FeatureManifest(id: "c", name: "Gamma", settings: [setting("c.x", "Cx", section: "Shared")]),
            FeatureManifest(id: "d", name: "Delta", settings: [setting("d.x", "Dx", section: "Shared")]),
            FeatureManifest(id: "e", name: "Epsilon", settings: [setting("e.x", "Ex")], settingsPage: "Zeta Things"),
            FeatureManifest(id: "f", name: "No settings", settingsPage: "Empty"),
        ]
        let pages = SettingsPageModel.build(manifests: manifests, panes: [])
        // Known pages first in their order, then pages only features name, then Keyboard's place among the known.
        #expect(pages.main.map(\.title) == ["General", "Tabs", "Keyboard", "Zeta Things"])
        #expect(pages.main.map(\.id) == ["general", "tabs", "keyboard", "zeta-things"])
        #expect(pages.main[1].sections.map(\.title) == ["Alpha", "Beta"])
        #expect(pages.main[0].sections.map(\.title) == ["Shared"] && pages.main[0].sections[0].settings.map(\.key) == ["c.x", "d.x"])
        #expect(pages.advanced.map(\.id) == ["features"])
    }

    @Test func searchFindsPagesSettingsAndCommands() {
        let m = FeatureManifest(id: "a", name: "Alpha", settings: [setting("a.x", "Block ads"), setting("a.y", "Hide placeholders")],
                                settingsPage: "Privacy & Security")
        let pages = SettingsPageModel.build(manifests: [m], panes: [])
        let commands = [CommandDescriptor(id: "a.tab", title: "New Tab", keywords: ["ads"])]
        let hits = SettingsPageModel.results(for: "ads", in: pages.main + pages.advanced, commands: commands)
        #expect(hits.map(\.id) == ["setting:a.x", "command:a.tab"])
        #expect(hits[0].breadcrumb == "Privacy & Security › Alpha" && hits[0].pageID == "privacy-security")
        #expect(hits[1].pageID == "keyboard")
        #expect(SettingsPageModel.results(for: "keyboard", in: pages.main, commands: []).map(\.id) == ["page:keyboard"])
        #expect(SettingsPageModel.results(for: "  ", in: pages.main, commands: commands).isEmpty)
    }

    @Test func listEditorsRoundTripTheStoredString() {
        let items = ListSettingEditor.items(of: "yt=https://y.com/?q=%s, gh=https://g.com/search?q=%s,", editor: .pairs)
        #expect(items.map(\.key) == ["yt", "gh"] && items[0].value == "https://y.com/?q=%s")
        var edited = items + [ListSettingEditor.Item()]  // an empty item isn't stored
        #expect(ListSettingEditor.string(of: edited, editor: .pairs) == "yt=https://y.com/?q=%s,gh=https://g.com/search?q=%s")
        edited[1].key = ""
        #expect(ListSettingEditor.string(of: edited, editor: .pairs) == "yt=https://y.com/?q=%s")
        #expect(ListSettingEditor.string(of: ListSettingEditor.items(of: "a.com, b.com", editor: .list), editor: .list) == "a.com,b.com")
    }
}
