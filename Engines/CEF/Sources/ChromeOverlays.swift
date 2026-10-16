import AppKit
import CEFBridge

/// Chrome's own non-interactive windows over pages never show; the browser has its own for each. The one left once
/// Chrome's status bubble is off (a browser setting): the "download started" animation, an image flying from the page
/// to Chrome's (hidden) downloads button, while the Downloads feature shows the download. No rebuild of Chromium.
@MainActor
final class ChromeOverlays {
    private var observer: NSObjectProtocol?

    init() {
        observer = NotificationCenter.default.addObserver(forName: .CEFChromeWindowShown, object: nil, queue: .main) { note in
            guard let window = note.object as? NSWindow else { return }
            MainActor.assumeIsolated {
                if Self.isPageOverlay(window) { window.orderOut(nil) }
            }
        }
    }

    /// A Chrome window over a page that takes no clicks and holds no text or button: only an image.
    static func isPageOverlay(_ window: NSWindow) -> Bool {
        guard window.ignoresMouseEvents, window.frame.width <= 128, window.frame.height <= 128,
              let parent = window.parent, NSStringFromClass(type(of: parent)) == "CefNSWindow" else { return false }
        var content = false
        ChromeDialogs.walk(window) { _, role, _ in
            if ["AXStaticText", "AXButton", "AXLink", "AXHeading", "AXTextField", "AXWebArea"].contains(role) { content = true }
        }
        return !content
    }
}
