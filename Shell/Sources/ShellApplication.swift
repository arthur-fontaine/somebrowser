import AppKit
import BrowserCore

/// Process entry point, called from the generated `main.swift`.
public enum ShellApplication {
    public static func main(engine engineType: BrowserEngine.Type, features: [FeatureRegistration],
                            settingOverrides: [String: SettingValue], engineOptions: [String: SettingValue]) {
        let app = engineType.applicationClass.shared
        app.setActivationPolicy(.regular)
        let engine = engineType.init(options: engineOptions)
        let dataDirectory = Self.dataDirectory()
        let runtime = BrowserRuntime(engine: engine, registrations: features, settingOverrides: settingOverrides,
                                     dataDirectory: dataDirectory, userDefaults: Self.settingsStorage())
        let controller = ShellController(runtime: runtime)
        runtime.shell = controller
        app.delegate = controller
        do {
            try engine.bootstrap(profileDirectory: dataDirectory.appendingPathComponent("Engine/\(engine.id)", isDirectory: true))
        } catch {
            let alert = NSAlert()
            alert.messageText = "\(Brand.name) could not start its web engine"
            alert.informativeText = "\(error)"
            alert.runModal()
            exit(1)
        }
        engine.runMainLoop { controller.engineDidBecomeReady() }
    }

    /// Settings live with the data: a data directory given with BROWSER_DATA_DIR (tests, automation) gets its own
    /// `settings.plist` and never changes the real profile's settings.
    static func settingsStorage() -> UserDefaults? {
        guard ProcessInfo.processInfo.environment["BROWSER_DATA_DIR"] != nil else { return .standard }
        return UserDefaults(suiteName: dataDirectory().appendingPathComponent("settings").path)
    }

    static func dataDirectory() -> URL {
        if let override = ProcessInfo.processInfo.environment["BROWSER_DATA_DIR"] {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent(Brand.name, isDirectory: true)
    }
}
