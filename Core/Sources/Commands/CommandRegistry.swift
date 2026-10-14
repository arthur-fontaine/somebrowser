import Foundation
import Observation

/// What a command handler receives.
public struct CommandInvocation {
    /// Window the command was invoked from (key window, or nil when there is none).
    public var window: BrowserWindowState?
    /// Arguments when invoked programmatically (automation, command bar, other features).
    public var arguments: [String: String]

    public init(window: BrowserWindowState?, arguments: [String: String] = [:]) {
        self.window = window
        self.arguments = arguments
    }
}

public enum CommandError: Error, CustomStringConvertible {
    case unknown(String)
    case unhandled(String)
    case disabled(String)

    public var description: String {
        switch self {
        case .unknown(let id): "unknown command '\(id)'"
        case .unhandled(let id): "command '\(id)' has no handler (feature not activated?)"
        case .disabled(let id): "command '\(id)' is disabled right now"
        }
    }
}

/// Every user-invokable action. Commands are declared statically in feature.json (title, menu, shortcut)
/// and bound to code at activation. Menus, the command bar, shortcut settings and automation are all
/// generated from this registry — nothing lists commands by hand.
@Observable
public final class CommandRegistry {
    public private(set) var descriptors: [CommandDescriptor] = []
    @ObservationIgnored private var byID: [String: Int] = [:]
    @ObservationIgnored private var handlers: [String: (CommandInvocation) -> Void] = [:]
    @ObservationIgnored private var enablement: [String: (CommandInvocation) -> Bool] = [:]
    /// User remaps (from keyboard settings); nil value = removed.
    public private(set) var userShortcuts: [String: KeyShortcut?] = [:]
    /// Most recently run commands, newest first (command bar ranking).
    public private(set) var recent: [String] = []
    /// Resolves the invocation window when none is given (set by the shell: key window).
    @ObservationIgnored public var currentWindow: () -> BrowserWindowState? = { nil }
    /// Observers notified after any command runs (analytics-free: used by tests and the command bar).
    @ObservationIgnored public var didRun: [(String) -> Void] = []

    public init() {}

    public func register(_ descriptors: [CommandDescriptor]) {
        for d in descriptors {
            if let i = byID[d.id] { self.descriptors[i] = d; continue }
            byID[d.id] = self.descriptors.count
            self.descriptors.append(d)
        }
    }

    public func descriptor(_ id: String) -> CommandDescriptor? { byID[id].map { descriptors[$0] } }

    /// Binds code to a declared command.
    public func handle(_ id: String, isEnabled: ((CommandInvocation) -> Bool)? = nil, _ handler: @escaping (CommandInvocation) -> Void) {
        precondition(byID[id] != nil, "command '\(id)' is not declared in any feature.json")
        handlers[id] = handler
        if let isEnabled { enablement[id] = isEnabled }
    }

    public func isHandled(_ id: String) -> Bool { handlers[id] != nil }

    public func canRun(_ id: String, in window: BrowserWindowState? = nil) -> Bool {
        guard handlers[id] != nil else { return false }
        let inv = CommandInvocation(window: window ?? currentWindow())
        return enablement[id]?(inv) ?? true
    }

    public func run(_ id: String, window: BrowserWindowState? = nil, arguments: [String: String] = [:]) throws {
        guard byID[id] != nil else { throw CommandError.unknown(id) }
        guard let handler = handlers[id] else { throw CommandError.unhandled(id) }
        let inv = CommandInvocation(window: window ?? currentWindow(), arguments: arguments)
        if let check = enablement[id], !check(inv) { throw CommandError.disabled(id) }
        handler(inv)
        recent.removeAll { $0 == id }
        recent.insert(id, at: 0)
        if recent.count > 50 { recent.removeLast() }
        didRun.forEach { $0(id) }
    }

    // MARK: Shortcuts

    public func shortcut(for id: String) -> KeyShortcut? {
        if let user = userShortcuts[id] { return user }
        return descriptor(id)?.shortcut.flatMap(KeyShortcut.init)
    }

    public func alternateShortcuts(for id: String) -> [KeyShortcut] {
        if userShortcuts[id] != nil { return [] }
        return descriptor(id)?.alternateShortcuts.compactMap(KeyShortcut.init) ?? []
    }

    public func setUserShortcut(_ shortcut: KeyShortcut?, for id: String) { userShortcuts[id] = .some(shortcut) }
    public func resetUserShortcut(for id: String) { userShortcuts.removeValue(forKey: id) }
    public func loadUserShortcuts(_ map: [String: KeyShortcut?]) { userShortcuts = map }

    /// Command bound to a key event, if any (used by the shell's key routing and the shortcut editor).
    public func command(matching shortcut: KeyShortcut) -> String? {
        descriptors.first { d in
            self.shortcut(for: d.id) == shortcut || alternateShortcuts(for: d.id).contains(shortcut)
        }?.id
    }

    /// Commands shown in the command bar.
    public var paletteCommands: [CommandDescriptor] { descriptors.filter { $0.palette && handlers[$0.id] != nil } }
}
