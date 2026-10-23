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

    /// The rows shown for `container` (focus mode keeps the selected branch).
    static func rows(_ container: Container, in window: BrowserWindowState, store: TabStore) -> [SidebarRow] {
        let all = store.rows(in: container)
        return window.flags.contains(SidebarModel.focusFlag) ? SidebarLogic.focusRows(all, selected: window.selectedTabID, store: store) : all
    }

    var body: some View {
        let store = env.runtime.tabs
        let rows = Self.rows(container, in: window, store: store)
        let rowHeight = model.rowHeight
        Group {
            if rows.isEmpty, case .section(_, .pinned) = container {
                EmptyPinnedDropZone(model: model, container: container)
            } else {
                LazyVStack(alignment: .leading, spacing: SidebarModel.rowSpacing) {
                    ForEach(rows) { row in
                        TabRow(row: row, window: window, model: model, rowHeight: rowHeight)
                            .transition(.asymmetric(
                                insertion: .move(edge: .top).combined(with: .opacity),
                                removal: .opacity.combined(with: .scale(scale: 0.96, anchor: .leading))))
                    }
                }
                .overlay(alignment: .topLeading) {
                    DropMark(target: model.dropTarget, owner: .list(container), rows: rows, rowHeight: rowHeight)
                }
                .contentShape(Rectangle())  // the gaps between rows take drops too
                .onDrop(of: [UTType.text], delegate: SidebarDropDelegate(model: model, owner: .list(container), env: env) { point, dragged in
                    SidebarLogic.placement(at: point, rows: rows, in: container, dragged: dragged, rowHeight: rowHeight,
                                           spacing: SidebarModel.rowSpacing, store: store)
                })
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
    let model: SidebarModel
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
                defer { model.endDrag() }
                guard let id = items.first.flatMap(UUID.init(uuidString:)) else { return false }
                return env.runtime.sidebarHistory.move(id) { SidebarLogic.drop(id, into: container, store: env.runtime.tabs) }
            } isTargeted: { targeted = $0 }
    }
}

struct TabRow: View {
    @Environment(BrowserEnvironment.self) private var env
    @Environment(\.frozenSelection) private var frozenSelection
    let row: SidebarRow
    let window: BrowserWindowState
    let model: SidebarModel
    let rowHeight: CGFloat

    static let indent = SidebarLogic.indent

    var body: some View {
        let store = env.runtime.tabs
        let selected = (frozenSelection.map(\.id) ?? window.selectedTabID) == row.id
        let hovered = model.hovered == row.id
        Group {
            if let tab = store.tab(row.id) {
                TabRowContent(tab: tab, window: window, selected: selected, hovered: hovered, renaming: isRenaming, disclosure: disclosure)
            } else if let folder = store.folder(row.id) {
                FolderRowContent(folder: folder, window: window, renaming: isRenaming, disclosure: disclosure)
            }
        }
        .padding(.leading, Design.Grid.iconInset + CGFloat(row.depth) * Self.indent)
        .padding(.trailing, 8)  // the ×'s center mirrors the favicon's
        .frame(height: rowHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(alignment: .leading) { guides }
        .background(Design.itemShape.fill(hovered && !selected ? Design.Fill.hover : .clear))
        // Claude at work in the tab: its page's glow, around the row.
        .overlay { AgentGlow(Design.itemShape, activeUntil: store.tab(row.id)?.agentActedAt?.addingTimeInterval(BrowserTab.agentActivityWindow)) }
        .anchorPreference(key: SelectionLensAnchor.self, value: .bounds) { selected ? $0 : nil }
        .contentShape(Rectangle())
        // A single click selects at once: a double-click gesture placed before it would hold every click for the
        // double-click interval (up to half a second) to rule out a second one.
        .onTapGesture { activate() }
        .simultaneousGesture(TapGesture(count: 2).onEnded { window.flags.insert("rename:\(row.id.uuidString)") })
        .contextMenu { RowMenu(id: row.id, window: window) }
        .onDrag {
            model.beginDrag(row.id)
            return NSItemProvider(object: row.id.uuidString as NSString)
        }
    }

    private var isRenaming: Bool { window.flags.contains("rename:\(row.id.uuidString)") }

    /// A parent's chevron takes its icon's place while the row is hovered (or while collapsed, so hidden children show).
    private var disclosure: Disclosure? {
        guard row.hasChildren else { return nil }
        let id = row.id
        return Disclosure(isCollapsed: row.isCollapsed, isShown: model.hovered == id || row.isCollapsed) { [env] in
            withAnimation(Design.Motion.layout) { env.runtime.tabs.setCollapsed(id, !row.isCollapsed) }
        }
    }

    @ViewBuilder
    private var guides: some View {
        if row.depth > 0, env.runtime.settings.bool("sidebar.treeGuides") {
            // Under each ancestor's icon.
            ZStack(alignment: .leading) {
                ForEach(0..<row.depth, id: \.self) { d in
                    Rectangle().fill(.quaternary).frame(width: 1)
                        .offset(x: Design.Grid.iconInset + Design.Size.favicon / 2 - 0.5 + CGFloat(d) * Self.indent)
                }
            }
            .padding(.vertical, -1)
        }
    }

    private func activate() {
        let runtime = env.runtime
        if runtime.tabs.folder(row.id) != nil {
            withAnimation(Design.Motion.layout) { runtime.tabs.setCollapsed(row.id, !row.isCollapsed) }
            return
        }
        runtime.select(row.id, in: window)
        runtime.shell?.focusContent(in: window)
    }
}

/// A parent row's expand/collapse control, drawn in its icon's slot.
struct Disclosure {
    let isCollapsed: Bool
    let isShown: Bool
    let toggle: () -> Void
}

struct DisclosureButton: View {
    let disclosure: Disclosure

