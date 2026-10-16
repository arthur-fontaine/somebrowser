import AppKit
import BrowserCore
import SwiftUI
import UniformTypeIdentifiers

/// The tree for one container (pinned or today), as a flat list of precomputed rows.
struct TabList: View {
    @Environment(BrowserEnvironment.self) private var env
    let window: BrowserWindowState
    let model: SidebarModel
    let container: Container

    var body: some View {
        let store = env.runtime.tabs
        let all = store.rows(in: container)
        let rows = window.flags.contains(SidebarModel.focusFlag) ? SidebarLogic.focusRows(all, selected: window.selectedTabID, store: store) : all
        let rowHeight = model.rowHeight
        Group {
            if rows.isEmpty, case .section(_, .pinned) = container {
                EmptyPinnedDropZone(container: container)
            } else {
                LazyVStack(alignment: .leading, spacing: SidebarModel.rowSpacing) {
                    ForEach(rows) { row in
                        TabRow(row: row, window: window, model: model, rowHeight: rowHeight)
                            .transition(.asymmetric(
                                insertion: .move(edge: .top).combined(with: .opacity),
                                removal: .opacity.combined(with: .scale(scale: 0.96, anchor: .leading))))
                    }
                }
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let p):
                        let id = SidebarLogic.row(at: p.y, rows: rows, rowHeight: rowHeight, spacing: SidebarModel.rowSpacing)?.id
                        if model.hovered != id { model.hovered = id }
                    case .ended:
                        if let h = model.hovered, rows.contains(where: { $0.id == h }) { model.hovered = nil }
                    }
                }
            }
        }
        .animation(.spring(duration: 0.38, bounce: 0.16), value: rows)
    }
}

struct EmptyPinnedDropZone: View {
    @Environment(BrowserEnvironment.self) private var env
    let container: Container
    @State private var targeted = false

    var body: some View {
        Text("Drag tabs here to keep them")
            .font(.system(size: 11))
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, minHeight: 28)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                .foregroundStyle(targeted ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary)))
            .dropDestination(for: String.self) { items, _ in
                guard let id = items.first.flatMap(UUID.init(uuidString:)) else { return false }
                return env.runtime.sidebarHistory.move(id) { SidebarLogic.drop(id, into: container, store: env.runtime.tabs) }
            } isTargeted: { targeted = $0 }
    }
}

struct TabRow: View {
    @Environment(BrowserEnvironment.self) private var env
    let row: SidebarRow
    let window: BrowserWindowState
    let model: SidebarModel
    let rowHeight: CGFloat

    static let indent: CGFloat = 14

