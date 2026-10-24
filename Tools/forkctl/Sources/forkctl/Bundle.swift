import Foundation

/// Assembles `build/<Brand>.app` from SwiftPM products. Engines that need extra bundle structure
/// (CEF helpers + framework) are handled here so no Xcode project is ever required.
enum Bundler {
    static func bundle(_ p: Project, configuration: String) throws -> URL {
        let fm = FileManager.default
        let products = p.path(".build/\(configuration)")
        let app = p.path("build/\(p.brand.name).app")
        let contents = app.appendingPathComponent("Contents")
        try? fm.removeItem(at: app)
        for d in ["MacOS", "Resources", "Frameworks"] {
            try fm.createDirectory(at: contents.appendingPathComponent(d), withIntermediateDirectories: true)
        }

        let exe = p.brand.executableName
        try fm.copyItem(at: products.appendingPathComponent(exe), to: contents.appendingPathComponent("MacOS/\(exe)"))

        // SwiftPM resource bundles (Bundle.module lookups search Contents/Resources).
        for item in (try? fm.contentsOfDirectory(at: products, includingPropertiesForKeys: nil)) ?? []
        where item.pathExtension == "bundle" {
            try fm.copyItem(at: item, to: contents.appendingPathComponent("Resources/\(item.lastPathComponent)"))
        }

        try infoPlist(p, principalClass: p.engine.principalClass ?? "NSApplication")
            .write(to: contents.appendingPathComponent("Info.plist"))
        try makeIcon(p, into: contents.appendingPathComponent("Resources/AppIcon.icns"))

        if p.engine.bundler == "cef" { try CEFBundler.embed(p, app: app, products: products) }

        try sign(p, app: app)
        return app
    }

    static func infoPlist(_ p: Project, principalClass: String) throws -> Data {
        let b = p.brand
        let plist: [String: Any] = [
            "CFBundleName": b.name,
            "CFBundleDisplayName": b.name,
            "CFBundleIdentifier": b.bundleId,
            "CFBundleExecutable": b.executableName,
            "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": version(p),
            "CFBundleVersion": buildNumber(p),
            "CFBundleIconFile": "AppIcon",
            "CFBundleIconName": "AppIcon",  // the Assets.car icon, when the brand icon is a .icon
            "LSMinimumSystemVersion": "26.0",
            "LSApplicationCategoryType": "public.app-category.productivity",
            "NSPrincipalClass": principalClass,
            "NSHighResolutionCapable": true,
            "NSSupportsAutomaticGraphicsSwitching": true,
            "NSHumanReadableCopyright": b.copyright,
            "NSCameraUsageDescription": "Websites you allow can use the camera.",
            "NSMicrophoneUsageDescription": "Websites you allow can use the microphone.",
            "NSLocationUsageDescription": "Websites you allow can use your location.",
            "NSBluetoothAlwaysUsageDescription": "Websites you allow can use Bluetooth devices.",
            "NSAppleEventsUsageDescription": "Used to read your Safari favorites and tabs when Safari sync is on.",
            // A browser: web content (WebKit tabs) may load any site, plain http included, and a certificate the user
            // chose to accept (Visit Anyway). The browser's own requests still go through App Transport Security.
            "NSAppTransportSecurity": ["NSAllowsArbitraryLoadsInWebContent": true],
            "CFBundleURLTypes": [
                ["CFBundleURLName": "Web site URL", "CFBundleURLSchemes": ["http", "https"]],
                ["CFBundleURLName": "\(b.name) URL", "CFBundleURLSchemes": [b.urlScheme]],
            ],
            "CFBundleDocumentTypes": [[
                "CFBundleTypeName": "HTML document",
                "CFBundleTypeRole": "Viewer",
                "LSItemContentTypes": ["public.html", "public.xhtml", "com.apple.webarchive", "public.svg-image"],
            ]],
        ]
        return try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    }

