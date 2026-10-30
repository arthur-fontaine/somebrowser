import AppKit
import BrowserCore
import SwiftUI
import UniformTypeIdentifiers

struct SidebarView: View {
    @Environment(BrowserEnvironment.self) private var env
    @Environment(\.isFloatingSidebar) private var isFloating
    let window: BrowserWindowState
    let model: SidebarModel

    var body: some View {
        VStack(spacing: 0) {
            // Its controls end 8 pt above the address field, the outer margin.
            header
            VStack(spacing: Design.Space.block) {
                if !window.isLocked {  // a locked private space shows nothing of its pages
                    SlotHost(.sidebarAddress, window: window)
                        .padding(.horizontal, Design.Grid.edge)
                        .onDrop(of: [UTType.text], delegate: RevealFavorites(model: model, store: env.runtime.tabs))
                }
                FavoritesGrid(window: window, model: model)
                    .padding(.horizontal, Design.Grid.edge)
                SlotHost(.sidebarTop, window: window)
                    .padding(.horizontal, Design.Grid.edge)
                SpacePager(window: window, model: model)
                footer
            }
        }
        // The footer's bottom edge on the page card's.
        .padding(.bottom, Design.windowInset)
        .background { WindowDragArea() }
        .overlay(alignment: .trailing) { SidebarResizeHandle(window: window) }
    }

    /// The traffic lights' row: the shell centers them in it (the system's toolbar height).
    private var header: some View {
        // The traffic lights live here (full-size content view). The floating sidebar covers the window's own, and in full
        // screen they're in the menu bar's titlebar, out of sight: then it draws its own in their place.
        let drawsLights = isFloating || window.isFullscreen
        return GlassGroup(spacing: 6) {
            HStack(spacing: Design.Space.block) {
                if drawsLights { WindowControls(leading: Design.Grid.edge).frame(width: WindowControls.width, height: Design.Size.header) }
                Spacer(minLength: drawsLights ? Design.Space.block : 72)
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
            FooterLayout {
                HStack(spacing: Design.Space.block) {
                    SidebarMenuButton(window: window)
                    SlotHost(.sidebarFooter, window: window)
                }
                // Each in a stack, so the layout always gets its three parts, empty or not.
                HStack(spacing: 0) { SlotHost(.sidebarFooterCenter, window: window) }
                HStack(spacing: Design.Space.block) { SlotHost(.sidebarFooterTrailing, window: window) }
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, Design.Grid.edge)
        .frame(height: Design.Size.control)
    }
}

/// The footer's one leading button (as in Safari's and Oleksii's sidebars): a menu of new windows, what features list
/// there (History, Archive, iCloud Tabs) and Settings, so the footer keeps room for the space switcher however many
/// features are on. Their panels pop up above it.
struct SidebarMenuButton: View {
    @Environment(BrowserEnvironment.self) private var env
    let window: BrowserWindowState

    var body: some View {
        let runtime = env.runtime
        Menu {
            if runtime.commands.isHandled("tabs.new-window") {
                Button("New Window", systemImage: "macwindow.badge.plus") { try? runtime.commands.run("tabs.new-window", window: window) }
                Divider()
            }
            SlotHost(.sidebarMenu, window: window)
            Divider()
            Button("Settings…", systemImage: "gearshape") { runtime.shell?.showSettings(paneID: nil) }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 15, weight: .medium))
                .frame(width: Design.Size.control, height: Design.Size.control)
                .contentShape(Circle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .foregroundStyle(.primary)
        .glassControl(in: Circle())
        .help("More")
        .accessibilityLabel("More")
    }
}

/// The footer: buttons at its ends, the center on the sidebar's axis (the address field's and the lens's), moved
/// aside only if it would come within 8 pt of the buttons.
struct FooterLayout: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        CGSize(width: proposal.replacingUnspecifiedDimensions().width, height: Design.Size.control)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 3 else { return }
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        subviews[0].place(at: CGPoint(x: bounds.minX, y: bounds.midY), anchor: .leading, proposal: .unspecified)
        subviews[2].place(at: CGPoint(x: bounds.maxX, y: bounds.midY), anchor: .trailing, proposal: .unspecified)
        let gap = Design.Space.block
        let lowest = bounds.minX + (sizes[0].width > 0 ? sizes[0].width + gap : 0)
        let highest = bounds.maxX - (sizes[2].width > 0 ? sizes[2].width + gap : 0) - sizes[1].width
        let x = min(max(bounds.midX - sizes[1].width / 2, lowest), max(lowest, highest))
        subviews[1].place(at: CGPoint(x: x, y: bounds.midY), anchor: .leading, proposal: .unspecified)
    }
}