    var body: some View {
        Button(action: disclosure.toggle) {
            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .bold))
                .rotationEffect(.degrees(disclosure.isCollapsed ? 0 : 90))
                .frame(width: Design.Size.favicon, height: Design.Size.favicon)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(disclosure.isCollapsed ? "Show Children" : "Hide Children")
    }
}

struct TabRowContent: View {
    @Environment(BrowserEnvironment.self) private var env
    let tab: BrowserTab
    let window: BrowserWindowState
    let selected: Bool
    let hovered: Bool
    let renaming: Bool
    var disclosure: Disclosure?

    var body: some View {
        let live = tab.live
        HStack(spacing: Design.Grid.iconToText) {
            if let disclosure, disclosure.isShown {
                DisclosureButton(disclosure: disclosure)
            } else {
                FaviconView(tab: tab).frame(width: Design.Size.favicon, height: Design.Size.favicon)
            }
            if renaming {
                RenameField(initial: tab.displayTitle) { name in
                    tab.customTitle = name.isEmpty ? nil : name
                    window.flags.remove("rename:\(tab.id.uuidString)")
                }
            } else {
                Text(title(live))
                    .font(.system(size: 13, weight: selected ? .semibold : .regular))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(tab.isLoaded || selected ? .primary : .secondary)
            }
            Spacer(minLength: 2)
            if let acted = tab.agentActedAt {
                AgentSpark(activeUntil: acted.addingTimeInterval(BrowserTab.agentActivityWindow), hidesWhenIdle: true)
                    .frame(width: 12, height: 12)
                    .help("Claude is working in this tab")
            }
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
                CloseTabButton {
                    withAnimation(.spring(duration: 0.32, bounce: 0.12)) { env.runtime.sidebarHistory.close([tab.id], includingDescendants: false) }
                }
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

/// A row's ×: washed under the pointer, over the row's own hover or selection.
struct CloseTabButton: View {
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).frame(width: 20, height: 20)
                .background(Circle().fill(hovering ? Design.Fill.selection : .clear))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(hovering ? .primary : .secondary)
        .onHover { h in withAnimation(Design.Motion.hover) { hovering = h } }
        .help("Close Tab (⌘W)")
    }
}

struct FolderRowContent: View {
    let folder: Folder
    let window: BrowserWindowState
    let renaming: Bool
    var disclosure: Disclosure?

