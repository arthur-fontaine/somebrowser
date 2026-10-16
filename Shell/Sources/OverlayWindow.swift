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
    }
}
