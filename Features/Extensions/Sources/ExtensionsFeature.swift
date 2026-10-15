import AppKit
import BrowserCore
import SwiftUI

/// Chrome extensions from the sidebar. The engine runs actions through Chrome's own toolbar machinery, so
/// popups, `action.onClicked` and `activeTab` behave as in Chrome (docs/decisions/0003).
public final class ExtensionsFeature: BrowserFeature {
    let context: FeatureContext
    let model = ExtensionsModel()
    let sidePanels: SidePanels
    static let manageURL = URL(string: "chrome://extensions/")!
    static let storeURL = URL(string: "https://chromewebstore.google.com/")!

    public init(context: FeatureContext) {
        self.context = context
        sidePanels = SidePanels(context: context)
    }

    var engine: EngineExtensions? { context.engine as? EngineExtensions }

    public func activate() {
        guard let engine else { return }  // engines without Chrome extensions: no buttons, commands stay unhandled
        model.extensions = engine.installedExtensions
        engine.onExtensionsChanged = { [weak self] in self?.model.extensions = self?.engine?.installedExtensions ?? [] }

        context.commands.handle("extensions.menu") { [weak self] inv in self?.showMenu(in: inv.window) }
        context.commands.handle("extensions.cycle") { [weak self] inv in self?.cyclePinned(in: inv.window) }
        context.commands.handle("extensions.run") { [weak self] inv in
            if let id = inv.arguments["id"] { self?.run(id, in: inv.window) }
        }
        context.commands.handle("extensions.manage") { [weak self] inv in self?.open(Self.manageURL, in: inv.window) }
        context.commands.handle("extensions.store") { [weak self] inv in self?.open(Self.storeURL, in: inv.window) }
        context.commands.handle("extensions.side-panel", isEnabled: { [weak self] _ in self?.model.extensions.contains { $0.sidePanelPath != nil } == true }) {
            [weak self] inv in self?.toggleSidePanel(inv.arguments["id"], in: inv.window)
        }
        sidePanels.activate { [weak model] id in model?.icons[id] }
        context.capabilities.provide(NewTabPageProvider.self, self)

        let model = self.model, settings = context.settings
        context.ui.contribute("sidebar.header", id: "extensions.buttons", order: 200) { [weak self] window in
            ExtensionButtons(model: model, showPinned: settings.bool("extensions.showPinned"),
                             run: { self?.run($0, in: window) }, menu: { self?.showMenu(in: window) })
        }
    }

    /// The selected page, loaded if it was discarded: actions always act on a live tab.
    func liveTab(in window: BrowserWindowState?) -> EngineTab? {
        guard let window, let tab = context.runtime.selectedTab(in: window) else { return nil }
        return context.runtime.live(tab)
    }

    func run(_ id: String, in window: BrowserWindowState?) {
        // Chrome would open its own side panel, which pages here can't show.
        if let window, let ext = model.extensions.first(where: { $0.id == id }), ext.opensSidePanelOnClick, ext.sidePanelPath != nil {
            return sidePanels.toggle(ext, in: window)
        }
        guard let engine, let tab = liveTab(in: window) else { return }
        engine.runAction(of: id, in: tab)
    }

    /// The given extension's panel, else the open one (closing it), else the last one used, else the first there is.
    func toggleSidePanel(_ id: String?, in window: BrowserWindowState?) {
        guard let window else { return }
        let withPanels = model.extensions.filter { $0.sidePanelPath != nil }
        let wanted = id ?? sidePanels.model.panels[window.id]?.extensionID ?? sidePanels.model.lastUsed
        guard let ext = withPanels.first(where: { $0.id == wanted }) ?? withPanels.first else { return }
        sidePanels.toggle(ext, in: window)
    }

    /// Arc's ⌘E: each press runs the next pinned extension (its popup, usually); nothing pinned: the extensions menu.
    func cyclePinned(in window: BrowserWindowState?) {
        let pinned = model.pinned
        guard !pinned.isEmpty else { return showMenu(in: window) }
        let next = pinned.firstIndex { $0.id == model.lastCycled }.map { (pinned.index(after: $0)) % pinned.count } ?? 0
        model.lastCycled = pinned[next].id
        run(pinned[next].id, in: window)
    }

    func showMenu(in window: BrowserWindowState?) {
        guard let engine, let tab = liveTab(in: window) else { return }
        if !engine.showExtensionsMenu(in: tab), let window { open(Self.manageURL, in: window) }
    }

    func open(_ url: URL, in window: BrowserWindowState?) {
        guard let window else { return }
        context.runtime.openTab(url, in: window)
    }
}

/// An extension that replaces the new tab page gets new tabs, as in Chrome (the first one, pinned first, if several do).
extension ExtensionsFeature: NewTabPageProvider {
    public func newTabPage(in window: BrowserWindowState) -> URL? {
        guard !window.isPrivate, context.settings.bool("extensions.newTabPage") else { return nil }
        return model.extensions.lazy.compactMap { ext in ext.newTabPagePath.flatMap(ext.page) }.first
    }
}

@Observable
final class ExtensionsModel {
    var extensions: [BrowserExtension] = [] {
        didSet {
            // Decoded once per change, never while the sidebar renders.
            icons = Dictionary(uniqueKeysWithValues: extensions.compactMap { ext in
                (ext.icon.flatMap { icons[ext.id] ?? NSImage(contentsOf: $0) }).map { (ext.id, $0) }
            })
        }
    }
    private(set) var icons: [String: NSImage] = [:]
    /// The pinned extension ⌘E ran last.
    var lastCycled: String?
    var pinned: [BrowserExtension] { extensions.filter(\.isPinned) }
}

/// Pinned actions and the extensions menu, next to the navigation buttons; Chrome opens popups beside them.
struct ExtensionButtons: View {
    let model: ExtensionsModel
    let showPinned: Bool
    let run: (String) -> Void
    let menu: () -> Void

    var body: some View {
        if !model.extensions.isEmpty {
            HStack(spacing: 0) {
                if showPinned {
                    ForEach(model.pinned) { ext in
                        ExtensionIcon(title: ext.name, image: model.icons[ext.id]) { run(ext.id) }
                    }
                }
                ExtensionIcon(title: "Extensions", image: nil, help: "Extensions (⌘⇧E)", action: menu)
            }
        }
    }
}

struct ExtensionIcon: View {
    let title: String
    let image: NSImage?
    var help: String?
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Group {
                if let image {
                    Image(nsImage: image).resizable().interpolation(.high).frame(width: 16, height: 16)
                } else {
                    Image(systemName: "puzzlepiece.extension").font(.system(size: 13, weight: .medium))
                }
            }
            .frame(width: 28, height: 28)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(hovering ? Color.primary.opacity(0.08) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(help ?? title)
        .accessibilityLabel(title)
        .onHover { hovering = $0 }
    }
}