/// The sidebar in its column. It slides in and out in Core Animation (on the render server), so the slide keeps
/// moving while the page's resize holds the main thread, which a SwiftUI animation would not; under Reduce Motion it
/// fades. Its own hosting view carries the environment the window's would.
struct DockedSidebar: View {
    @Environment(BrowserEnvironment.self) private var env
    let window: BrowserWindowState
    let model: SidebarModel

    var body: some View {
        SidebarSlideHost(window: window, model: model, env: env, isActive: window.isKeyWindow, slide: model.slides[window.id])
    }
}

struct SidebarSlideHost: NSViewRepresentable {
    let window: BrowserWindowState
    let model: SidebarModel
    let env: BrowserEnvironment
    let isActive: Bool
    let slide: SidebarModel.Slide?

    func makeNSView(context: Context) -> SlideView {
        let view = SlideView()
        // Made to slide in: it starts out of view (the slide is added before its first frame).
        if let slide, slide.to == 0 { view.current = -1 }
        return view
    }

    func updateNSView(_ view: SlideView, context: Context) {
        view.hosting.rootView = AnyView(SidebarView(window: window, model: model)
            .ignoresSafeArea()  // under the titlebar, as the window's own content is
            .environment(env)
            .environment(\.controlActiveState, isActive ? .key : .inactive))
        view.width = window.sidebarWidth  // its bounds are still empty when it's made
        if let slide, slide.id != view.lastSlide { view.run(slide) }
    }

    final class SlideView: NSView {
        let hosting = NSHostingView(rootView: AnyView(EmptyView()))
        var lastSlide: UUID?

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            hosting.sizingOptions = []
            hosting.safeAreaRegions = []
            hosting.autoresizingMask = [.width, .height]
            hosting.frame = bounds
            addSubview(hosting)
        }

        required init?(coder: NSCoder) { fatalError() }

        /// The offset the last slide ends at, in sidebar widths.
        var current: CGFloat = 0
        var width: CGFloat = 0

        func run(_ slide: SidebarModel.Slide) {
            lastSlide = slide.id
            guard let layer = hosting.layer else { slide.finished?(); return }
            // From wherever it is now (a slide reversed halfway carries on from there).
            let from: CGFloat
            if layer.animation(forKey: "slide") != nil,
               let presented = layer.presentation()?.value(forKeyPath: slide.fades ? "opacity" : "transform.translation.x") as? CGFloat {
                from = slide.fades ? presented - 1 : (width > 0 ? presented / width : current)
            } else {
                from = current
            }
            current = slide.to
            let animation = Self.animation(fades: slide.fades, from: from, to: slide.to, width: width)
            animation.duration = slide.duration
            let c = slide.curve
            animation.timingFunction = CAMediaTimingFunction(controlPoints: c[0], c[1], c[2], c[3])
            CATransaction.begin()
            CATransaction.setCompletionBlock { [weak self] in
                MainActor.assumeIsolated {
                    guard self?.lastSlide == slide.id else { return }
                    if slide.to == 0 { self?.hosting.layer?.removeAnimation(forKey: "slide") }
                    slide.finished?()
                }
            }
            layer.add(animation, forKey: "slide")
            CATransaction.commit()
        }

        private static func animation(fades: Bool, from: CGFloat, to: CGFloat, width: CGFloat) -> CABasicAnimation {
            let a = CABasicAnimation(keyPath: fades ? "opacity" : "transform.translation.x")
            a.fromValue = fades ? 1 + from : from * width
            a.toValue = fades ? 1 + to : to * width
            a.fillMode = .both
            a.isRemovedOnCompletion = false
            return a
        }
    }
}