    var body: some View {
        let store = env.runtime.tabs
        let selected = window.selectedTabID == row.id
        let hovered = model.hovered == row.id
        let drop = model.dropTarget?.id == row.id ? model.dropTarget?.zone : nil
        HStack(spacing: 6) {
            disclosure
            if let tab = store.tab(row.id) {
                TabRowContent(tab: tab, window: window, selected: selected, hovered: hovered, renaming: isRenaming)
            } else if let folder = store.folder(row.id) {
                FolderRowContent(folder: folder, window: window, renaming: isRenaming)
            }
        }
        .padding(.leading, 6 + CGFloat(row.depth) * Self.indent)
        .padding(.trailing, 4)
        .frame(height: rowHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(alignment: .leading) { guides }
        .background {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(selected ? AnyShapeStyle(Color(nsColor: .controlBackgroundColor).opacity(0.92))
                      : hovered ? AnyShapeStyle(Color.primary.opacity(0.07)) : AnyShapeStyle(Color.clear))
                .shadow(color: .black.opacity(selected ? 0.10 : 0), radius: 1.5, y: 0.5)
        }
        .overlay { dropIndicator(drop) }
        .contentShape(Rectangle())
        // A single click selects at once: a double-click gesture placed before it would hold every click for the
        // double-click interval (up to half a second) to rule out a second one.
        .onTapGesture { activate() }
        .simultaneousGesture(TapGesture(count: 2).onEnded { window.flags.insert("rename:\(row.id.uuidString)") })
        .contextMenu { RowMenu(id: row.id, window: window) }
        .onDrag {
            model.dragging = row.id
            return NSItemProvider(object: row.id.uuidString as NSString)
        }
        .onDrop(of: [UTType.text], delegate: RowDropDelegate(target: row, model: model, store: store, history: env.runtime.sidebarHistory, rowHeight: rowHeight))
    }

    private var isRenaming: Bool { window.flags.contains("rename:\(row.id.uuidString)") }

    @ViewBuilder
    private var disclosure: some View {
        if row.hasChildren {
            Button {
                withAnimation(.spring(duration: 0.3, bounce: 0.1)) { env.runtime.tabs.setCollapsed(row.id, !row.isCollapsed) }
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .rotationEffect(.degrees(row.isCollapsed ? 0 : 90))
                    .frame(width: 12, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.tertiary)
        } else if row.depth > 0 || hasSiblingsWithChildren {
            Color.clear.frame(width: 12)
        }
    }

    private var hasSiblingsWithChildren: Bool { false }

    @ViewBuilder
    private var guides: some View {
        if row.depth > 0, env.runtime.settings.bool("sidebar.treeGuides") {
            HStack(spacing: 0) {
                ForEach(0..<row.depth, id: \.self) { d in
                    Rectangle().fill(.quaternary).frame(width: 1)
                        .padding(.leading, d == 0 ? 6 + 5.5 : Self.indent - 1)
                }
            }
            .padding(.vertical, -1)
        }
    }

    private func activate() {
        let runtime = env.runtime
        if runtime.tabs.folder(row.id) != nil {
            withAnimation(.spring(duration: 0.3, bounce: 0.1)) { runtime.tabs.setCollapsed(row.id, !row.isCollapsed) }
            return
        }
        runtime.select(row.id, in: window)
        runtime.shell?.focusContent(in: window)
    }

    @ViewBuilder
    private func dropIndicator(_ zone: SidebarLogic.DropZone?) -> some View {
        switch zone {
        case .inside:
            RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(.tint, lineWidth: 2)
        case .before:
            VStack { Capsule().fill(.tint).frame(height: 2); Spacer() }.padding(.top, -2)
        case .after:
            VStack { Spacer(); Capsule().fill(.tint).frame(height: 2) }.padding(.bottom, -2)
        case nil:
            EmptyView()
        }
    }
}

struct TabRowContent: View {
    @Environment(BrowserEnvironment.self) private var env
    let tab: BrowserTab
    let window: BrowserWindowState
    let selected: Bool
    let hovered: Bool
    let renaming: Bool

    var body: some View {
        let live = tab.live
        HStack(spacing: 8) {
            FaviconView(tab: tab).frame(width: 16, height: 16)
            if renaming {
                RenameField(initial: tab.displayTitle) { name in
                    tab.customTitle = name.isEmpty ? nil : name
                    window.flags.remove("rename:\(tab.id.uuidString)")
                }
            } else {
                Text(title(live))
                    .font(.system(size: 13, weight: selected ? .medium : .regular))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(tab.isLoaded || selected ? .primary : .secondary)
            }
            Spacer(minLength: 2)
            if let live, live.isPlayingAudio || live.isMuted {
                Button { tab.engineTab?.isMuted.toggle() } label: {
                    Image(systemName: live.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .font(.system(size: 10)).symbolEffect(.variableColor.iterative, isActive: live.isPlayingAudio && !live.isMuted)
                }
                .buttonStyle(.plain).foregroundStyle(.secondary).help(live.isMuted ? "Unmute" : "Mute")
            }
            if let live, live.isCapturingCamera || live.isCapturingMicrophone {
                Image(systemName: live.isCapturingCamera ? "video.fill" : "mic.fill").font(.system(size: 10)).foregroundStyle(.red)
            }
            if hovered || selected {
                Button {
                    withAnimation(.spring(duration: 0.32, bounce: 0.12)) { env.runtime.sidebarHistory.close([tab.id], includingDescendants: false) }
                } label: {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).frame(width: 18, height: 18)
                        .background(Circle().fill(Color.primary.opacity(hovered ? 0.06 : 0)))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Close Tab (⌘W)")
                .transition(.opacity)
            }
        }
    }

    private func title(_ live: EngineTabState?) -> String {
        if let custom = tab.customTitle, !custom.isEmpty { return custom }
        if let t = live?.title, !t.isEmpty { return t }
        return tab.displayTitle
    }
}

struct FolderRowContent: View {
    let folder: Folder
    let window: BrowserWindowState
    let renaming: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: folder.isCollapsed ? "folder" : "folder.fill")
                .font(.system(size: 13)).foregroundStyle(.secondary).frame(width: 16)
            if renaming {
                RenameField(initial: folder.name) { name in
                    if !name.isEmpty { folder.name = name }
                    window.flags.remove("rename:\(folder.id.uuidString)")
                }
            } else {
                Text(folder.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
            }
            Spacer()
        }
    }
}

struct RenameField: View {
    let initial: String
    let commit: (String) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField("", text: $text)
            .textFieldStyle(.plain)
            .font(.system(size: 13))
            .focused($focused)
            .onAppear { text = initial; focused = true }
            .onSubmit { commit(text) }
            .onExitCommand { commit(initial) }
            .onChange(of: focused) { if !focused { commit(text) } }
    }
}

