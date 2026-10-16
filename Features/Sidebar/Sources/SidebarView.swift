import AppKit
import BrowserCore
import SwiftUI

struct SidebarView: View {
    @Environment(BrowserEnvironment.self) private var env
    let window: BrowserWindowState
    let model: SidebarModel

    var body: some View {
        VStack(spacing: 6) {
            header
            if !window.isLocked {  // a locked private space shows nothing of its pages
                SlotHost(.sidebarAddress, window: window)
                    .padding(.horizontal, Design.Grid.edge)
            }
            FavoritesGrid(window: window, model: model)
                .padding(.horizontal, Design.Grid.edge)
            SlotHost(.sidebarTop, window: window)
                .padding(.horizontal, Design.Grid.edge)
            SpacePager(window: window, model: model)
            footer
        }
        // The footer's bottom edge on the page card's.
        .padding(.bottom, Design.windowInset)
        .background { WindowDragArea() }
        .overlay(alignment: .trailing) { SidebarResizeHandle(window: window) }
    }

    /// The traffic lights' row: the shell centers them in it (the system's toolbar height).
    private var header: some View {
        GlassGroup(spacing: 6) {
            HStack(spacing: 6) {
                Spacer(minLength: 72)  // traffic lights live here (full-size content view)
                SlotHost(.sidebarHeader, window: window)
                SidebarIconButton(systemImage: "sidebar.left", help: "Toggle Sidebar (⌘S)") {
                    try? env.runtime.commands.run("sidebar.toggle", window: window)
                }
                .glassControl(in: Circle())
            }
        }
        .padding(.horizontal, Design.Grid.edge)
        .frame(height: Design.Size.header)
    }

    private var footer: some View {
        GlassGroup(spacing: 6) {
            HStack(spacing: 6) {
                SlotHost(.sidebarFooter, window: window)
            }
        }
        .padding(.horizontal, Design.Grid.edge)
        .frame(height: Design.Size.control)
    }
}

/// The sidebar in its column, sliding while it arrives or leaves (`SidebarModel.toggle`); under Reduce Motion it fades.
struct DockedSidebar: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let window: BrowserWindowState
    let model: SidebarModel

    var body: some View {
        let slide = model.slide[window.id] ?? 0
        SidebarView(window: window, model: model)
            .offset(x: reduceMotion ? 0 : slide * window.sidebarWidth)
            .opacity(reduceMotion ? 1 + slide : 1)
    }
}

/// One space's tabs (pinned, divider, new tab, today). Horizontal two-finger swipes page between spaces.
struct SpacePager: View {
    @Environment(BrowserEnvironment.self) private var env
    let window: BrowserWindowState
    let model: SidebarModel

    var body: some View {
        let store = env.runtime.tabs
        let offset = model.swipeOffset[window.id] ?? 0
        GeometryReader { geo in
            ZStack {
                if let space = store.space(window.spaceID) {
                    SpaceTabs(window: window, model: model, space: space)
                        .offset(x: offset)
                        .id(space.id)
                        .transition(.asymmetric(insertion: .opacity, removal: .opacity))
                }
                if offset != 0, let neighbor = neighbor(offset: offset) {
                    SpaceTabs(window: window, model: model, space: neighbor)
                        .offset(x: offset + (offset < 0 ? geo.size.width : -geo.size.width))
                        .allowsHitTesting(false)
                }
            }
            .clipped()
            .background(SwipeCatcher(window: window, model: model, width: geo.size.width, runtime: env.runtime))
        }
    }

    private func neighbor(offset: CGFloat) -> Space? {
        let spaces = env.runtime.tabs.spaces
        guard let i = spaces.firstIndex(where: { $0.id == window.spaceID }) else { return nil }
        let j = offset < 0 ? i + 1 : i - 1
        return spaces.indices.contains(j) ? spaces[j] : nil
    }
}

struct SpaceTabs: View {
    @Environment(BrowserEnvironment.self) private var env
    let window: BrowserWindowState
    let model: SidebarModel
    let space: Space

    var body: some View {
        let store = env.runtime.tabs
        _ = store.structureVersion
        if space.kind == .private && window.isLocked {
            return AnyView(LockedSpace(window: window))
        }
        let hasPinned = !space.pinned.isEmpty || model.dragging != nil
        return AnyView(ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 4) {
                if hasPinned {  // the pinned section (and its divider) only once there's something to keep
                    TabList(window: window, model: model, container: .section(space.id, .pinned))
                    SectionDivider(window: window)
                }
                NewTabRow(window: window, model: model)
                TabList(window: window, model: model, container: .section(space.id, .today))
                Color.clear.frame(height: 40)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { env.runtime.openTab(nil, in: window) }  // Arc: double-click empty space
                    .dropDestination(for: String.self) { items, _ in
                        guard let id = items.first.flatMap(UUID.init(uuidString:)) else { return false }
                        return env.runtime.sidebarHistory.move(id) { SidebarLogic.drop(id, into: .section(space.id, .today), store: store) }
                    }
            }
            .backgroundPreferenceValue(SelectionLensAnchor.self) { anchor in
                GeometryReader { geo in SelectionLens(rect: anchor.map { geo[$0] }) }
            }
            .padding(.horizontal, Design.Grid.edge)
        }
        .scrollIndicators(.never))
    }
}

/// A locked private space shows none of its tabs, only a way in (Touch ID, through `spaces.unlock`).
struct LockedSpace: View {
    @Environment(BrowserEnvironment.self) private var env
    let window: BrowserWindowState