    var body: some View {
        HStack(spacing: Design.Grid.iconToText) {
            if let disclosure, disclosure.isShown {
                DisclosureButton(disclosure: disclosure)
            } else {
                Image(systemName: folder.isCollapsed ? "folder" : "folder.fill")
                    .font(.system(size: 13)).foregroundStyle(.secondary).frame(width: Design.Size.favicon)
            }
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
    @Environment(BrowserEnvironment.self) private var env
    let tab: BrowserTab

    var body: some View {
        let live = tab.live
        // The page's icon, or the one it showed last time (a tab not loaded yet): never fetched from here.
        SiteIcon(live?.favicon ?? env.runtime.favicons.image(for: live?.url ?? tab.url),
                 placeholder: tab.url == nil ? "square.grid.2x2" : "globe")
            .overlay {
                if live?.isLoading == true {
                    ProgressView().controlSize(.mini).scaleEffect(0.8)
                        .background(Circle().fill(.background).padding(-1))
                }
            }
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

/// A drop on the sidebar: `resolve` turns the pointer (in the target's space) into a placement, drawn as `owner`'s mark.
struct SidebarDropDelegate: DropDelegate {
    let model: SidebarModel
    let owner: SidebarModel.DropOwner
    let env: BrowserEnvironment
    let resolve: (CGPoint, NodeID) -> SidebarLogic.DropPlacement?

    func validateDrop(info: DropInfo) -> Bool { model.dragging != nil }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        model.target(model.dragging.flatMap { resolve(info.location, $0) }, by: owner)
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) { model.target(nil, by: owner) }

    func performDrop(info: DropInfo) -> Bool {
        defer { model.endDrag() }
        guard let dragged = model.dragging, let placement = resolve(info.location, dragged) else { return false }
        let runtime = env.runtime
        var ok = false
        withAnimation(.spring(duration: 0.35, bounce: 0.15)) {
            ok = runtime.sidebarHistory.move(dragged) { SidebarLogic.drop(dragged, at: placement, store: runtime.tabs) }
        }
        if ok { NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now) }
        return ok
    }
}

/// Where a drag would land, for one owner: a line starting at the depth's icon, which grows into an outline of the
/// row it would nest in. One per list, gliding from gap to gap.
struct DropMark: View {
    let target: SidebarModel.DropTarget?
    let owner: SidebarModel.DropOwner
    let rows: [SidebarRow]
    let rowHeight: CGFloat

    private static let line: CGFloat = 2
    private static let dot: CGFloat = 6

    var body: some View {
        GeometryReader { geo in
            if let target, target.owner.drawnBy == owner {
                let frame = frame(target.placement.mark, width: geo.size.width)
                let isLine = frame.height == Self.line
                ZStack(alignment: .leading) {
                    Design.itemShape.strokeBorder(.tint, lineWidth: Self.line)
                    // Finder's ring at the line's start.
                    Circle().strokeBorder(.tint, lineWidth: Self.line)
                        .frame(width: Self.dot, height: Self.dot)
                        .offset(x: -Self.dot + 1)
                        .opacity(isLine ? 1 : 0)
                }
                .frame(width: frame.width, height: frame.height)
                .offset(x: frame.minX, y: frame.minY)
                .transition(.opacity)
            }
        }
        .allowsHitTesting(false)
        .animation(.spring(duration: 0.22, bounce: 0), value: target)
    }

    private func frame(_ mark: SidebarLogic.DropPlacement.Mark, width: CGFloat) -> CGRect {
        let pitch = rowHeight + SidebarModel.rowSpacing
        switch mark {
        case .into(let id):
            let i = rows.firstIndex { $0.id == id } ?? 0
            return CGRect(x: 0, y: CGFloat(i) * pitch, width: width, height: rowHeight)
        case .line(let gap, let depth):
            let x = Design.Grid.iconInset + CGFloat(depth) * SidebarLogic.indent + Self.dot - 1
            // Centred in the gap; the first one inside the list, where a scroll view's edge would cut it.
            let y = max(0, CGFloat(gap) * pitch - SidebarModel.rowSpacing / 2 - Self.line / 2)
            return CGRect(x: x, y: y, width: max(0, width - x), height: Self.line)
        }
    }
}

/// The selected row's frame, for the one lens drawn behind all rows.
struct SelectionLensAnchor: PreferenceKey {
    static let defaultValue: Anchor<CGRect>? = nil
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) { value = value ?? nextValue() }
}

/// One piece of Liquid Glass behind the rows, sliding to the selected one. Rows draw above it, so their titles never
/// pass through the glass (a lens per row smeared both titles while it re-formed). Solid style: a wash.
struct SelectionLens: View {
    @Environment(BrowserEnvironment.self) private var env
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let rect: CGRect?
    @State private var shown: CGRect?

    var body: some View {
        let solid = env.runtime.settings.string(SurfaceStyle.settingKey) == SurfaceStyle.solid.rawValue
        let frame = rect ?? shown ?? .zero
        Group {
            if solid {
                Design.itemShape.fill(Design.Fill.selection)
            } else {
                Color.clear.glassSurface(in: Design.itemShape)
            }
        }
        .frame(width: frame.width, height: frame.height)
        .offset(x: frame.minX, y: frame.minY)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .opacity(rect == nil ? 0 : 1)
        .allowsHitTesting(false)
        .onChange(of: rect, initial: true) { if let rect { shown = rect } }
        // A lens that wasn't showing appears where it is; one that was slides.
        .animation(shown == nil ? nil : reduceMotion ? Design.Motion.reduced : Design.Motion.selection, value: rect)
    }
}

/// A space sliding out keeps showing the tab it had selected (the window's selection has moved to the next space).
struct FrozenSelection: Equatable {
    let id: UUID?
}

extension EnvironmentValues {
    @Entry var frozenSelection: FrozenSelection?
}
