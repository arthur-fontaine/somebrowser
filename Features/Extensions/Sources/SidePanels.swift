import AppKit
import BrowserCore
import SwiftUI

/// Extension side panels (`chrome.sidePanel`). Chrome draws them in its own window chrome, which pages here don't have,
/// so the panel's page is shown in a pane beside the content: one panel per window, opened from the extension's button
/// (when the extension asks for that) or `extensions.side-panel`.
final class SidePanels {
    let context: FeatureContext
    let model = SidePanelModel()

    init(context: FeatureContext) {
        self.context = context
    }

    func activate(icons: @escaping (String) -> NSImage?) {
        context.events.subscribe(WindowClosed.self) { [weak self] e in self?.close(windowID: e.windowID) }
        let model = self.model, runtime = context.runtime
        context.ui.contribute(.contentTrailing, id: "extensions.side-panel", order: 10) { [weak self] window in
            SidePanelPane(model: model, window: window, runtime: runtime, icon: icons, close: { self?.close(windowID: window.id) })
        }
    }

    func isOpen(_ extensionID: String, in window: BrowserWindowState) -> Bool { model.panels[window.id]?.extensionID == extensionID }

    func toggle(_ ext: BrowserExtension, in window: BrowserWindowState) {
        if isOpen(ext.id, in: window) { return close(windowID: window.id) }
        guard let url = ext.sidePanelPath.flatMap(ext.page) else { return }
        close(windowID: window.id)
        let page = context.engine.makeTab(EngineTabRequest(url: url, isPrivate: window.isPrivate))
        let links = PanelLinks(runtime: context.runtime, windowID: window.id) { [weak self] in self?.close(windowID: window.id) }
        page.delegate = links
        model.panels[window.id] = SidePanel(extensionID: ext.id, title: ext.name, page: page, links: links)
        model.lastUsed = ext.id
    }

    func close(windowID: UUID) {
        model.panels.removeValue(forKey: windowID)?.page.close()
    }
}

struct SidePanel {
    let extensionID: String
    let title: String
    let page: EngineTab
    /// The page's delegate (pages hold theirs weakly).
    let links: PanelLinks
}

@Observable
final class SidePanelModel {
    /// Window → its open panel.
    var panels: [UUID: SidePanel] = [:]
    var lastUsed: String?
}

/// Pages the panel opens become tabs of its window; `window.close()` closes the panel.
final class PanelLinks: EngineTabDelegate {
    weak var runtime: BrowserRuntime?
    let windowID: UUID
    let onClose: () -> Void

    init(runtime: BrowserRuntime, windowID: UUID, onClose: @escaping () -> Void) {
        self.runtime = runtime
        self.windowID = windowID
        self.onClose = onClose
    }

    func engineTab(_ tab: EngineTab, didOpen newTab: EngineTab, url: URL?, disposition: OpenDisposition, userGesture: Bool) {
        guard let runtime, let window = runtime.window(windowID) else { return newTab.close() }
        runtime.adopt(newTab, in: window, select: disposition != .backgroundTab)
    }

    func engineTabDidRequestClose(_ tab: EngineTab) { onClose() }
}

struct SidePanelPane: View {
    let model: SidePanelModel
    let window: BrowserWindowState
    let runtime: BrowserRuntime
    let icon: (String) -> NSImage?
    let close: () -> Void

    var body: some View {
        if let panel = model.panels[window.id] {
            VStack(spacing: 4) {
                HStack(spacing: 6) {
                    if let image = icon(panel.extensionID) {
                        Image(nsImage: image).resizable().interpolation(.high).frame(width: 14, height: 14)
                    } else {
                        Image(systemName: "puzzlepiece.extension")
                    }
                    Text(panel.title).fontWeight(.medium).lineLimit(1)
                    Spacer(minLength: 4)
                    Button(action: close) { Image(systemName: "xmark") }.buttonStyle(.borderless).help("Close Side Panel")
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .frame(height: 22)
                PanelPage(page: panel.page, runtime: runtime)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .shadow(color: .black.opacity(0.18), radius: 1.5, y: 0.5)
            }
            .frame(width: 360)
            .padding(.leading, 6)
            .transition(.move(edge: .trailing).combined(with: .opacity))
        }
    }
}

/// The panel page in its own engine viewport.
struct PanelPage: NSViewRepresentable {
    let page: EngineTab
    let runtime: BrowserRuntime

    final class Container: NSView {
        var viewport: EngineViewport?
        override func layout() { super.layout(); viewport?.layoutDidChange() }
    }

    func makeNSView(context: Context) -> Container {
        let v = Container()
        v.wantsLayer = true
        v.layer?.cornerRadius = 10
        v.layer?.masksToBounds = true
        DispatchQueue.main.async {
            let viewport = runtime.engine.makeViewport(in: v)
            v.viewport = viewport
            viewport.present(page)
        }
        return v
    }

    func updateNSView(_ v: Container, context: Context) {
        if let viewport = v.viewport, viewport.presentedTab !== page { viewport.present(page) }
    }

    static func dismantleNSView(_ v: Container, coordinator: ()) {
        v.viewport?.tearDown()
    }
}
