import AppKit
import BrowserCore
import SwiftUI

/// Start page: Safari Favorites (live) and the iPhone's tabs; connecting Safari is a start-page suggestion.
struct SafariStartSection: View {
    @Environment(BrowserEnvironment.self) private var env
    let model: SafariModel
    let window: BrowserWindowState
    let open: (URL, Bool) -> Void
    let openInNewWindow: (URL) -> Void
    let delete: (SafariBookmark) -> Void

    var body: some View {
        switch model.hasAccess {
        case .some(false):
            EmptyView()  // the connect card is a start-page suggestion
        case .some(true):
            if !model.favorites.isEmpty || !model.devices.isEmpty || !model.tabGroups.isEmpty {
                PageSection("iCloud Favorites") {
                    if !model.favorites.isEmpty {
                        LazyVGrid(columns: SiteTile.columns, alignment: .leading, spacing: 16) {
                            ForEach(model.favorites.prefix(16)) { favorite in
                                // Only an icon a page already showed: a start page contacts no site.
                                SiteTile(icon: env.runtime.favicons.image(for: favorite.url), title: favorite.title,
                                         help: favorite.url.absoluteString) { open(favorite.url, false) }
                                    .contextMenu {
                                        Button("Open in New Tab") { open(favorite.url, true) }
                                        Button("Open in New Window") { openInNewWindow(favorite.url) }
                                        Button("Delete", role: .destructive) { delete(favorite) }
                                        Button("Copy Link") {
                                            NSPasteboard.general.clearContents()
                                            NSPasteboard.general.setString(favorite.url.absoluteString, forType: .string)
                                        }
                                    }
                                    .transition(.scale.combined(with: .opacity))
                            }
                        }
                        .animation(Design.Motion.layout, value: model.favorites)
                    }
                    if !model.devices.isEmpty || !model.tabGroups.isEmpty {
                        Button { window.toggle(flag: SafariFeature.cloudTabsFlag) } label: {
                            Label("iCloud Tabs", systemImage: "icloud")
                                .font(.system(size: 13))
                                .padding(.horizontal, 14)
                                .frame(height: 32)
                                .background(Design.Fill.hover, in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                    }
                }
            }
        case .none:
            EmptyView()
        }
    }
}

/// The iPhone's (and other devices') open Safari tabs, then Safari's Tab Groups.
struct CloudTabsPanel: View {
    let model: SafariModel
    let window: BrowserWindowState
    let open: (URL) -> Void

    var body: some View {
        if window.flags.contains(SafariFeature.cloudTabsFlag) {
            ZStack {
                Color.black.opacity(0.12).contentShape(Rectangle()).onTapGesture { window.flags.remove(SafariFeature.cloudTabsFlag) }
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Label("iCloud Tabs", systemImage: "icloud").font(.title3.bold())
                        Spacer()
                        Button { window.flags.remove(SafariFeature.cloudTabsFlag) } label: { Image(systemName: "xmark") }
                            .buttonStyle(.borderless).keyboardShortcut(.cancelAction)
                    }
                    if model.devices.isEmpty && model.tabGroups.isEmpty {
                        ContentUnavailableView("No iCloud Tabs", systemImage: "icloud.slash",
                                               description: Text("Tabs open in Safari on your other devices, and Safari's Tab Groups, appear here."))
                    } else {
                        List {
                            ForEach(model.devices) { device in
                                Section(device.name) { ForEach(device.tabs) { tab in row(tab) } }
                            }
                            ForEach(model.tabGroups) { group in
                                Section {
                                    ForEach(group.tabs) { tab in row(tab) }
                                } header: {
                                    Label(group.title, systemImage: "square.on.square")
                                }
                            }
                        }
                        .listStyle(.inset)
                    }
                }
                .padding(20)
                .frame(width: 560, height: 460)
                .overlayKeyboardFocus("safari.cloud-tabs", in: window)
                .glassSurface(in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .shadow(color: .black.opacity(0.25), radius: 24, y: 10)
            }
        }
    }

    private func row(_ tab: SafariBookmark) -> some View {
        HStack {
            Text(tab.title.isEmpty ? tab.url.absoluteString : tab.title).lineLimit(1)
            Spacer()
            Text(tab.url.host() ?? "").foregroundStyle(.tertiary).lineLimit(1)
        }
        .contentShape(Rectangle())
        .onTapGesture { open(tab.url); window.flags.remove(SafariFeature.cloudTabsFlag) }
    }
}
