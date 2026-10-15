import AppKit
import BrowserCore
import SwiftUI

/// One routing rule: links matching `pattern` open in `destination`.
nonisolated struct TrafficRule: Codable, Equatable, Identifiable, Sendable {
    enum Destination: Codable, Equatable, Hashable, Sendable {
        case space(UUID)
        case miniWindow
        case mainWindow
    }
    var id = UUID()
    /// A host (`github.com`, its subdomains too) or, with a `/`, the start of an address (`docs.google.com/document`).
    var pattern: String
    var destination: Destination

    func matches(_ url: URL) -> Bool {
        let rule = Self.normalized(pattern)
        guard !rule.isEmpty, ["http", "https"].contains(url.scheme), var host = url.host()?.lowercased() else { return false }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        if !rule.contains("/") { return host == rule || host.hasSuffix("." + rule) }
        return (host + url.path() + (url.query().map { "?" + $0 } ?? "")).hasPrefix(rule)
    }

    static func normalized(_ pattern: String) -> String {
        var p = pattern.trimmingCharacters(in: .whitespaces).lowercased()
        for prefix in ["https://", "http://", "www."] where p.hasPrefix(prefix) { p.removeFirst(prefix.count) }
        return p
    }
}

/// Air Traffic Control (Arc): links from other apps follow your rules — to a Space, a mini window, or the main window
/// even when mini windows take links from other apps. First matching rule wins; no match keeps the usual behavior.
public final class AirTrafficFeature: BrowserFeature {
    let context: FeatureContext
    let model = AirTrafficModel()
    static let editorFlag = "air-traffic.editor"
    private var file: URL { context.dataDirectory.appendingPathComponent("rules.json") }

    public init(context: FeatureContext) {
        self.context = context
    }

    public func activate() {
        model.rules = (try? JSONDecoder().decode([TrafficRule].self, from: Data(contentsOf: file))) ?? []
        // Before other handlers (mini windows): a rule decides first.
        context.runtime.externalURLHandlers.insert({ [weak self] url in self?.route(url) ?? false }, at: 0)
        context.commands.handle("air-traffic.edit") { inv in inv.window?.flags.insert(Self.editorFlag) }
        let model = self.model, runtime = context.runtime
        context.ui.contribute(.overlay, id: "air-traffic.editor", order: 87) { [weak self] window in
            AirTrafficEditor(model: model, window: window, spaces: runtime.tabs.spaces.map { ($0.id, $0.name, $0.icon) },
                             save: { self?.save() }, close: { window.flags.remove(Self.editorFlag) })
        }
    }

    func save() {
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(model.rules).write(to: file, options: .atomic)
    }

    /// Opens `url` where its rule says; false when no rule matches (or a mini window isn't available).
    func route(_ url: URL) -> Bool {
        guard let rule = model.rules.first(where: { $0.matches(url) }) else { return false }
        switch rule.destination {
        case .miniWindow:
            guard context.commands.isHandled("mini-window.new") else { return false }
            try? context.commands.run("mini-window.new", window: nil, arguments: ["url": url.absoluteString])
        case .mainWindow:
            open(url, in: mainWindow())
        case .space(let id):
            guard context.tabs.space(id) != nil else { return false }
            let window = context.windows.first { !$0.isPrivate && $0.spaceID == id && !$0.isMini } ?? mainWindow()
            context.runtime.switchSpace(id, in: window)
            open(url, in: window)
        }
        return true
    }

    private func mainWindow() -> BrowserWindowState {
        let key = context.runtime.keyWindow
        if let key, !key.isPrivate, !key.isMini { return key }
        return context.windows.first { !$0.isPrivate && !$0.isMini }
            ?? context.shell?.openWindow(spaceID: nil, isPrivate: false, initialURL: nil) ?? context.runtime.makeWindowState()
    }

    private func open(_ url: URL, in window: BrowserWindowState) {
        context.runtime.openTab(url, in: window)
        context.shell?.nsWindow(for: window)?.makeKeyAndOrderFront(nil)
        if let app = NSApp { app.activate() }
    }
}

private extension BrowserWindowState {
    /// Mini windows mark themselves with this flag (Little Arc); they're not where routed links go.
    var isMini: Bool { flags.contains("mini-window") }
}

@Observable
final class AirTrafficModel {
    var rules: [TrafficRule] = []
}
