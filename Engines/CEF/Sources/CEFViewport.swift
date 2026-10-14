import AppKit
import BrowserCore

/// Shows the selected page by attaching its page window as a child window glued to the content area.
/// Switching tabs = detach one child, attach another (~1.5 ms, docs/decisions/0002).
final class CEFViewport: EngineViewport {
    private weak var container: NSView?
    private(set) var presentedTab: EngineTab?
    static let cornerRadius: CGFloat = 10

    init(container: NSView) { self.container = container }

    private var page: CEFPage? { presentedTab as? CEFPage }

    func present(_ tab: EngineTab?) {
        let next = tab as? CEFPage
        if let current = page, current !== next, let w = current.window {
            w.parent?.removeChildWindow(w)
            w.orderOut(nil)
        }
        presentedTab = tab
        attach()
    }

    private func attach() {
        guard let page, let w = page.window, let container, let host = container.window else { return }
        style(w)
        w.setFrame(screenRect(of: container), display: false)
        if w.parent !== host {
            w.parent?.removeChildWindow(w)
            host.addChildWindow(w, ordered: .above)
        }
        w.orderFront(nil)
        keepOverlaysOnTop(host)
        if host.isKeyWindow { focusContent() }
    }

    private func style(_ w: NSWindow) {
        guard let view = w.contentView, view.layer?.cornerRadius != Self.cornerRadius else { return }
        view.wantsLayer = true
        view.layer?.cornerRadius = Self.cornerRadius
        view.layer?.cornerCurve = .continuous
        view.layer?.masksToBounds = true
        w.hasShadow = false
        w.isOpaque = false
        w.backgroundColor = .clear
    }

    /// Shell overlay windows (command bar, toasts…) must stay above pages.
    private func keepOverlaysOnTop(_ host: NSWindow) {
        for child in host.childWindows ?? [] where child.identifier == ShellOverlay.windowIdentifier {
            host.removeChildWindow(child)
            host.addChildWindow(child, ordered: .above)
        }
    }

    private func screenRect(of view: NSView) -> NSRect {
        guard let w = view.window else { return .zero }
        return w.convertToScreen(view.convert(view.bounds, to: nil))
    }

    func layoutDidChange() {
        guard let page, let w = page.window, let container else { return }
        if container.window == nil || container.isHiddenOrHasHiddenAncestor {
            w.orderOut(nil)
            return
        }
        let target = screenRect(of: container)
        if w.frame != target { w.setFrame(target, display: true) }
        if !w.isVisible { attach() }
    }

    func focusContent() {
        guard let page, let w = page.window else { return }
        w.makeKey()
        page.tab?.setFocus(true)
    }

    func tearDown() { present(nil) }
}