    var body: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "lock.fill").font(.system(size: 22)).foregroundStyle(.secondary)
            Text("Private tabs are locked").font(.callout).foregroundStyle(.secondary)
            if env.runtime.commands.isHandled("spaces.unlock") {
                Button("Unlock") { try? env.runtime.commands.run("spaces.unlock", window: window) }
                    .buttonStyle(.glass)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}

struct SectionDivider: View {
    @Environment(BrowserEnvironment.self) private var env
    let window: BrowserWindowState
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            Rectangle().fill(Design.Fill.hairline).frame(height: 1)
            if hovering, let space = env.runtime.tabs.space(window.spaceID), !space.today.isEmpty {
                Button {
                    withAnimation(.spring(duration: 0.4, bounce: 0.1)) {
                        try? env.runtime.commands.run("tabs.clear-today", window: window)
                    }
                } label: {
                    Label("Clear", systemImage: "arrow.down").font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .transition(.opacity.combined(with: .move(edge: .trailing)))
            }
        }
        .frame(height: 18)
        .padding(.horizontal, Design.Grid.iconInset)
        .contentShape(Rectangle())
        .onHover { h in withAnimation(Design.Motion.hover) { hovering = h } }
    }
}

struct NewTabRow: View {
    @Environment(BrowserEnvironment.self) private var env
    let window: BrowserWindowState
    let model: SidebarModel
    @State private var hovering = false

    var body: some View {
        Button {
            if env.runtime.commands.isHandled("command-bar.open") {
                try? env.runtime.commands.run("command-bar.open", window: window)
            } else {
                env.runtime.openTab(nil, in: window)
            }
        } label: {
            // On the rows' grid: icon column, then the title column.
            HStack(spacing: Design.Grid.iconToText) {
                Image(systemName: "plus").font(.system(size: 12, weight: .semibold)).frame(width: Design.Size.favicon)
                Text("New Tab").font(.system(size: 13))
                Spacer()
            }
            .padding(.leading, Design.Grid.iconInset)
            .frame(height: model.rowHeight)
            .background(Design.itemShape.fill(hovering ? Design.Fill.hover : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .onHover { hovering = $0 }
    }
}

/// An icon button of the sidebar's; its glass comes from where it sits (alone, or in a group).
struct SidebarIconButton: View {
    let systemImage: String
    let help: String
    var isEnabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .medium))
                .frame(width: Design.Size.control, height: Design.Size.control)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(isEnabled ? .primary : .tertiary)
        .disabled(!isEnabled)
        .help(help)
    }
}

/// Empty sidebar space moves the window (Arc).
struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
    final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }
        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 {
                window?.performZoom(nil)
            } else {
                window?.performDrag(with: event)
            }
        }
    }
}

/// Drag the sidebar edge to resize; double-click resets; dragging far left hides it (Arc).
struct SidebarResizeHandle: View {
    let window: BrowserWindowState
    @State private var startWidth: CGFloat?

    var body: some View {
        Rectangle()
            .fill(Color.clear)
            .frame(width: 6)
            .contentShape(Rectangle())
            .onHover { inside in if inside { NSCursor.columnResize.push() } else { NSCursor.pop() } }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { v in
                        let start = startWidth ?? window.sidebarWidth
                        startWidth = start
                        let w = start + v.translation.width
                        if w < 120 { window.isSidebarVisible = false; return }
                        window.sidebarWidth = min(480, max(190, w))
                    }
                    .onEnded { _ in startWidth = nil }
            )
            .onTapGesture(count: 2) { withAnimation(.spring(duration: 0.3)) { window.sidebarWidth = 260 } }
    }
}

/// When the sidebar is hidden, the left window edge reveals it as a floating panel (Horse's "Shelf").
struct SidebarPeekOverlay: View {
    @Environment(BrowserEnvironment.self) private var env
    let window: BrowserWindowState
    let model: SidebarModel
    @State private var hideTask: Task<Void, Never>?

    var body: some View {
        if !window.isSidebarVisible, env.runtime.settings.bool("sidebar.peekOnEdgeHover") {
            HStack(spacing: 0) {
                if window.isSidebarPeeking {
                    let slab = RoundedRectangle(cornerRadius: Design.cardRadius, style: .continuous)
                    SidebarView(window: window, model: model)
                        .environment(\.isOnGlass, true)
                        .frame(width: window.sidebarWidth)
                        .glassSurface(in: slab)
                        .clipShape(slab)
                        .shadow(color: .black.opacity(0.22), radius: 24, y: 10)
                        .padding(Design.windowInset)
                        .transition(.move(edge: .leading).combined(with: .opacity))
                        .onHover { inside in
                            hideTask?.cancel()
                            if !inside { scheduleHide() }
                        }
                } else {
                    Color.clear
                        .frame(width: 8)
                        .contentShape(Rectangle())
                        .onHover { inside in
                            guard inside else { return }
                            hideTask?.cancel()
                            withAnimation(.spring(duration: 0.28, bounce: 0.1)) { window.isSidebarPeeking = true }
                            window.titlebarRequests.insert("sidebar.peek")
                        }
                }
                Spacer(minLength: 0)
            }
            .frame(maxHeight: .infinity)
        }
    }

    private func scheduleHide() {
        hideTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            withAnimation(.spring(duration: 0.28, bounce: 0.05)) { window.isSidebarPeeking = false }
            window.titlebarRequests.remove("sidebar.peek")
        }
    }
}
