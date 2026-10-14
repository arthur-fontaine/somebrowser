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

    /// Brand icon (1024² PNG) → .icns. Fork icon wins over the default one.
    static func makeIcon(_ p: Project, into icns: URL) throws {
        let source = p.brand.icon.map { p.path($0) } ?? p.path("Defaults/Assets/AppIcon.png")
        guard FileManager.default.fileExists(atPath: source.path) else { return }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("forkctl-\(UUID().uuidString).iconset")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        for size in [16, 32, 128, 256, 512] {
            for scale in [1, 2] {
                let px = size * scale
                let name = scale == 1 ? "icon_\(size)x\(size).png" : "icon_\(size)x\(size)@2x.png"
                try Shell.run(["sips", "-z", "\(px)", "\(px)", source.path, "--out", tmp.appendingPathComponent(name).path], quiet: true)
            }
        }
        try Shell.run(["iconutil", "-c", "icns", tmp.path, "-o", icns.path], quiet: true)
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
            let name = "\(p.brand.name) Helper\(suffix)"
            let helper = app.appendingPathComponent("Contents/Frameworks/\(name).app/Contents")
            try fm.createDirectory(at: helper.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
            try fm.copyItem(at: helperBinary, to: helper.appendingPathComponent("MacOS/\(name)"))
            let plist: [String: Any] = [
                "CFBundleExecutable": name,
                "CFBundleIdentifier": "\(p.brand.bundleId).helper\(idSuffix)",
                "CFBundleName": name,
                "CFBundlePackageType": "APPL",
                "LSUIElement": "1",
                "LSMinimumSystemVersion": "26.0",
                "NSSupportsAutomaticGraphicsSwitching": true,
            ]
            try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
                .write(to: helper.appendingPathComponent("Info.plist"))
        }
    }
}
