import AppKit
import BrowserCore

/// Shows the selected page by attaching its page window as a child window glued to the content area.
/// Switching tabs = detach one child, attach another (~1.5 ms, docs/decisions/0002).
final class CEFViewport: EngineViewport {
    private weak var container: NSView?
    private(set) var presentedTab: EngineTab?

    /// Pages from the protected-media engine (WebKit) show through its own viewport in the same container.
    private let makeAlternate: (NSView) -> EngineViewport?
    private var alternate: EngineViewport?

    init(container: NSView, alternate: @escaping (NSView) -> EngineViewport? = { _ in nil }) {
        self.container = container
        self.makeAlternate = alternate
    }

    private var page: CEFPage? { presentedTab as? CEFPage }

    /// A page is shown by one viewport at a time (a window's content and a split-view pane can trade pages): taking a
    /// page from another viewport makes it forget the page, and a viewport only detaches pages it still shows.
    func present(_ tab: EngineTab?) {
        let next = tab as? CEFPage
        if let current = page, current !== next, current.presenter === self, let w = current.window {
            w.parent?.removeChildWindow(w)
            w.orderOut(nil)
            current.presenter = nil
        }
        if let next, let other = next.presenter, other !== self { other.forget(next) }
        presentedTab = tab
        next?.presenter = self
        attach()
        if let tab, next == nil {
            if alternate == nil, let container { alternate = makeAlternate(container) }
            alternate?.present(tab)
        } else {
            alternate?.present(nil)
        }
    }

    private func forget(_ page: CEFPage) {
        if presentedTab === page { presentedTab = nil }
    }

    private func attach() {
        guard let page, let w = page.window, let container, let host = container.window else { return }
        style(w, radius: container.layer?.cornerRadius ?? Design.cardRadius)
        // A child window keeps its own Spaces, and the window it's in can't go where it can't: one floating over other
        // apps' full-screen Spaces stayed on the browser's.
        w.level = host.level
        w.collectionBehavior = host.collectionBehavior.subtracting(.fullScreenPrimary).union(.fullScreenAuxiliary)
        w.setFrame(screenRect(of: container), display: false)
        if w.parent !== host {
            w.parent?.removeChildWindow(w)
            host.addChildWindow(w, ordered: .above)
        }
        w.orderFront(nil)
        keepOverlaysOnTop(host)
        if host.isKeyWindow { focusContent() }
    }

    /// `radius`: the content area's, which the window it's in sets.
    private func style(_ w: NSWindow, radius: CGFloat) {
        guard let view = w.contentView, view.layer?.cornerRadius != radius else { return }
        // macOS rounds every window with its own radius (about 17 pt here), wider than the card's, so a crescent of
        // the card's background showed in each corner (dark in Dark). The window's corner is set to the card's.
        Self.setWindowCornerRadius(w, radius)
        view.wantsLayer = true
        view.layer?.cornerRadius = radius
        view.layer?.cornerCurve = .continuous
        view.layer?.masksToBounds = true
        w.hasShadow = false
        w.isOpaque = false
        w.backgroundColor = .clear
    }

    /// AppKit's own (private) window corner: no public API sets it.
    private static func setWindowCornerRadius(_ w: NSWindow, _ radius: CGFloat) {
        let selector = NSSelectorFromString("_setCornerRadius:")
        guard w.responds(to: selector) else { return }
        typealias Setter = @convention(c) (AnyObject, Selector, CGFloat) -> Void
        unsafeBitCast(w.method(for: selector), to: Setter.self)(w, selector, radius)
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
        alternate?.layoutDidChange()
        guard let page, let w = page.window, let container else { return }
        if container.window == nil || container.isHiddenOrHasHiddenAncestor {
            w.orderOut(nil)
            return
        }
        style(w, radius: container.layer?.cornerRadius ?? Design.cardRadius)
        let target = screenRect(of: container)
        if w.frame != target { w.setFrame(target, display: true) }
        if !w.isVisible { attach() }
    }

    func focusContent() {
        if page == nil { alternate?.focusContent() }
        guard let page, let w = page.window else { return }
        w.makeKey()
        page.tab?.setFocus(true)
    }

    func tearDown() {
        present(nil)
        alternate?.tearDown()
    }
}