struct FaviconView: View {
    let tab: BrowserTab

    var body: some View {
        let live = tab.live
        ZStack {
            if let image = live?.favicon {
                Image(nsImage: image).resizable().interpolation(.high).scaledToFit()
            } else if let url = live?.faviconURL ?? tab.faviconURL {
                AsyncImage(url: url) { phase in
                    if let image = phase.image { image.resizable().scaledToFit() } else { placeholder }
                }
            } else {
                placeholder
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
        .overlay {
            if live?.isLoading == true {
                ProgressView().controlSize(.mini).scaleEffect(0.8)
                    .background(Circle().fill(.background).padding(-1))
            }
        }
    }

    private var placeholder: some View {
        Image(systemName: tab.url == nil ? "plus.square.dashed" : "globe")
            .resizable().scaledToFit().foregroundStyle(.tertiary)
    }
}

struct RowMenu: View {
    @Environment(BrowserEnvironment.self) private var env
    let id: NodeID
    let window: BrowserWindowState

    var body: some View {
        let runtime = env.runtime
        let store = runtime.tabs
        if let tab = store.tab(id) {
            Button("New Child Tab") { runtime.openTab(nil, in: window, placement: .childOf(id)) }
            Button("Duplicate") { if let u = tab.live?.url ?? tab.url { runtime.openTab(u, in: window, placement: .after(id)) } }
            Button("Rename…") { window.flags.insert("rename:\(id.uuidString)") }
            Divider()
            if store.isPinned(id) {
                Button("Unpin") { runtime.sidebarHistory.move(id) { store.unpin(id, in: window.spaceID) } }
            } else {
                Button("Pin") { runtime.sidebarHistory.move(id) { store.pin(id, in: window.spaceID) } }
            }
            Button("Add to Favorites") { runtime.sidebarHistory.move(id) { store.favorite(id) } }
            Toggle("Open Links in This Tab", isOn: Binding(get: { tab.opensLinksInPlace }, set: { tab.opensLinksInPlace = $0 }))
            Divider()
            Button("Copy Link") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString((tab.live?.url ?? tab.url)?.absoluteString ?? "", forType: .string)
            }
            Button("Copy Branch as Markdown") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(SidebarLogic.markdown(for: id, store: store), forType: .string)
            }
            // Between the user's own tabs and Claude's; private tabs never leave the private space, nor join it.
            ForEach(store.spaces.filter { $0.id != window.spaceID && $0.kind != .private && !tab.isPrivate }) { s in
                Button("Move to \(s.kind.title)") { runtime.sidebarHistory.move(id) { try? store.move(id, to: .section(s.id, .today), at: 0) } }
            }
            Divider()
            Button("Close") { runtime.sidebarHistory.close([id], includingDescendants: false) }
            if !store.children(of: id).isEmpty {
                Button("Close with Children") { runtime.sidebarHistory.close([id], includingDescendants: true) }
            }
        } else if store.folder(id) != nil {
            Button("Rename…") { window.flags.insert("rename:\(id.uuidString)") }
            Button("New Tab in Folder") { runtime.openTab(nil, in: window, placement: .container(.node(id), index: nil)) }
            Divider()
            Button("Delete Folder and Tabs") { runtime.sidebarHistory.close([id], includingDescendants: true) }
        }
    }
}

struct RowDropDelegate: DropDelegate {
    let target: SidebarRow
    let model: SidebarModel
    let store: TabStore
    let history: SidebarHistory
    let rowHeight: CGFloat

    func validateDrop(info: DropInfo) -> Bool { model.dragging != nil && model.dragging != target.id }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        let zone = SidebarLogic.zone(atY: info.location.y, rowHeight: rowHeight, canNest: true)
        if model.dropTarget?.id != target.id || model.dropTarget?.zone != zone { model.dropTarget = (target.id, zone) }
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        if model.dropTarget?.id == target.id { model.dropTarget = nil }
    }

    func performDrop(info: DropInfo) -> Bool {
        defer { model.dropTarget = nil; model.dragging = nil }
        guard let dragged = model.dragging else { return false }
        let zone = SidebarLogic.zone(atY: info.location.y, rowHeight: rowHeight, canNest: true)
        var ok = false
        withAnimation(.spring(duration: 0.35, bounce: 0.15)) {
            ok = history.move(dragged) { SidebarLogic.drop(dragged, on: target.id, zone: zone, store: store) }
        }
        if ok { NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now) }
        return ok
    }
}
