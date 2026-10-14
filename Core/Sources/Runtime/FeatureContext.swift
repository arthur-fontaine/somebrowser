import Foundation

/// Everything a feature may touch. Features get one at init; they never reach for globals.
public final class FeatureContext {
    public let manifest: FeatureManifest
    public unowned let runtime: BrowserRuntime

    public init(manifest: FeatureManifest, runtime: BrowserRuntime) {
        self.manifest = manifest
        self.runtime = runtime
    }

    public var featureID: String { manifest.id }
    public var commands: CommandRegistry { runtime.commands }
    public var settings: SettingsStore { runtime.settings }
    public var siteSettings: SiteSettingsStore { runtime.siteSettings }
    public var events: EventBus { runtime.events }
    public var capabilities: CapabilityRegistry { runtime.capabilities }
    public var tabs: TabStore { runtime.tabs }
    public var ui: UIRegistry { runtime.ui }
    public var engine: BrowserEngine { runtime.engine }
    public var hooks: EngineHooks { runtime.engine.hooks }
    public var shell: ShellServices? { runtime.shell }
    public var windows: [BrowserWindowState] { runtime.windows }
    public var keyWindow: BrowserWindowState? { runtime.keyWindow }

    /// Private storage for the feature (`<data>/Features/<id>/`), created on first access.
    public var dataDirectory: URL {
        let url = runtime.dataDirectory.appendingPathComponent("Features/\(featureID)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Transient message for the user (shown by whichever feature renders toasts).
    public func notify(_ message: String, systemImage: String? = nil, window: BrowserWindowState? = nil,
                       actionTitle: String? = nil, action: (() -> Void)? = nil) {
        events.publish(ToastRequested(message: message, systemImage: systemImage, windowID: window?.id,
                                      actionTitle: actionTitle, action: action))
    }
}
