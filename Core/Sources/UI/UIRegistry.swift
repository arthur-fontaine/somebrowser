import Observation
import SwiftUI

/// Named places in the window where features contribute views. The shell only knows slot names; it never
/// knows which feature fills them. Features may define their own slots (e.g. the sidebar hosts
/// `sidebar.footer`) — any string works.
public struct SlotID: Hashable, Sendable, ExpressibleByStringLiteral, CustomStringConvertible {
    public let rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { rawValue = value }
    public var description: String { rawValue }

    /// Leading column (Arc sidebar). Usually filled by exactly one feature.
    public static let sidebar: SlotID = "sidebar"
    /// Above the web content (toolbar / address bar).
    public static let toolbar: SlotID = "toolbar"
    /// Floating above everything in the window (command bar, toasts, peek).
    public static let overlay: SlotID = "overlay"
    /// Floating above the web content only (find bar, link hover box).
    public static let contentOverlay: SlotID = "content-overlay"
    /// Shown instead of the web content when the window has no selected tab (start page).
    public static let emptyContent: SlotID = "empty-content"
    /// Beside the web content, to its right (split view): a contribution that shows nothing takes no room.
    public static let contentTrailing: SlotID = "content-trailing"
}

public struct SlotContribution: Identifiable {
    public let id: String
    public let slot: SlotID
    public let order: Int
    public let makeView: (BrowserWindowState) -> AnyView
}

/// A settings pane contributed by a feature (shown in the native Settings window).
public struct SettingsPane: Identifiable {
    public let id: String
    public let title: String
    public let systemImage: String
    public let order: Int
    public let makeView: () -> AnyView
}

@Observable
public final class UIRegistry {
    public private(set) var contributions: [SlotContribution] = []
    public private(set) var settingsPanes: [SettingsPane] = []

    public init() {}

    public func contribute<V: View>(_ slot: SlotID, id: String, order: Int = 0, @ViewBuilder _ view: @escaping (BrowserWindowState) -> V) {
        contributions.removeAll { $0.id == id }
        contributions.append(SlotContribution(id: id, slot: slot, order: order) { AnyView(view($0)) })
    }

    public func remove(id: String) { contributions.removeAll { $0.id == id } }

    public func views(for slot: SlotID) -> [SlotContribution] {
        contributions.filter { $0.slot == slot }.sorted { ($0.order, $0.id) < ($1.order, $1.id) }
    }

    public func addSettingsPane<V: View>(id: String, title: String, systemImage: String, order: Int = 100, @ViewBuilder _ view: @escaping () -> V) {
        settingsPanes.removeAll { $0.id == id }
        settingsPanes.append(SettingsPane(id: id, title: title, systemImage: systemImage, order: order) { AnyView(view()) })
        settingsPanes.sort { ($0.order, $0.title) < ($1.order, $1.title) }
    }
}

/// Renders every contribution to a slot, in order.
public struct SlotHost: View {
    @Environment(BrowserEnvironment.self) private var env
    let slot: SlotID
    let window: BrowserWindowState

    public init(_ slot: SlotID, window: BrowserWindowState) {
        self.slot = slot
        self.window = window
    }

    public var body: some View {
        ForEach(env.runtime.ui.views(for: slot)) { c in
            c.makeView(window)
        }
    }
}

/// Injected into every SwiftUI hierarchy the shell creates.
@Observable
public final class BrowserEnvironment {
    public let runtime: BrowserRuntime
    public init(runtime: BrowserRuntime) { self.runtime = runtime }
}

public extension View {
    /// Declares that this overlay takes keyboard input while it is on screen (command bar, find bar…); not when
    /// `isEnabled` is false.
    func overlayKeyboardFocus(_ id: String, in window: BrowserWindowState, isEnabled: Bool = true) -> some View {
        onAppear { if isEnabled { window.overlayFocusRequests.insert(id) } }
            .onDisappear { window.overlayFocusRequests.remove(id) }
    }
}
