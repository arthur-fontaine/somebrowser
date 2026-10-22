import AppKit
import BrowserCore
import SwiftUI

public final class NavigationFeature: BrowserFeature {
    let context: FeatureContext
    /// host → zoom factor (persisted).
    private(set) var zoomByHost: [String: Double] = [:]
    static let zoomSteps: [Double] = [0.5, 0.67, 0.75, 0.8, 0.9, 1, 1.1, 1.25, 1.5, 1.75, 2, 2.5, 3]

    public init(context: FeatureContext) {
        self.context = context
        if let data = try? Data(contentsOf: zoomFile), let map = try? JSONDecoder().decode([String: Double].self, from: data) {
            zoomByHost = map
        }
    }

    private var zoomFile: URL { context.dataDirectory.appendingPathComponent("zoom.json") }

    public func activate() {
        let c = context.commands
        let live: (CommandInvocation) -> EngineTab? = { [weak self] inv in
            guard let self, let w = inv.window else { return nil }
            return self.context.runtime.selectedTab(in: w)?.engineTab
        }
        c.handle("navigation.back", isEnabled: { live($0)?.state.canGoBack ?? false }) { live($0)?.goBack() }
        c.handle("navigation.forward", isEnabled: { live($0)?.state.canGoForward ?? false }) { live($0)?.goForward() }
        c.handle("navigation.reload", isEnabled: { live($0) != nil }) { live($0)?.reload(bypassingCache: false) }
        c.handle("navigation.hard-reload", isEnabled: { live($0) != nil }) { live($0)?.reload(bypassingCache: true) }
        c.handle("navigation.stop", isEnabled: { live($0)?.state.isLoading ?? false }) { live($0)?.stopLoading() }
        c.handle("navigation.zoom-in", isEnabled: { live($0) != nil }) { [weak self] in self?.zoom(live($0), by: 1) }
        c.handle("navigation.zoom-out", isEnabled: { live($0) != nil }) { [weak self] in self?.zoom(live($0), by: -1) }
        c.handle("navigation.zoom-reset", isEnabled: { live($0) != nil }) { [weak self] in self?.zoom(live($0), by: 0) }
        c.handle("navigation.devtools", isEnabled: { live($0) != nil }) { live($0)?.showDevTools() }
        c.handle("navigation.console", isEnabled: { live($0) != nil }) { live($0)?.showDevTools(.console) }
        c.handle("navigation.inspect-element", isEnabled: { live($0) != nil }) { live($0)?.showDevTools(.inspectElement) }
        c.handle("navigation.save-page", isEnabled: { live($0) != nil }) { live($0)?.savePage() }
        c.handle("navigation.view-source", isEnabled: { live($0)?.state.url != nil }) { [weak self] inv in
            guard let self, let w = inv.window, let url = live(inv)?.state.url else { return }
            self.context.runtime.openTab(URL(string: "view-source:\(url.absoluteString)"), in: w,
                                         placement: w.selectedTabID.map { .childOf($0) } ?? .automatic)
        }
        c.handle("navigation.copy-url", isEnabled: { live($0)?.state.url != nil }) { [weak self] inv in
            guard let self, let url = live(inv)?.state.url else { return }
            self.copy(self.cleaned(url).absoluteString)
            self.context.notify("Copied URL", systemImage: "link", window: inv.window)
        }
        c.handle("navigation.copy-markdown", isEnabled: { live($0)?.state.url != nil }) { [weak self] inv in
            guard let self, let tab = live(inv), let url = tab.state.url else { return }
            let title = tab.state.title.isEmpty ? (url.host() ?? url.absoluteString) : tab.state.title
            self.copy("[\(title.replacingOccurrences(of: "]", with: "\\]"))](\(self.cleaned(url).absoluteString))")
            self.context.notify("Copied as Markdown", systemImage: "text.badge.checkmark", window: inv.window)
        }

        // Restore remembered zoom when a site commits.
        context.events.subscribe(TabNavigated.self) { [weak self] e in
            guard let self, self.context.settings.bool("navigation.rememberZoom"),
                  let tab = self.context.tabs.tab(e.tabID)?.engineTab, let host = e.url.host() else { return }
            let z = self.zoomByHost[host] ?? 1
            if tab.zoomFactor != z { tab.zoomFactor = z }
        }

        let commands = c
        context.ui.contribute("sidebar.header", id: "navigation.buttons", order: 0) { window in
            NavigationButtons(window: window, commands: commands)
        }
        // In the address field's end, as Safari's (the header has no room once extensions are pinned).
        context.ui.contribute("address-bar.trailing", id: "navigation.reload", order: 300) { window in
            ReloadButton(window: window, commands: commands)
        }
    }

    func zoom(_ tab: EngineTab?, by direction: Int) {
        guard let tab else { return }
        let steps = Self.zoomSteps
        let current = steps.enumerated().min { abs($0.element - tab.zoomFactor) < abs($1.element - tab.zoomFactor) }?.offset ?? 5
        let next = direction == 0 ? 1 : steps[max(0, min(steps.count - 1, current + direction))]
        tab.zoomFactor = next
        if context.settings.bool("navigation.rememberZoom"), let host = tab.state.url?.host() {
            zoomByHost[host] = next == 1 ? nil : next
            try? JSONEncoder().encode(zoomByHost).write(to: zoomFile, options: .atomic)
        }
        context.notify("Zoom \(Int((next * 100).rounded()))%", systemImage: "plus.magnifyingglass")
    }

    func cleaned(_ url: URL) -> URL {
        context.settings.bool("navigation.stripTrackers") ? URLCleaner.clean(url) : url
    }

    private func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }
}

