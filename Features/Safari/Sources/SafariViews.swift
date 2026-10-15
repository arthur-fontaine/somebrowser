import AppKit
import BrowserCore
import SwiftUI

/// Start page: Safari Favorites (live) and the iPhone's tabs, or the button that connects Safari.
struct SafariStartSection: View {
    let model: SafariModel
    let window: BrowserWindowState
    let open: (URL, Bool) -> Void
    let openInNewWindow: (URL) -> Void
    let delete: (SafariBookmark) -> Void
    let connect: () -> Void

    var body: some View {
        switch model.hasAccess {
        case .some(false):
            Button(action: connect) {
                Label("Sync with Safari on your iPhone", systemImage: "safari")
                    .font(.callout)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(.quaternary.opacity(0.5), in: Capsule())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        case .some(true):
            VStack(spacing: 14) {
                if !model.favorites.isEmpty {
                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(76), spacing: 14), count: min(model.favorites.count, 8)), spacing: 14) {
                        ForEach(model.favorites.prefix(16)) { favorite in
                            FavoriteTile(favorite: favorite) { open(favorite.url, false) }
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
                }
                if !model.devices.isEmpty || !model.tabGroups.isEmpty {
                    Button { window.toggle(flag: SafariFeature.cloudTabsFlag) } label: {
                        Label("iCloud Tabs", systemImage: "icloud")
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .background(.quaternary.opacity(0.5), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
            }
            .animation(.spring(duration: 0.35, bounce: 0.2), value: model.favorites)
        case .none:
            EmptyView()
        }
    }
}

struct FavoriteTile: View {
    let favorite: SafariBookmark
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                AsyncImage(url: URL(string: "/favicon.ico", relativeTo: favorite.url)) { image in
                    image.resizable().interpolation(.high)
                } placeholder: {
                    Text(String(favorite.title.prefix(1)).uppercased()).font(.system(size: 18, weight: .semibold)).foregroundStyle(.secondary)
                }
                .frame(width: 26, height: 26)
                .frame(width: 56, height: 56)
                .background(.quaternary.opacity(hovering ? 0.8 : 0.5), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .scaleEffect(hovering ? 1.05 : 1)
                Text(favorite.title).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).frame(width: 76)
            }
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(.spring(duration: 0.2)) { hovering = h } }
        .help(favorite.url.absoluteString)
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
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
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
