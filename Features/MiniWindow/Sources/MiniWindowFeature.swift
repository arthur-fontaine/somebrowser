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
        context.commands.handle("mini-window.new") { [weak self] _ in self?.open(nil) }
        context.commands.handle("mini-window.move-to-main", isEnabled: { inv in inv.window?.flags.contains(Self.flag) ?? false }) { [weak self] inv in
            guard let w = inv.window else { return }
            self?.moveToMain(w)
        }
        let runtime = context.runtime
        context.ui.contribute(.toolbar, id: "mini-window.bar") { window in
            if window.flags.contains(Self.flag) { MiniWindowBar(window: window, runtime: runtime) }
        }
        context.events.subscribe(WindowClosed.self) { [weak self] e in self?.windowClosed(e.windowID) }
    }

    private var miniTabs: [UUID: [NodeID]] = [:]

    @discardableResult
    func open(_ url: URL?) -> BrowserWindowState? {
        guard let shell = context.shell else { return nil }
        let window = shell.openWindow(spaceID: nil, isPrivate: false, initialURL: nil)
        window.flags.insert(Self.flag)
        window.isSidebarVisible = false
        if let ns = shell.nsWindow(for: window), let screen = ns.screen?.visibleFrame {
            let size = CGSize(width: min(960, screen.width * 0.6), height: min(720, screen.height * 0.75))
            ns.setFrame(CGRect(x: screen.midX - size.width / 2, y: screen.midY - size.height / 2, width: size.width, height: size.height), display: true)
            ns.level = .floating  // stays above full-screen apps like Little Arc
            ns.collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace]
        }
        let tab = context.runtime.openTab(url, in: window)
        miniTabs[window.id] = [tab.id]
        return window
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
}

struct MiniWindowBar: View {
    let window: BrowserWindowState
    let runtime: BrowserRuntime

    var body: some View {
        let live = runtime.selectedTab(in: window)?.live
        HStack(spacing: 8) {
            Spacer().frame(width: 70)
            Text(live?.url?.host() ?? "").font(.system(size: 12, weight: .semibold)).lineLimit(1)
            Spacer()
            Button { try? runtime.commands.run("mini-window.move-to-main", window: window) } label: {
                Label("Open in Main Window", systemImage: "rectangle.portrait.and.arrow.forward").font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.borderless)
            .help("Move to Main Window (⌘⌥O)")
        }
        .padding(.horizontal, 10)
        .frame(height: 36)
    }
}
