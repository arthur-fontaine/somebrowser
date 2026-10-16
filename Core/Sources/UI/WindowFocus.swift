/// Which window a key window belongs to. Under Chromium the page, overlays and Chrome's popups are windows of their
/// own above the browser window; to the user they are one window, active while any of them has keyboard focus.
public enum WindowFocus {
    public static func isActive<W: AnyObject>(_ window: W, keyWindow: W?, parent: (W) -> W?) -> Bool {
        var w = keyWindow
        while let current = w {
            if current === window { return true }
            w = parent(current)
        }
        return false
    }
}
