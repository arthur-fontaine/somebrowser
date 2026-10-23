import AppKit
import Foundation

/// What features may ask of the window layer. Implemented by the Shell; nil in unit tests.
public protocol ShellServices: AnyObject {
    var keyWindowState: BrowserWindowState? { get }
    @discardableResult
    func openWindow(spaceID: UUID?, isPrivate: Bool, initialURL: URL?, placement: BrowserWindowPlacement?) -> BrowserWindowState
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
        openWindow(spaceID: spaceID, isPrivate: isPrivate, initialURL: initialURL, placement: nil)
    }
}

/// Where a new window shows and the Spaces it joins, applied as the window is created: one moved before it first shows
/// stays on the active Space (measured on macOS 27), so it couldn't join another app's full-screen Space.
public struct BrowserWindowPlacement {
    /// Screen coordinates; nil leaves it to the shell.
    public var frame: CGRect?
    public var level: NSWindow.Level
    public var collectionBehavior: NSWindow.CollectionBehavior

    public init(frame: CGRect? = nil, level: NSWindow.Level = .normal, collectionBehavior: NSWindow.CollectionBehavior = [.fullScreenPrimary]) {
        self.frame = frame
        self.level = level
        self.collectionBehavior = collectionBehavior
    }
}