/// One space's tabs (pinned, divider, new tab, today). Horizontal two-finger swipes page between spaces; switching
/// any other way (the switcher, ⌥⌘→, a private tab) slides the same way, the next space coming from its side.
struct SpacePager: View {
    @Environment(BrowserEnvironment.self) private var env
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let window: BrowserWindowState
    let model: SidebarModel
    /// The space sliding out, and the direction (1: to the next space, on the right).
    @State private var leaving: (id: UUID, direction: CGFloat)?
    @State private var progress: CGFloat = 1

    var body: some View {
        let store = env.runtime.tabs
        let offset = model.swipeOffset[window.id] ?? 0
        GeometryReader { geo in
            let width = geo.size.width
            // Under Reduce Motion the spaces cross-fade instead.
            let direction = reduceMotion ? 0 : leaving?.direction ?? 0
            ZStack {
                if let space = store.space(window.spaceID) {
                    SpaceTabs(window: window, model: model, space: space)
                        .offset(x: offset + direction * width * (1 - progress))
                        .opacity(reduceMotion && leaving != nil ? progress : 1)
                        .id(space.id)
                }
                if let leaving, let space = store.space(leaving.id) {
                    SpaceTabs(window: window, model: model, space: space)
                        .environment(\.frozenSelection, FrozenSelection(id: window.mru.first { store.spaceID(of: $0) == leaving.id }))
                        .offset(x: -direction * width * progress)
                        .opacity(reduceMotion ? 1 - progress : 1)
                        .allowsHitTesting(false)
                }
                if offset != 0, let neighbor = neighbor(offset: offset) {
                    SpaceTabs(window: window, model: model, space: neighbor)
                        .offset(x: offset + (offset < 0 ? width : -width))
                        .allowsHitTesting(false)
                }
            }
            .clipped()
            .background(SwipeCatcher(window: window, model: model, width: width, runtime: env.runtime))
        }
        .onChange(of: window.spaceID) { old, new in
            model.clearPicks(in: window)
            slide(from: old, to: new)
        }
    }

    private func slide(from old: UUID, to new: UUID) {
        // A swipe has already moved the spaces with the fingers.
        if model.swiped.remove(window.id) != nil { return }
        let ids = env.runtime.tabs.spaces.map(\.id)
        guard let i = ids.firstIndex(of: old), let j = ids.firstIndex(of: new) else { return }
        var still = Transaction()
        still.disablesAnimations = true
        withTransaction(still) {
            leaving = (old, j > i ? 1 : -1)
            progress = 0
        }
        withAnimation(reduceMotion ? Design.Motion.reduced : Design.Motion.space) { progress = 1 } completion: {
            if leaving?.id == old { leaving = nil }
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
        let hasPinned = !space.pinned.isEmpty
        let today = Container.section(space.id, .today)
        return AnyView(ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: Design.Space.row) {
                if hasPinned {  // the pinned section (and its divider) only once there's something to keep
                    TabList(window: window, model: model, container: .section(space.id, .pinned))
                    let pinned = Container.section(space.id, .pinned)
                    SectionDivider(window: window)
                        // Pinned's end, marked under its last row.
                        .onDrop(of: [UTType.text], delegate: SidebarDropDelegate(model: model, owner: .end(pinned), env: env) { _, dragged in
                            SidebarLogic.endPlacement(rows: TabList.rows(pinned, in: window, store: store), in: pinned, dragged: dragged, store: store)
                        })
                }
                if space.kind.isUserDriven { NewTabRow(window: window, model: model) }
                TabList(window: window, model: model, container: .section(space.id, .today))
                Color.clear.frame(height: 40)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) {  // Arc: double-click empty space
                        if space.kind.isUserDriven { env.runtime.openTab(nil, in: window) }
                    }
                    // Today's end, marked under its last row.
                    .onDrop(of: [UTType.text], delegate: SidebarDropDelegate(model: model, owner: .end(today), env: env) { _, dragged in
                        SidebarLogic.endPlacement(rows: TabList.rows(today, in: window, store: store), in: today, dragged: dragged, store: store)
                    })
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
        // 12 + 1 + 12 from the rows around it (the stack's own 2 pt gaps included).
        .frame(height: 2 * (Design.Space.divider - Design.Space.row) + 1)
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
        .overlay(alignment: .topLeading) { DropMark(target: model.dropTarget, owner: .newTab, rows: [], rowHeight: model.rowHeight) }
        .onDrop(of: [UTType.text], delegate: SidebarDropDelegate(model: model, owner: .newTab, env: env) { [window, model, env] point, dragged in
            SidebarLogic.newTabPlacement(atY: point.y, rowHeight: model.rowHeight, space: window.spaceID, dragged: dragged, store: env.runtime.tabs)
        })
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
            // The browser window, also from the floating sidebar's window above its page (it moves with it).
            let target = window?.parent ?? window
            if event.clickCount == 2 {
                target?.performZoom(nil)
            } else {
                target?.performDrag(with: event)
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
                        // At least the header's controls clear of the traffic lights.
                        window.sidebarWidth = min(480, max(216, w))
                    }
                    .onEnded { _ in startWidth = nil }
            )
            .onTapGesture(count: 2) { withAnimation(.spring(duration: 0.3)) { window.sidebarWidth = 260 } }
    }
}

