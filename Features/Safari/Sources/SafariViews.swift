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

/// Start page: the tabs last looked at on the iPhone, as tiles like the favorites; Show All lists the rest in place.
struct SafariRecentTabsSection: View {
    @Environment(BrowserEnvironment.self) private var env
    let model: SafariModel
    let window: BrowserWindowState
    let open: (URL, Bool) -> Void
    let openInNewWindow: (URL) -> Void
    @State private var showsAll = false

    static let shown = 8

    var body: some View {
        let all = model.recentTabs
        let tabs = all.prefix(showsAll ? all.count : Self.shown)
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
                if all.count > Self.shown {
                    PageSectionLink(showsAll ? "Show Less" : "Show All") {
                        withAnimation(Design.Motion.layout) { showsAll.toggle() }
                    }
                }
            }
        }
    }
}

/// The sidebar's iPhone tabs, under the favorites: the few last looked at on the iPhone and not open here, a click from
/// opening here (Handoff's idea: one opened leaves the list, as it's now a tab). The header folds them; its menu shows
/// every iCloud tab or hides the block (`safari.sidebar-tabs`).
struct SidebarPhoneTabs: View {
    @Environment(BrowserEnvironment.self) private var env
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let model: SafariModel
    let window: BrowserWindowState
    let open: (URL, _ select: Bool) -> Void
    let fold: (Bool) -> Void
    let hide: () -> Void
    @State private var hovering = false

    var body: some View {
        let store = env.runtime.tabs
        let tabs = model.sidebarTabs { url in
            model.handedOff[url].flatMap(store.tab) != nil || !store.tabs(matching: url, in: window.spaceID).isEmpty
        }
        if env.runtime.settings.bool("safari.sidebar-tabs"), !window.isPrivate, !tabs.isEmpty {
            VStack(spacing: Design.Space.row) {
                header
                if !model.sidebarCollapsed {
                    ForEach(tabs) { tab in
                        PhoneTabRow(tab: tab, icon: env.runtime.favicons.image(for: tab.url), open: open)
                            .transition(.opacity)
                    }
                }
            }
            .animation(reduceMotion ? Design.Motion.reduced : Design.Motion.layout, value: tabs.map(\.id))
            .animation(reduceMotion ? Design.Motion.reduced : Design.Motion.layout, value: model.sidebarCollapsed)
        }
    }

    private var header: some View {
        HStack(spacing: Design.Grid.iconToText) {
            Image(systemName: "iphone").font(.system(size: 11, weight: .semibold))
                .frame(width: Design.Size.favicon)
            Text(model.recentTabsTitle).font(.system(size: 11, weight: .semibold))
            Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold))
                .rotationEffect(.degrees(model.sidebarCollapsed ? 0 : 90))
                .opacity(hovering || model.sidebarCollapsed ? 1 : 0)
            Spacer(minLength: 0)
        }
        .foregroundStyle(.secondary)
        .padding(.leading, Design.Grid.iconInset)
        .frame(height: 22)
        .contentShape(Rectangle())
        .onTapGesture { fold(!model.sidebarCollapsed) }
        .onHover { h in withAnimation(Design.Motion.hover) { hovering = h } }
        .help(model.sidebarCollapsed ? "Show the iPhone's Latest Tabs" : "Fold")
        .contextMenu {
            Button("Show All iCloud Tabs") { window.toggle(flag: SafariFeature.cloudTabsFlag) }
            Button("Hide from Sidebar", action: hide)
        }
    }
}

/// A tab on the iPhone, on the sidebar's grid like a tab here, but quieter: its title in the secondary color, how long
/// ago it was viewed at its end.
struct PhoneTabRow: View {
    let tab: SafariBookmark
    let icon: NSImage?
    let open: (URL, _ select: Bool) -> Void
    @State private var hovering = false

    var body: some View {
        Button {
            open(tab.url, !(NSApp.currentEvent?.modifierFlags.contains(.command) ?? false))
        } label: {
            HStack(spacing: Design.Grid.iconToText) {
                SiteIcon(icon).frame(width: Design.Size.favicon, height: Design.Size.favicon)
                Text(tab.title.isEmpty ? tab.url.absoluteString : tab.title)
                    .font(.system(size: 13)).lineLimit(1).truncationMode(.tail)
                    .foregroundStyle(hovering ? .primary : .secondary)
                Spacer(minLength: 4)
                if let viewed = tab.lastViewed {
                    TimelineView(.everyMinute) { context in
                        Text(Self.age(viewed, now: context.date)).font(.system(size: 11)).monospacedDigit().foregroundStyle(.tertiary)
                    }
                }
            }
            .padding(.leading, Design.Grid.iconInset)
            .padding(.trailing, 10)
            .frame(height: 32)
            .background(Design.itemShape.fill(hovering ? Design.Fill.hover : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(tab.title.isEmpty ? tab.url.absoluteString : tab.title)
        .accessibilityValue(tab.lastViewed.map { Self.age($0) } ?? "")
        .onHover { h in withAnimation(Design.Motion.hover) { hovering = h } }
        .help((tab.title.isEmpty ? "" : tab.title + "\n") + tab.url.absoluteString)
        .contextMenu {
            Button("Open") { open(tab.url, true) }
            Button("Open in Background") { open(tab.url, false) }
            CopyLinkButton(url: tab.url)
        }
    }

    /// "now", "5m", "2h", "3d".
    static func age(_ date: Date, now: Date = Date()) -> String {
        let minutes = Int(max(0, now.timeIntervalSince(date)) / 60)
        if minutes < 1 { return "now" }
        if minutes < 60 { return "\(minutes)m" }
        if minutes < 24 * 60 { return "\(minutes / 60)h" }
        return "\(minutes / (24 * 60))d"
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
        let devices = model.devices.map { PanelSection(id: "device/" + $0.id, title: $0.name, items: items($0.tabs, prefix: $0.id)) }
        let groups = model.tabGroups.map { PanelSection(id: "group/" + $0.id, title: $0.title, items: items($0.tabs, prefix: $0.id)) }
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
