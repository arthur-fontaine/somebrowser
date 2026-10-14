import AppKit
import Foundation

/// What features may ask of the window layer. Implemented by the Shell; nil in unit tests.
public protocol ShellServices: AnyObject {
    var keyWindowState: BrowserWindowState? { get }
    @discardableResult
    func openWindow(spaceID: UUID?, isPrivate: Bool, initialURL: URL?) -> BrowserWindowState
    func closeWindow(_ window: BrowserWindowState)
    func nsWindow(for window: BrowserWindowState) -> NSWindow?
    func showSettings(paneID: String?)
    /// Moves keyboard focus to the page.
    func focusContent(in window: BrowserWindowState)
    /// Content area geometry changed (sidebar toggled…): engines reposition child windows.
    func contentLayoutDidChange(in window: BrowserWindowState)
}