/// Arc's "Super Copy": strips the usual tracking parameters.
enum URLCleaner {
    static let exact: Set<String> = [
        "fbclid", "gclid", "gclsrc", "dclid", "msclkid", "mc_cid", "mc_eid", "igshid", "igsh", "yclid", "twclid",
        "_hsenc", "_hsmi", "mkt_tok", "oly_anon_id", "oly_enc_id", "vero_id", "wickedid", "ref_src", "ref_url",
        "si", "s_cid", "spm", "scm", "ttclid", "li_fat_id", "srsltid", "_ga", "_gl",
    ]
    static let prefixes = ["utm_", "pk_", "mtm_", "hsa_", "ga_"]

    static func clean(_ url: URL) -> URL {
        guard var c = URLComponents(url: url, resolvingAgainstBaseURL: false), let items = c.queryItems else { return url }
        let kept = items.filter { item in
            let n = item.name.lowercased()
            return !exact.contains(n) && !prefixes.contains { n.hasPrefix($0) }
        }
        c.queryItems = kept.isEmpty ? nil : kept
        return c.url ?? url
    }
}

struct NavigationButtons: View {
    @Environment(BrowserEnvironment.self) private var env
    let window: BrowserWindowState
    let commands: CommandRegistry

    var body: some View {
        let live = env.runtime.selectedTab(in: window)?.live
        // One piece of glass for the two, as the system groups a toolbar's single-action buttons. Forward stays when
        // it can't go forward, so the header never shifts.
        HStack(spacing: 0) {
            NavButton(systemImage: "chevron.left", help: "Back (⌘[)", enabled: live?.canGoBack ?? false) {
                try? commands.run("navigation.back", window: window)
            }
            NavButton(systemImage: "chevron.right", help: "Forward (⌘])", enabled: live?.canGoForward ?? false) {
                try? commands.run("navigation.forward", window: window)
            }
        }
        .glassControl(in: Capsule(), hover: false)
    }
}

/// Reload, or Stop while the page loads.
struct ReloadButton: View {
    @Environment(BrowserEnvironment.self) private var env
    let window: BrowserWindowState
    let commands: CommandRegistry

    var body: some View {
        let live = env.runtime.selectedTab(in: window)?.live
        // None on a blank tab: the extensions beside it take the field's end.
        if let live {
            FieldButton(help: live.isLoading ? "Stop" : "Reload (⌘R)") {
                try? commands.run(live.isLoading ? "navigation.stop" : "navigation.reload", window: window)
            } label: {
                Image(systemName: live.isLoading ? "xmark" : "arrow.clockwise")
                    .font(.system(size: 13, weight: .semibold))
                    .contentTransition(.symbolEffect(.replace))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct NavButton: View {
    let systemImage: String
    let help: String
    let enabled: Bool
    let action: () -> Void
    @State private var bounce = 0
    @State private var hovering = false

    var body: some View {
        Button {
            bounce += 1
            action()
        } label: {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .medium))
                .contentTransition(.symbolEffect(.replace))
                .symbolEffect(.bounce, value: bounce)
                .frame(width: Design.Size.control, height: Design.Size.control)
                .background(Circle().fill(hovering && enabled ? Design.Fill.hover : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(enabled ? .primary : .tertiary)
        .disabled(!enabled)
        .onHover { h in withAnimation(Design.Motion.hover) { hovering = h } }
        .help(help)
    }
}
