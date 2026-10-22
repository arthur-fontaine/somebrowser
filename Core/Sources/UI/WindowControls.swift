import AppKit
import SwiftUI

/// The traffic lights, drawn where the window's own can't show: the floating sidebar sits in a window above the page,
/// over the browser window's titlebar. They act on the browser window and light up together under the pointer, as the
/// real ones do. Lay out `width` wide; the red light is centered `Design.Grid.iconCenter − leading` in.
public struct WindowControls: NSViewRepresentable {
    public static let width: CGFloat = 72
    let leading: CGFloat

    /// `leading`: where this view starts from the sidebar's edge, so the lights land where the docked sidebar has them.
    public init(leading: CGFloat) { self.leading = leading }

    public func makeNSView(context: Context) -> Group { Group(redCenter: Design.Grid.iconCenter - leading) }
    public func updateNSView(_ view: Group, context: Context) {}

    public final class Group: NSView {
        private let buttons: [NSButton]
        private let redCenter: CGFloat
        private var inside = false

        init(redCenter: CGFloat) {
            self.redCenter = redCenter
            let style: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable]
            buttons = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].compactMap { NSWindow.standardWindowButton($0, for: style) }
            super.init(frame: .zero)
            for (button, action) in zip(buttons, [#selector(NSWindow.performClose(_:)), #selector(NSWindow.performMiniaturize(_:)),
                                                  #selector(NSWindow.toggleFullScreen(_:))]) {  // as the window's own green light
                button.action = action
                addSubview(button)
            }
            addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
            // Their window is rarely key (the page or the browser window is), so nothing redraws them as key moves around.
            for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
                NotificationCenter.default.addObserver(self, selector: #selector(keyDidMove), name: name, object: nil)
            }
        }

        @objc private func keyDidMove() {
            for button in buttons { button.needsDisplay = true }
        }

        public required init?(coder: NSCoder) { fatalError() }

        public override var isFlipped: Bool { true }

        public override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            // The browser window: this one's parent when drawn in the overlay above its page.
            let target = window?.parent ?? window
            for button in buttons { button.target = target }
        }

        public override func layout() {
            super.layout()
            // As far apart as the window's own (it changes with the system); the red one on the sidebar's icon column.
            let target = window?.parent ?? window
            let close = target?.standardWindowButton(.closeButton), minimize = target?.standardWindowButton(.miniaturizeButton)
            let spacing = close.flatMap { c in minimize.map { $0.frame.minX - c.frame.minX } } ?? 23
            for (i, button) in buttons.enumerated() {
                let size = button.frame.size
                button.setFrameOrigin(NSPoint(x: redCenter - size.width / 2 + CGFloat(i) * spacing, y: (bounds.height - size.height) / 2))
            }
        }

        public override func mouseEntered(with event: NSEvent) { setInside(true) }
        public override func mouseExited(with event: NSEvent) { setInside(false) }

        private func setInside(_ value: Bool) {
            inside = value
            for button in buttons { button.needsDisplay = true }
        }

        /// AppKit asks a traffic light's superview whether the pointer is over the group, to show the glyphs on all three.
        @objc func _mouseInGroup(_ button: NSButton) -> Bool { inside }
    }
}
