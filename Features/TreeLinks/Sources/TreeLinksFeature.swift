import AppKit
import BrowserCore
import SwiftUI

public final class TreeLinksFeature: BrowserFeature {
    let context: FeatureContext

    public init(context: FeatureContext) { self.context = context }

    public func activate() {
        context.hooks.addNavigationPolicy { [weak self] action in self?.decide(action) ?? .allow }
        context.commands.handle("tree-links.toggle") { [weak self] inv in
            guard let self else { return }
            let on = !self.context.settings.bool("tree-links.enabled")
            self.context.settings.set("tree-links.enabled", on)
            self.context.notify(on ? "Links open as child tabs" : "Links open in place", systemImage: "arrow.triangle.branch", window: inv.window)
        }
        let runtime = context.runtime
        context.ui.contribute(.contentOverlay, id: "tree-links.hover-box", order: 20) { window in
            LinkHoverBox(window: window, runtime: runtime)
        }
    }

    var exclusions: [String] {
        context.settings.string("tree-links.exclusions").split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty }
    }

    static func matches(_ site: String?, _ hosts: [String]) -> Bool {
        guard let site else { return false }
        return hosts.contains { site == $0 || site.hasSuffix("." + $0) }
    }

    /// A link click becomes a child tab (Horse), unless it stays on the same page, targets an app-like
    /// site, or the tab opens links in place. A form sent (a search, an upload such as Google Lens's) stays in place:
    /// its data can't be sent again from a new tab. Claude's tabs too: Claude follows its own clicks in the tab it
    /// drives, and a child tab would be one it doesn't know.
    func decide(_ action: NavigationAction) -> NavigationPolicy {
        guard context.settings.bool("tree-links.enabled"), action.isMainFrame, action.userGesture, !action.isFormSubmission,
              ["http", "https"].contains(action.url.scheme ?? ""),
              let source = action.sourceTab, let current = source.state.url,
              let tab = context.tabs.allTabs.first(where: { $0.engineTab === source }), !tab.opensLinksInPlace,
              context.tabs.spaceID(of: tab.id).flatMap(context.tabs.space)?.kind != .claude
        else { return .allow }
        // In-page anchors and identical URLs navigate normally.
        if Self.samePage(current, action.url) { return .allow }
        let from = SiteSettingsStore.site(for: current), to = SiteSettingsStore.site(for: action.url)
        if Self.matches(from, exclusions) { return .allow }
        if !context.settings.bool("tree-links.sameSite"), from == to { return .allow }
        if context.settings.bool("tree-links.focusExisting"),
           let existing = context.tabs.tabs(matching: action.url).first(where: { $0.id != tab.id }),
           let window = context.windows.first(where: { $0.selectedTabID == tab.id }) {
            DispatchQueue.main.async { [weak self] in self?.context.runtime.select(existing.id, in: window) }
            return .handled
        }
        return .openInNewTab(action.url)
    }

    static func samePage(_ a: URL, _ b: URL) -> Bool {
        var ca = URLComponents(url: a, resolvingAgainstBaseURL: false), cb = URLComponents(url: b, resolvingAgainstBaseURL: false)
        ca?.fragment = nil
        cb?.fragment = nil
        return ca?.url == cb?.url
    }
}

/// Horse's link box / Arc's status pill: where a hovered link goes, and whether it's already open.
struct LinkHoverBox: View {
    let window: BrowserWindowState
    let runtime: BrowserRuntime
    @State private var shown: URL?
    @State private var task: Task<Void, Never>?

    var body: some View {
        let hovered = runtime.selectedTab(in: window)?.live?.hoveredLink
        VStack {
            Spacer()
            HStack {
                if let url = shown, runtime.settings.bool("tree-links.hoverBox") {
                    let existing = runtime.tabs.tabs(matching: url).first
                    HStack(spacing: 6) {
                        if existing != nil {
                            Image(systemName: "arrow.uturn.right.circle.fill").foregroundStyle(.tint)
                        }
                        VStack(alignment: .leading, spacing: 1) {
                            if let existing { Text("Already open · \(existing.displayTitle)").font(.system(size: 11, weight: .semibold)).lineLimit(1) }
                            Text(Self.display(url)).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .glassSurface(in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .shadow(color: .black.opacity(0.15), radius: 4, y: 1)
                    .frame(maxWidth: 420, alignment: .leading)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
                Spacer()
            }
            .padding(8)
        }
        .allowsHitTesting(false)
        .animation(.easeOut(duration: 0.15), value: shown)
        .onChange(of: hovered) { _, new in
            task?.cancel()
            // Small delay so sweeping across links doesn't flicker; hiding is immediate.
            if new == nil { shown = nil; return }
            task = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(120))
                if !Task.isCancelled { shown = new }
            }
        }
    }

    static func display(_ url: URL) -> String {
        var s = url.absoluteString
        for p in ["https://", "http://", "www."] where s.hasPrefix(p) { s.removeFirst(p.count) }
        return s
    }
}
