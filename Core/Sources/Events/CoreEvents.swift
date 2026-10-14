import Foundation

// Events published by Core. Features publish their own events from their own modules.

public struct TabSelected: BrowserEvent {
    public let windowID: UUID
    public let tabID: NodeID?
    public let previousTabID: NodeID?
    public init(windowID: UUID, tabID: NodeID?, previousTabID: NodeID?) {
        self.windowID = windowID
        self.tabID = tabID
        self.previousTabID = previousTabID
    }
}

public struct TabOpened: BrowserEvent {
    public let tabID: NodeID
    /// Tab whose page opened this one (link, popup), if any.
    public let openerID: NodeID?
    public let disposition: OpenDisposition?
    public init(tabID: NodeID, openerID: NodeID?, disposition: OpenDisposition?) {
        self.tabID = tabID
        self.openerID = openerID
        self.disposition = disposition
    }
}

public struct TabsClosed: BrowserEvent {
    public let tabIDs: [NodeID]
    public init(tabIDs: [NodeID]) {
        self.tabIDs = tabIDs
    }
}

public struct TabNavigated: BrowserEvent {
    public let tabID: NodeID
    public let url: URL
    public let isPrivate: Bool
    public init(tabID: NodeID, url: URL, isPrivate: Bool) {
        self.tabID = tabID
        self.url = url
        self.isPrivate = isPrivate
    }
}

public struct TabFinishedLoading: BrowserEvent {
    public let tabID: NodeID
    public init(tabID: NodeID) {
        self.tabID = tabID
    }
}

public struct TabLiveChanged: BrowserEvent {
    public let tabID: NodeID
    /// true when an engine page was created, false when discarded.
    public let isLive: Bool
    public init(tabID: NodeID, isLive: Bool) {
        self.tabID = tabID
        self.isLive = isLive
    }
}

public struct WindowOpened: BrowserEvent {
    public let windowID: UUID

    public init(windowID: UUID) {
        self.windowID = windowID
    }
}
public struct WindowClosed: BrowserEvent {
    public let windowID: UUID

    public init(windowID: UUID) {
        self.windowID = windowID
    }
}

public struct SpaceSwitched: BrowserEvent {
    public let windowID: UUID
    public let spaceID: UUID
    /// -1 left, +1 right, 0 jump (for slide animations).
    public let direction: Int
    public init(windowID: UUID, spaceID: UUID, direction: Int) {
        self.windowID = windowID
        self.spaceID = spaceID
        self.direction = direction
    }
}

/// Ask whoever shows toasts to display a transient message.
public struct ToastRequested: BrowserEvent {
    public let message: String
    public let systemImage: String?
    public let windowID: UUID?
    public let actionTitle: String?
    public let action: (() -> Void)?

    public init(message: String, systemImage: String? = nil, windowID: UUID? = nil, actionTitle: String? = nil, action: (() -> Void)? = nil) {
        self.message = message
        self.systemImage = systemImage
        self.windowID = windowID
        self.actionTitle = actionTitle
        self.action = action
    }
}

public struct AppWillTerminate: BrowserEvent { public init() {} }
public struct EngineReady: BrowserEvent { public init() {} }
