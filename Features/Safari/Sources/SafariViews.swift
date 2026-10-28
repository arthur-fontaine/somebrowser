import AppKit
import BrowserCore
import SwiftUI

/// Start page: Safari's Favorites (live); connecting Safari is a start-page suggestion.
struct SafariFavoritesSection: View {
    @Environment(BrowserEnvironment.self) private var env
    let model: SafariModel
    let open: (URL, Bool) -> Void
    let openInNewWindow: (URL) -> Void
    let delete: (SafariBookmark) -> Void

    var body: some View {
        if model.hasAccess == true, !model.favorites.isEmpty {
            PageSection("iCloud Favorites") {
                LazyVGrid(columns: SiteTile.columns, alignment: .leading, spacing: 16) {
                    ForEach(model.favorites.prefix(16)) { favorite in
                        // Only an icon a page already showed: a start page contacts no site.
                        SiteTile(icon: env.runtime.favicons.image(for: favorite.url), title: favorite.title,
                                 help: favorite.url.absoluteString) { open(favorite.url, false) }
                            .contextMenu {
                                Button("Open in New Tab") { open(favorite.url, true) }
                                Button("Open in New Window") { openInNewWindow(favorite.url) }
                                Button("Delete", role: .destructive) { delete(favorite) }
                                CopyLinkButton(url: favorite.url)
                            }
                            .transition(.scale.combined(with: .opacity))
                    }
                }
                .animation(Design.Motion.layout, value: model.favorites)
            }
        }
    }
}

/// Start page: the tabs last looked at on the iPhone, as tiles like the favorites; Show All opens iCloud Tabs.
struct SafariRecentTabsSection: View {
    @Environment(BrowserEnvironment.self) private var env
    let model: SafariModel
    let window: BrowserWindowState
    let open: (URL, Bool) -> Void
    let openInNewWindow: (URL) -> Void

    var body: some View {
        let tabs = model.recentTabs.prefix(8)
        if !tabs.isEmpty, !window.isPrivate {
            PageSection(model.recentTabsTitle) {
                LazyVGrid(columns: SiteTile.columns, alignment: .leading, spacing: 16) {
                    ForEach(tabs) { tab in
                        let title = tab.title.isEmpty ? SiteTile.name(for: tab.url) ?? tab.url.absoluteString : tab.title
                        SiteTile(icon: env.runtime.favicons.image(for: tab.url), title: title,
                                 help: tab.title.isEmpty ? tab.url.absoluteString : tab.title + "\n" + tab.url.absoluteString) {
                            open(tab.url, false)
                        }
                        .contextMenu {
                            Button("Open in New Tab") { open(tab.url, true) }
                            Button("Open in New Window") { openInNewWindow(tab.url) }
                            CopyLinkButton(url: tab.url)
                        }
                        .transition(.scale.combined(with: .opacity))
                    }
                }
                .animation(Design.Motion.layout, value: Array(tabs))
            } accessory: {
                PageSectionLink("Show All") { window.toggle(flag: SafariFeature.cloudTabsFlag) }
            }
        }
    }
}

struct CopyLinkButton: View {
    let url: URL

    var body: some View {
        Button("Copy Link") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(url.absoluteString, forType: .string)
        }
    }
}

/// The iPhone's (and other devices') open Safari tabs, then Safari's Tab Groups: a popover above the sidebar's footer,
/// as History and the archive are.
struct CloudTabsPanel: View {
    let model: SafariModel
    let window: BrowserWindowState
    let runtime: BrowserRuntime
    let open: (URL, _ select: Bool) -> Void
    @State private var query = ""

    var body: some View {
        let shown = window.flags.contains(SafariFeature.cloudTabsFlag)
        ListPopover("safari.cloud-tabs", in: window, isShown: shown, title: "iCloud Tabs", query: $query,
                    sections: shown ? sections() : [],
                    empty: PanelEmptyState(symbol: "icloud", title: query.isEmpty ? "No iCloud Tabs" : "No Matches",
                                           detail: query.isEmpty ? "Tabs open in Safari on your iPhone, and Safari's Tab Groups, show up here." : nil),
                    close: { window.flags.remove(SafariFeature.cloudTabsFlag) })
            .onChange(of: shown) { if !shown { query = "" } }
    }

    private func sections() -> [PanelSection] {
        let devices = model.devices.map { PanelSection(title: $0.name, items: items($0.tabs, prefix: $0.id)) }
        let groups = model.tabGroups.map { PanelSection(title: $0.title, items: items($0.tabs, prefix: $0.id)) }
        return (devices + groups).filter { !$0.items.isEmpty }
    }

    private func items(_ tabs: [SafariBookmark], prefix: String) -> [PanelItem] {
        tabs.filter { tab in
            query.isEmpty || tab.title.localizedCaseInsensitiveContains(query) || tab.url.absoluteString.localizedCaseInsensitiveContains(query)
        }.map { tab in
            PanelItem(id: prefix + "/" + tab.id, icon: runtime.favicons.image(for: tab.url),
                      title: tab.title.isEmpty ? tab.url.absoluteString : tab.title, subtitle: tab.url.absoluteString,
                      detail: tab.lastViewed.map(Self.when), url: tab.url,
                      open: { open(tab.url, true) }, openInBackground: { open(tab.url, false) })
        }
    }

    /// The time today, the day this week, else the date.
    static func when(_ date: Date) -> String {
        let calendar = Calendar.current, now = Date()
        if calendar.isDate(date, inSameDayAs: now) { return date.formatted(date: .omitted, time: .shortened) }
        if let week = calendar.date(byAdding: .day, value: -6, to: now), date > calendar.startOfDay(for: week) {
            return date.formatted(.dateTime.weekday(.abbreviated))
        }
        return date.formatted(.dateTime.day().month(.abbreviated))
    }
}
