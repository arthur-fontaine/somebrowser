import AppKit
import BrowserCore
import SwiftUI

public final class MiniWindowFeature: BrowserFeature {
    let context: FeatureContext
    static let flag = "mini-window"

    public init(context: FeatureContext) { self.context = context }

    public func activate() {
        context.runtime.externalURLHandlers.append { [weak self] url in
            guard let self, self.context.settings.bool("mini-window.forExternalLinks"), self.context.shell != nil else { return false }
            // Links already open somewhere just focus that tab (Arc).
            if let existing = self.context.tabs.tabs(matching: url).first,
               let w = self.context.windows.first(where: { $0.selectedTabID == existing.id }) {
                self.context.shell?.nsWindow(for: w)?.makeKeyAndOrderFront(nil)
                return true
            }
            self.open(url)
            return true
        }
        // `url` argument: open that page (Air Traffic Control routes links here).
        context.commands.handle("mini-window.new") { [weak self] inv in _ = self?.open(inv.arguments["url"].flatMap(URL.init(string:))) }
        context.commands.handle("mini-window.move-to-main", isEnabled: { inv in inv.window?.flags.contains(Self.flag) ?? false }) { [weak self] inv in
            guard let w = inv.window else { return }
            self?.moveToMain(w)
        }
        let runtime = context.runtime
        context.ui.contribute(.toolbar, id: "mini-window.bar") { window in
            if window.flags.contains(Self.flag) { MiniWindowBar(window: window, runtime: runtime) }
        }
        context.events.subscribe(WindowClosed.self) { [weak self] e in self?.windowClosed(e.windowID) }
        context.events.subscribe(TabsClosed.self) { [weak self] e in self?.tabsClosed(e.tabIDs) }
    }

    private var miniTabs: [UUID: [NodeID]] = [:]

    @discardableResult
    func open(_ url: URL?) -> BrowserWindowState? {
        guard let shell = context.shell else { return nil }
        // Quick Look: where the pointer is, above every app, full-screen ones included.
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main
        let placement = BrowserWindowPlacement(frame: screen.map { Self.frame(around: mouse, in: $0.visibleFrame) }, level: .floating,
                                        collectionBehavior: [.canJoinAllSpaces, .fullScreenAuxiliary], isPanel: true)
        let window = shell.openWindow(spaceID: nil, isPrivate: false, initialURL: nil, placement: placement)
        window.flags.insert(Self.flag)
        window.isSidebarVisible = false
        window.allowsSidebar = false
        window.cardInset = QuickLook.cardInset
        window.cardRadius = QuickLook.cardRadius
        let tab = context.runtime.openTab(url, in: window)
        miniTabs[window.id] = [tab.id]
        return window
    }

    /// Centered on the pointer, kept whole on its screen.
    static func frame(around point: CGPoint, in screen: CGRect) -> CGRect {
        let size = CGSize(width: min(960, screen.width * 0.6), height: min(720, screen.height * 0.75))
        let x = min(max(point.x - size.width / 2, screen.minX), screen.maxX - size.width)
        let y = min(max(point.y - size.height / 2, screen.minY), screen.maxY - size.height)
        return CGRect(origin: CGPoint(x: x, y: y), size: size)
    }

    /// ⌘⌥O: the page becomes a normal tab in the most recent main window.
    func moveToMain(_ mini: BrowserWindowState) {
        guard let tabID = mini.selectedTabID else { return }
        miniTabs[mini.id] = nil
        let main = context.windows.first { !$0.flags.contains(Self.flag) && $0 !== mini }
            ?? context.shell?.openWindow(spaceID: nil, isPrivate: false, initialURL: nil)
        guard let main else { return }
        try? context.tabs.move(tabID, to: .section(main.spaceID, .today), at: 0)
        context.runtime.select(tabID, in: main)
        context.shell?.closeWindow(mini)
        context.shell?.nsWindow(for: main)?.makeKeyAndOrderFront(nil)
    }

