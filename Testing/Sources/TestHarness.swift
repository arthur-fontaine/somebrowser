import AppKit
import BrowserCore
import Foundation

public enum TestHarnessError: Error, CustomStringConvertible {
    case manifestNotFound(String)
    public var description: String {
        switch self { case .manifestNotFound(let p): "no feature.json found above \(p)" }
    }
}

/// A runtime with a fake engine, one window and the features under test — no AppKit windows, no disk.
///
/// ```swift
/// let h = try TestHarness(features: [PipFeature.self], manifestDirectory: #filePath)
/// try h.run("pip.toggle")
/// ```
/// Features under test must not need other features' modules: stub capabilities with
/// `h.runtime.capabilities.provide(…)` before `activate()` when needed (`activate: false`).
public final class TestHarness {
    public let runtime: BrowserRuntime
    public let engine: FakeEngine
    public let window: BrowserWindowState
    public let viewport: FakeViewport
    public private(set) var notifications: [String] = []
    public private(set) var events: [Any] = []
    public let dataDirectory: URL

    public convenience init(features: [BrowserFeature.Type], manifestDirectory: String, settingOverrides: [String: SettingValue] = [:],
                            activate: Bool = true) throws {
        let manifest = try Self.loadManifest(near: manifestDirectory)
        var registrations: [FeatureRegistration] = []
        for (i, type) in features.enumerated() {
            let m = i == 0 ? manifest : FeatureManifest(id: "test-\(i)", name: "\(type)")
            registrations.append(FeatureRegistration(manifest: m) { type.init(context: $0) })
        }
        try self.init(registrations: registrations, settingOverrides: settingOverrides, activate: activate)
    }

    public init(registrations: [FeatureRegistration], settingOverrides: [String: SettingValue] = [:], activate: Bool = true) throws {
        engine = FakeEngine()
        dataDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("browser-tests-\(UUID().uuidString)")
        runtime = BrowserRuntime(engine: engine, registrations: registrations, settingOverrides: settingOverrides,
                                 dataDirectory: dataDirectory, userDefaults: nil, persistSession: false)
        runtime.loadSession()
        window = runtime.makeWindowState()
        viewport = engine.makeViewport(in: NSView()) as! FakeViewport
        window.viewport = viewport
        runtime.commands.currentWindow = { [weak window] in window }
        runtime.events.subscribe(ToastRequested.self) { [weak self] in self?.notifications.append($0.message) }
        if activate { runtime.activateFeatures() }
    }

    public func activate() { runtime.activateFeatures() }

    /// Context of the first feature under test.
    public var context: FeatureContext { FeatureContext(manifest: runtime.manifests.first ?? FeatureManifest(id: "test", name: "test"), runtime: runtime) }

    public func run(_ command: String, arguments: [String: String] = [:]) throws {
        try runtime.commands.run(command, window: window, arguments: arguments)
    }

    /// Records every event of a type for assertions.
    public func record<E: BrowserEvent>(_ type: E.Type) -> EventRecorder<E> {
        let r = EventRecorder<E>()
        runtime.events.subscribe(type) { r.events.append($0) }
        return r
    }

    @discardableResult
    public func openTab(_ string: String, placement: TabPlacement = .automatic, select: Bool = true) -> BrowserTab {
        runtime.openTab(URL(string: string)!, in: window, placement: placement, select: select)
    }

    public var selectedTab: BrowserTab? { runtime.selectedTab(in: window) }

    public func fakeTab(_ tab: BrowserTab) -> FakeEngineTab { runtime.live(tab) as! FakeEngineTab }

    static func loadManifest(near path: String) throws -> FeatureManifest {
        var dir = URL(fileURLWithPath: path).deletingLastPathComponent()
        while dir.path != "/" {
            let candidate = dir.appendingPathComponent("feature.json")
            if let data = FileManager.default.contents(atPath: candidate.path) {
                return try JSONDecoder().decode(FeatureManifest.self, from: data)
            }
            dir.deleteLastPathComponent()
        }
        throw TestHarnessError.manifestNotFound(path)
    }

    deinit { try? FileManager.default.removeItem(at: dataDirectory) }
}

public final class EventRecorder<E: BrowserEvent> {
    public var events: [E] = []
    public var last: E? { events.last }
}
