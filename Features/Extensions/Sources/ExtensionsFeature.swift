import AppKit
import BrowserCore
import SwiftUI

/// Chrome extensions from the sidebar. The engine runs actions through Chrome's own toolbar machinery, so
/// popups, `action.onClicked` and `activeTab` behave as in Chrome (docs/decisions/0003).
public final class ExtensionsFeature: BrowserFeature {
    let context: FeatureContext
    let model = ExtensionsModel()
    static let manageURL = URL(string: "chrome://extensions/")!
    static let storeURL = URL(string: "https://chromewebstore.google.com/")!

    public init(context: FeatureContext) {
        self.context = context
    }

    var engine: EngineExtensions? { context.engine as? EngineExtensions }

    public func activate() {
        guard let engine else { return }  // engines without Chrome extensions: no buttons, commands stay unhandled
        model.extensions = engine.installedExtensions
        engine.onExtensionsChanged = { [weak self] in self?.model.extensions = self?.engine?.installedExtensions ?? [] }

        context.commands.handle("extensions.menu") { [weak self] inv in self?.showMenu(in: inv.window) }
        context.commands.handle("extensions.run") { [weak self] inv in
            if let id = inv.arguments["id"] { self?.run(id, in: inv.window) }
        }
        context.commands.handle("extensions.manage") { [weak self] inv in self?.open(Self.manageURL, in: inv.window) }
        context.commands.handle("extensions.store") { [weak self] inv in self?.open(Self.storeURL, in: inv.window) }

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
        guard let engine, let tab = liveTab(in: window) else { return }
        engine.runAction(of: id, in: tab)
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

@Observable
final class ExtensionsModel {
    var extensions: [BrowserExtension] = []
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
                    ForEach(model.pinned) { ext in ExtensionIcon(ext: ext) { run(ext.id) } }
                }
                ExtensionIcon(ext: nil, action: menu)
            }
        }
    }
}

struct ExtensionIcon: View {
    let ext: BrowserExtension?
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Group {
                if let ext, let icon = ext.icon, let image = NSImage(contentsOf: icon) {
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
        .help(ext?.name ?? "Extensions (⌘⇧E)")
        .onHover { hovering = $0 }
    }
}
