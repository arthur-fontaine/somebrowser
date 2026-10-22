import AppKit
import BrowserCore
import SwiftUI

/// For engines whose pages are child windows (CEF): a transparent window above the pages that hosts the
/// `overlay` and `contentOverlay` slots. Transparent pixels let mouse events through to the page below.
final class OverlayWindow: NSPanel {
    init(state: BrowserWindowState, runtime: BrowserRuntime) {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        identifier = ShellOverlay.windowIdentifier
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        becomesKeyOnlyIfNeeded = true
        let hosting = NSHostingView(rootView: OverlayLayer(window: state).environment(BrowserEnvironment(runtime: runtime)))
        hosting.sizingOptions = []
        contentView = hosting
    }

    /// Text fields in overlays (command bar, find) need key status.
    override var canBecomeKey: Bool { true }

    /// Controls drawn here (the floating sidebar's traffic lights) look active while the browser window is.
    @objc var _hasActiveAppearance: Bool {
        guard let parent else { return false }
        return ShellWindow.isActive(parent, keyWindow: NSApp.keyWindow)
    }
    /// The traffic lights draw in colour from these (AppKit answers from this panel's own key and main state), not
    /// `_hasActiveAppearance`: they went grey while the page had key. Their state comes from the first two, their
    /// drawing from the key appearance.
    @objc(_hasActiveAppearanceForStandardWindowButton:)
    func _hasActiveAppearance(for button: NSWindow.ButtonType) -> Bool { _hasActiveAppearance }
    @objc var _hasMainAppearance: Bool { _hasActiveAppearance }
    @objc var _hasKeyAppearance: Bool { _hasActiveAppearance }
    @objc var hasKeyAppearance: Bool { _hasActiveAppearance }

    /// As the browser window does (`ShellWindow.sendEvent`): a click here while its page has key is no first click, or
    /// the floating sidebar's address took two.
    override func sendEvent(_ event: NSEvent) {
        if [.leftMouseDown, .rightMouseDown, .otherMouseDown].contains(event.type), !isKeyWindow, let parent,
           let key = NSApp.keyWindow, key !== self, ShellWindow.isActive(parent, keyWindow: key) {
            makeKey()
        }
        super.sendEvent(event)
    }

    /// Their green light is the browser window's, which goes full screen: AppKit asks the window they're in which glyph
    /// to draw ("+" otherwise).
    @objc var _zoomButtonIsFullScreenButton: Bool { parent != nil }
    override var canBecomeMain: Bool { false }
}

struct OverlayLayer: View {
    let window: BrowserWindowState

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear.allowsHitTesting(false)
            ZStack { SlotHost(.contentOverlay, window: window) }
                .frame(width: window.contentFrame.width, height: window.contentFrame.height)
                .clipShape(RoundedRectangle(cornerRadius: Design.cardRadius, style: .continuous))
                .offset(x: window.contentFrame.minX, y: window.contentFrame.minY)
            SlotHost(.overlay, window: window)
        }
        .ignoresSafeArea()
        // As in the browser window (`BrowserWindowView`): this panel is rarely key, its page or the browser window is, and
        // SwiftUI drew everything here inactive then (the floating sidebar's glass flat).
        .environment(\.controlActiveState, window.isKeyWindow ? .key : .inactive)
    }
}
