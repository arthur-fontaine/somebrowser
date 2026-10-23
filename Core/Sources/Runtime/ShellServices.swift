import AppKit
import Foundation

/// What features may ask of the window layer. Implemented by the Shell; nil in unit tests.
public protocol ShellServices: AnyObject {
    var keyWindowState: BrowserWindowState? { get }
    /// `prepare` sets the window up before it shows: where it goes, its level, the Spaces it joins.
    @discardableResult
    func openWindow(spaceID: UUID?, isPrivate: Bool, initialURL: URL?, prepare: ((NSWindow) -> Void)?) -> BrowserWindowState
    func closeWindow(_ window: BrowserWindowState)
    func nsWindow(for window: BrowserWindowState) -> NSWindow?
    func showSettings(paneID: String?)
    /// Moves keyboard focus to the page.
    func focusContent(in window: BrowserWindowState)
    /// Content area geometry changed (sidebar toggled…): engines reposition child windows.
    func contentLayoutDidChange(in window: BrowserWindowState)
}

public extension ShellServices {
    @discardableResult
    func openWindow(spaceID: UUID?, isPrivate: Bool, initialURL: URL?) -> BrowserWindowState {
        openWindow(spaceID: spaceID, isPrivate: isPrivate, initialURL: initialURL, prepare: nil)
    }
}
