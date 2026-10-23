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
        // Quick Look: where the pointer is, above every app, full-screen ones included. Set before the window shows: a
        // window already on the browser's Space can't join another app's full-screen one.
        let window = shell.openWindow(spaceID: nil, isPrivate: false, initialURL: nil) { ns in
            let mouse = NSEvent.mouseLocation
            if let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main {
                ns.setFrame(Self.frame(around: mouse, in: screen.visibleFrame), display: false)
            }
            ns.level = .floating
            ns.collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace]
        }
        window.flags.insert(Self.flag)
        window.isSidebarVisible = false
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

/// Quick Look's bar: close, the site, then share and the way out to the main window.
struct MiniWindowBar: View {
    let window: BrowserWindowState
    let runtime: BrowserRuntime

    var body: some View {
        let live = runtime.selectedTab(in: window)?.live
        let url = live?.url
        HStack(spacing: Design.Space.block) {
            FieldButton(help: "Close (⌘W)", action: { runtime.shell?.closeWindow(window) }) {
                Image(systemName: "xmark").font(.system(size: 13, weight: .semibold))
            }
            // The close button's center on the traffic lights' column.
            .padding(.leading, Design.Grid.iconCenter - Design.windowInset - Design.AddressField.control / 2)
            SiteIcon(live?.favicon ?? runtime.favicons.image(for: url))
                .frame(width: Design.Size.favicon, height: Design.Size.favicon)
            Text(url?.host() ?? "").font(.system(size: 13, weight: .semibold)).lineLimit(1)
            Spacer(minLength: Design.Space.block)
            if let url {
                ShareLink(item: url) {
                    Image(systemName: "square.and.arrow.up").font(.system(size: 14, weight: .medium))
                        .frame(width: Design.AddressField.control, height: Design.AddressField.control)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help("Share")
            }
            Button("Open in Main Window") { try? runtime.commands.run("mini-window.move-to-main", window: window) }
                .buttonStyle(.glass)
                .buttonBorderShape(.capsule)
                .help("Move to Main Window (⌘⌥O)")
        }
        .padding(.trailing, Design.Space.segment)
        .frame(height: Design.Size.control)
        .background { Color.clear.contentShape(Rectangle()).gesture(WindowDragGesture()) }
    }
}