    static func version(_ p: Project) -> String {
        (try? String(contentsOf: p.path("VERSION"), encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "0.1.0"
    }

    static func buildNumber(_ p: Project) -> String {
        (try? Shell.capture(["git", "-C", p.root.path, "rev-list", "--count", "HEAD"]))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "1"
    }

    /// Brand icon → `AppIcon.icns`. Fork icon wins over the default one. An Icon Composer document (`.icon`) is compiled
    /// with actool, which also writes `Assets.car`: only that carries the system glass and the dark and tinted looks.
    /// A 1024² PNG is converted directly; a master drawn for a small size sits next to it as `<name>-<px>.png`
    /// (e.g. `AppIcon-16.png`) and is used as is at that size instead of a shrunk copy.
    static func makeIcon(_ p: Project, into icns: URL) throws {
        let source = p.brand.icon.map { p.path($0) } ?? p.path("Defaults/Assets/AppIcon.png")
        guard FileManager.default.fileExists(atPath: source.path) else { return }
        if source.pathExtension == "icon" { return try compileIcon(source, into: icns.deletingLastPathComponent()) }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("forkctl-\(UUID().uuidString).iconset")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        for size in [16, 32, 128, 256, 512] {
            for scale in [1, 2] {
                let px = size * scale
                let name = scale == 1 ? "icon_\(size)x\(size).png" : "icon_\(size)x\(size)@2x.png"
                let out = tmp.appendingPathComponent(name)
                let master = source.deletingPathExtension().path + "-\(px).png"
                if FileManager.default.fileExists(atPath: master) {
                    try FileManager.default.copyItem(atPath: master, toPath: out.path)
                } else {
                    try Shell.run(["sips", "-z", "\(px)", "\(px)", source.path, "--out", out.path], quiet: true)
                }
            }
        }
        try Shell.run(["iconutil", "-c", "icns", tmp.path, "-o", icns.path], quiet: true)
    }

    /// `.icon` → `Assets.car` + `AppIcon.icns` in `resources`. actool names the icon after its file, so it compiles a
    /// copy named `AppIcon.icon`. Its report (a plist on stdout) says why it rejected a document, so it is kept.
    static func compileIcon(_ source: URL, into resources: URL) throws {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("forkctl-\(UUID().uuidString)")
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }
        let doc = tmp.appendingPathComponent("AppIcon.icon")
        try fm.copyItem(at: source, to: doc)
        let actool = Process()
        actool.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        actool.arguments = [
            "actool", doc.path, "--compile", resources.path, "--app-icon", "AppIcon",
            "--platform", "macosx", "--target-device", "mac", "--minimum-deployment-target", "26.0",
            "--output-partial-info-plist", tmp.appendingPathComponent("partial.plist").path,
        ]
        let out = Pipe()
        actool.standardOutput = out
        actool.standardError = out
        try actool.run()
        let report = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        actool.waitUntilExit()
        guard actool.terminationStatus == 0, fm.fileExists(atPath: resources.appendingPathComponent("Assets.car").path) else {
            throw ProjectError.invalid("actool could not compile \(source.lastPathComponent):\n\(report)")
        }
    }

    static func sign(_ p: Project, app: URL) throws {
        let identity = ProcessInfo.processInfo.environment["FORKCTL_SIGN_IDENTITY"] ?? "-"
        var args = ["codesign", "--force", "--sign", identity, "--timestamp=none"]
        // Restricted entitlements (passwords helper, passkeys, AppSSO) only work with a real identity and
        // provisioning profile; ad-hoc builds would be killed at launch if they claimed them.
        let entitlements = identity == "-" ? p.path("Defaults/Entitlements.adhoc.plist") : p.path("Defaults/Entitlements.plist")
        let forkEntitlements = p.path("Fork/Entitlements.plist")
        let chosen = identity != "-" && FileManager.default.fileExists(atPath: forkEntitlements.path) ? forkEntitlements : entitlements
        if FileManager.default.fileExists(atPath: chosen.path) { args += ["--entitlements", chosen.path] }
        if identity != "-" { args += ["--options", "runtime"] }
        // Sign nested code first (helpers, frameworks), then the app.
        for nested in nestedCode(in: app) { try Shell.run(["codesign", "--force", "--sign", identity, "--timestamp=none", nested.path], quiet: true) }
        try Shell.run(args + [app.path], quiet: true)
    }

    static func nestedCode(in app: URL) -> [URL] {
        let fw = app.appendingPathComponent("Contents/Frameworks")
        guard let items = try? FileManager.default.contentsOfDirectory(at: fw, includingPropertiesForKeys: nil) else { return [] }
        var result: [URL] = []
        for item in items where item.pathExtension == "framework" {
            let libs = item.appendingPathComponent("Versions/A/Libraries")
            for lib in (try? FileManager.default.contentsOfDirectory(at: libs, includingPropertiesForKeys: nil)) ?? []
            where lib.pathExtension == "dylib" { result.append(lib) }
            result.append(item)
        }
        result += items.filter { $0.pathExtension == "app" }
        return result
    }
}

/// CEF needs the framework in a versioned layout and five helper apps (see docs/decisions/0002).
enum CEFBundler {
    static let helperSuffixes: [(name: String, id: String)] = [
        ("", ""), (" (Alerts)", ".alerts"), (" (GPU)", ".gpu"), (" (Plugin)", ".plugin"), (" (Renderer)", ".renderer"),
    ]