    /// Closing a mini window closes its page unless it was moved.
    private func windowClosed(_ id: UUID) {
        for tabID in miniTabs.removeValue(forKey: id) ?? [] { context.runtime.close(tabID, includingDescendants: true) }
    }

    /// ⌘W closes the page and its window with it (the window would show another of the space's tabs).
    private func tabsClosed(_ ids: [NodeID]) {
        for (windowID, tabs) in miniTabs where tabs.contains(where: ids.contains) {
            miniTabs[windowID] = nil
            if let window = context.windows.first(where: { $0.id == windowID }) { context.shell?.closeWindow(window) }
        }
    }
}

/// Quick Look's measurements (macOS 27, 2× captures), from the window's edges.
enum QuickLook {
    static let barHeight: CGFloat = 38
    static let cardInset: CGFloat = 6
    static let cardRadius: CGFloat = 14
    static let closeCenter: CGFloat = 18
    /// 8 pt past the close glyph's 12 pt circle, as Quick Look's title sits past its last glyph.
    static let titleLeading: CGFloat = 32
    static let glyph: CGFloat = 20
    static let buttonHeight: CGFloat = 22
    static let trailing: CGFloat = 14
}

/// Quick Look's bar: close, the site, then Share and the way out to the main window.
struct MiniWindowBar: View {
    let window: BrowserWindowState
    let runtime: BrowserRuntime

    var body: some View {
        let live = runtime.selectedTab(in: window)?.live
        let url = live?.url
        HStack(spacing: 0) {
            Glyph(systemImage: "xmark.circle.fill", help: "Close (⌘W)") { runtime.shell?.closeWindow(window) }
                .padding(.leading, QuickLook.closeCenter - QuickLook.glyph / 2)
            Text(url?.host() ?? "")
                .font(.system(size: 13, weight: .bold))
                .lineLimit(1)
                .padding(.leading, QuickLook.titleLeading - QuickLook.closeCenter - QuickLook.glyph / 2)
            Spacer(minLength: Design.Space.block)
            if let url {
                ShareLink(item: url) {
                    Image(systemName: "square.and.arrow.up").font(.system(size: 14))
                        .frame(width: QuickLook.glyph, height: QuickLook.glyph)
                        .contentShape(Rectangle())
                }
                .buttonStyle(GlyphStyle())
                .help("Share")
                .padding(.trailing, QuickLook.trailing)
            }
            Button("Open in Main Window") { try? runtime.commands.run("mini-window.move-to-main", window: window) }
                .buttonStyle(CapsuleStyle())
                .help("Move to Main Window (⌘⌥O)")
        }
        .padding(.trailing, QuickLook.trailing)
        .frame(height: QuickLook.barHeight)
        .background { Color.clear.contentShape(Rectangle()).gesture(WindowDragGesture()) }
        // The bar spans the window, over the card's margin.
        .padding([.top, .horizontal], -window.cardInset)
    }
}

private struct Glyph: View {
    let systemImage: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage).font(.system(size: 13))
                .frame(width: QuickLook.glyph, height: QuickLook.glyph)
                .contentShape(Rectangle())
        }
        .buttonStyle(GlyphStyle())
        .help(help)
        .accessibilityLabel(help)
    }
}

/// Grey glyphs, darker under the pointer and pressed.
private struct GlyphStyle: ButtonStyle {
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(configuration.isPressed || hovering ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
            .onHover { hovering = $0 }
    }
}

/// "Open with Preview": text on a grey capsule.
private struct CapsuleStyle: ButtonStyle {
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13))
            .padding(.horizontal, 12)
            .frame(height: QuickLook.buttonHeight)
            .background(Capsule().fill(.primary.opacity(configuration.isPressed ? 0.16 : hovering ? 0.11 : 0.07)))
            .contentShape(Capsule())
            .onHover { hovering = $0 }
    }
}
