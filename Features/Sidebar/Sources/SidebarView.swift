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
            SlotHost(.sidebarAddress, window: window)
                .padding(.horizontal, 8)
            FavoritesGrid(window: window, model: model)
                .padding(.horizontal, 8)
            SlotHost(.sidebarTop, window: window)
                .padding(.horizontal, 8)
            SpacePager(window: window, model: model)
            footer
        }
        .padding(.bottom, 6)
        .background { WindowDragArea() }
        .overlay(alignment: .trailing) { SidebarResizeHandle(window: window) }
    }

    private var header: some View {
        HStack(spacing: 2) {
            Spacer(minLength: 74)  // traffic lights live here (full-size content view)
            SlotHost(.sidebarHeader, window: window)
            SidebarIconButton(systemImage: "sidebar.left", help: "Toggle Sidebar (⌘S)") {
                try? env.runtime.commands.run("sidebar.toggle", window: window)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 40)
    }

    private var footer: some View {
        HStack(spacing: 6) {
            SlotHost(.sidebarFooter, window: window)
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
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
        return ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 4) {
                SpaceTitle(space: space)
                TabList(window: window, model: model, container: .section(space.id, .pinned))
                SectionDivider(window: window)
                NewTabRow(window: window)
                TabList(window: window, model: model, container: .section(space.id, .today))
                Color.clear.frame(height: 40)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { env.runtime.openTab(nil, in: window) }  // Arc: double-click empty space
                    .dropDestination(for: String.self) { items, _ in
                        guard let id = items.first.flatMap(UUID.init(uuidString:)) else { return false }
                        return SidebarLogic.drop(id, into: .section(space.id, .today), store: store)
                    }
            }
            .padding(.horizontal, 8)
        }
        .scrollIndicators(.never)
    }
}

struct SpaceTitle: View {
    let space: Space
    var body: some View {
        HStack(spacing: 6) {
            SpaceIcon(icon: space.icon).frame(width: 14, height: 14)
            Text(space.name).font(.system(size: 12, weight: .semibold))
            Spacer()
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 6)
        .padding(.top, 4)
    }
}

struct SpaceIcon: View {
    let icon: String
    var body: some View {
        if icon.unicodeScalars.first?.properties.isEmojiPresentation == true || icon.count == 1 {
            Text(icon).font(.system(size: 12))
        } else {
            Image(systemName: icon).resizable().scaledToFit()
        }
    }
}

struct SectionDivider: View {
    @Environment(BrowserEnvironment.self) private var env
    let window: BrowserWindowState
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            Rectangle().fill(.separator).frame(height: 1)
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
        .padding(.horizontal, 6)
        .contentShape(Rectangle())
        .onHover { h in withAnimation(.easeOut(duration: 0.15)) { hovering = h } }
    }
}

struct NewTabRow: View {
    @Environment(BrowserEnvironment.self) private var env
    let window: BrowserWindowState
    @State private var hovering = false

    var body: some View {
        Button {
            if env.runtime.commands.isHandled("command-bar.open") {
                try? env.runtime.commands.run("command-bar.open", window: window)
            } else {
                env.runtime.openTab(nil, in: window)
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "plus").font(.system(size: 12, weight: .semibold)).frame(width: 16)
                Text("New Tab").font(.system(size: 13))
                Spacer()
            }
            .padding(.horizontal, 8)
            .frame(height: 30)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(hovering ? Color.primary.opacity(0.06) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .onHover { hovering = $0 }
    }
}

struct SidebarIconButton: View {
    let systemImage: String
    let help: String
    var isEnabled = true
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 28, height: 28)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(hovering && isEnabled ? Color.primary.opacity(0.08) : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(isEnabled ? .secondary : .tertiary)
        .disabled(!isEnabled)
        .help(help)
        .onHover { hovering = $0 }
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
                    SidebarView(window: window, model: model)
                        .frame(width: window.sidebarWidth)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .shadow(color: .black.opacity(0.25), radius: 18, x: 4)
                        .padding(6)
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