    static func embed(_ p: Project, app: URL, products: URL) throws {
        let fm = FileManager.default
        let release = p.path("Vendor/cef/Release/Chromium Embedded Framework.framework")
        guard fm.fileExists(atPath: release.path) else {
            throw ProjectError.missing("CEF distribution — run `./forkctl vendor cef`")
        }
        let fw = app.appendingPathComponent("Contents/Frameworks/Chromium Embedded Framework.framework")
        try fm.createDirectory(at: fw.appendingPathComponent("Versions"), withIntermediateDirectories: true)
        // Clone (APFS copy-on-write) instead of copying 320 MB on every build.
        try Shell.run(["cp", "-c", "-R", release.path, fw.appendingPathComponent("Versions/A").path], quiet: true)
        try fm.createSymbolicLink(atPath: fw.appendingPathComponent("Versions/Current").path, withDestinationPath: "A")
        for link in ["Chromium Embedded Framework", "Libraries", "Resources"] {
            try fm.createSymbolicLink(atPath: fw.appendingPathComponent(link).path, withDestinationPath: "Versions/A/\(link)")
        }

        let helperBinary = products.appendingPathComponent("BrowserHelper")
        for (suffix, idSuffix) in helperSuffixes {
            // Chromium finds its helpers by the main executable's name ("<executable> Helper (GPU)…").
            let name = "\(p.brand.executableName) Helper\(suffix)"
            let helper = app.appendingPathComponent("Contents/Frameworks/\(name).app/Contents")
            try fm.createDirectory(at: helper.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
            try fm.copyItem(at: helperBinary, to: helper.appendingPathComponent("MacOS/\(name)"))
            var plist: [String: Any] = [
                "CFBundleExecutable": name,
                "CFBundleIdentifier": "\(p.brand.bundleId).helper\(idSuffix)",
                "CFBundleName": "\(p.brand.name) Helper\(suffix)",
                "CFBundlePackageType": "APPL",
                "LSUIElement": "1",
                "LSMinimumSystemVersion": "26.0",
                "NSSupportsAutomaticGraphicsSwitching": true,
            ]
            // Notifications with buttons are posted from this helper (as Chrome's helper-alerts-Info.plist): macOS shows
            // them as alerts, with its name and icon.
            if idSuffix == ".alerts" {
                plist["NSUserNotificationAlertStyle"] = "alert"
                plist["CFBundleDisplayName"] = p.brand.name
                plist["CFBundleIconFile"] = "AppIcon"
                try fm.createDirectory(at: helper.appendingPathComponent("Resources"), withIntermediateDirectories: true)
                try fm.copyItem(at: app.appendingPathComponent("Contents/Resources/AppIcon.icns"),
                                to: helper.appendingPathComponent("Resources/AppIcon.icns"))
            }
            try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
                .write(to: helper.appendingPathComponent("Info.plist"))
        }
    }
}