/// The browser window's own surface (the `background` slot): the floating sidebar sits on it as the docked one does.
struct WindowSurfaceBackground: View {
    @Environment(BrowserEnvironment.self) private var env
    let window: BrowserWindowState

    var body: some View {
        if env.runtime.ui.views(for: "background").isEmpty {
            Color(nsColor: .windowBackgroundColor)
        } else {
            SlotHost("background", window: window)
        }
    }
}

/// When the sidebar is hidden, the left window edge reveals it as a floating panel (Horse's "Shelf").
struct SidebarPeekOverlay: View {
    @Environment(BrowserEnvironment.self) private var env
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let window: BrowserWindowState
    let model: SidebarModel
    @State private var hideTask: Task<Void, Never>?

    var body: some View {
        // Also when something asked for it (editing the address with the sidebar hidden), edge hover or not.
        if window.allowsSidebar, !window.isSidebarVisible, env.runtime.settings.bool("sidebar.peekOnEdgeHover") || window.isSidebarPeeking {
            HStack(spacing: 0) {
                if window.isSidebarPeeking {
                    let slab = RoundedRectangle(cornerRadius: Design.cardRadius, style: .continuous)
                    // On the window's own surface, as the docked sidebar is, so its controls are Liquid Glass as there
                    // (a glass slab would have made them washes: glass can't sample glass).
                    SidebarView(window: window, model: model)
                        .environment(\.isFloatingSidebar, true)
                        .frame(width: window.sidebarWidth)
                        .background { WindowSurfaceBackground(window: window) }
                        .clipShape(slab)
                        .shadow(color: .black.opacity(0.22), radius: 24, y: 10)
                        .padding(Design.windowInset)
                        // Solid as it slides (fading, the page and its rows showed through each other).
                        .transition(reduceMotion ? .opacity : .move(edge: .leading))
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
                        }
                }
                Spacer(minLength: 0)
            }
            .frame(maxHeight: .infinity)
            // What held it closed with the pointer elsewhere: no hover report comes then.
            .onChange(of: window.sidebarPeekHolds.isEmpty) { if window.sidebarPeekHolds.isEmpty { scheduleHide() } }
        }
    }

    /// From the window's frame: hover reports also come when key moves to an overlay, the pointer still over it.
    private var pointerOverPanel: Bool {
        guard let frame = env.runtime.shell?.nsWindow(for: window)?.frame else { return false }
        let pointer = NSEvent.mouseLocation
        return frame.contains(pointer) && pointer.x <= frame.minX + window.sidebarWidth + 2 * Design.windowInset
    }

    private func scheduleHide() {
        hideTask?.cancel()
        hideTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(350))
            // Not under what was opened from it (the address editor, the extensions panel…): it goes when that does.
            guard !Task.isCancelled, window.sidebarPeekHolds.isEmpty, !pointerOverPanel else { return }
            withAnimation(.spring(duration: 0.28, bounce: 0.05)) { window.isSidebarPeeking = false }
        }
    }
}
