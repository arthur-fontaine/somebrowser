import Foundation
import Testing
@testable import EngineCEF

struct ChromeExtensionsReaderTests {
    /// A profile shaped like Chromium 154's: settings in Secure Preferences, pins in Preferences.
    func makeProfile() throws -> URL {
        let profile = FileManager.default.temporaryDirectory.appendingPathComponent("ext-profile-\(UUID().uuidString.prefix(6))")
        let fm = FileManager.default
        func write(_ object: Any, _ path: String) throws {
            let url = profile.appendingPathComponent(path)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: object).write(to: url)
        }
        let settings: [String: Any] = [
            "ublockid": ["location": 1, "path": "ublockid/1.0_0", "disable_reasons": [],
                         "manifest": ["name": "__MSG_extName__", "default_locale": "en",
                                      "action": ["default_icon": ["16": "img/16.png", "32": "img/32.png", "64": "img/64.png"]]]],
            "unpacked": ["location": 4, "path": "/Users/me/dev/my-ext", "state": 1,
                         "manifest": ["name": "My Ext", "icons": ["128": "icon.png"]]],
            "disabled": ["location": 1, "path": "disabled/1_0", "disable_reasons": [1], "manifest": ["name": "Off"]],
            "pdf": ["location": 5, "path": "/internal/pdf", "manifest": ["name": "Chromium PDF Viewer"]],
            "alpha": ["location": 1, "path": "alpha/2_0", "manifest": ["name": "Alpha", "action": ["default_icon": "a.png"]]],
        ]
        try write(["extensions": ["settings": settings]], "Secure Preferences")
        try write(["extensions": ["pinned_extensions": ["unpacked", "ublockid"]]], "Preferences")
        try write(["extName": ["message": "uBlock Origin Lite"]], "Extensions/ublockid/1.0_0/_locales/en/messages.json")
        try write(["extName": ["message": "uBlock Origin Lite (fr)"]], "Extensions/ublockid/1.0_0/_locales/fr/messages.json")
        return profile
    }

    @Test func listsEnabledUserExtensionsPinnedFirst() throws {
        let profile = try makeProfile()
        defer { try? FileManager.default.removeItem(at: profile) }
        let list = ChromeExtensionsReader.read(profile: profile, locale: "en-GB")
        #expect(list.map(\.id) == ["unpacked", "ublockid", "alpha"])
        #expect(list.map(\.isPinned) == [true, true, false])
        #expect(list[1].name == "uBlock Origin Lite")
        #expect(list[0].icon?.path == "/Users/me/dev/my-ext/icon.png")
        #expect(list[1].icon?.lastPathComponent == "32.png")
        #expect(list[2].icon?.path.hasSuffix("Extensions/alpha/2_0/a.png") == true)
    }

    @Test func localizesNamesWithFallbacks() throws {
        let profile = try makeProfile()
        defer { try? FileManager.default.removeItem(at: profile) }
        #expect(ChromeExtensionsReader.read(profile: profile, locale: "fr-FR").first { $0.id == "ublockid" }?.name == "uBlock Origin Lite (fr)")
        #expect(ChromeExtensionsReader.read(profile: profile, locale: "de").first { $0.id == "ublockid" }?.name == "uBlock Origin Lite")
    }

    @Test func readsManifestFromFolderWhenPrefsHaveNone() throws {
        let profile = try makeProfile()
        defer { try? FileManager.default.removeItem(at: profile) }
        let folder = profile.appendingPathComponent("dev-ext")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["name": "Dev Ext", "action": ["default_icon": "i.png"]])
            .write(to: folder.appendingPathComponent("manifest.json"))
        let prefs = profile.appendingPathComponent("Secure Preferences")
        var root = try JSONSerialization.jsonObject(with: Data(contentsOf: prefs)) as! [String: Any]
        var ext = root["extensions"] as! [String: Any]
        var settings = ext["settings"] as! [String: Any]
        settings["devext"] = ["location": 8, "path": folder.path, "disable_reasons": []]
        ext["settings"] = settings
        root["extensions"] = ext
        try JSONSerialization.data(withJSONObject: root).write(to: prefs)
        let dev = ChromeExtensionsReader.read(profile: profile).first { $0.id == "devext" }
        #expect(dev?.name == "Dev Ext")
        #expect(dev?.icon?.lastPathComponent == "i.png")
    }

    @Test func emptyProfileHasNoExtensions() {
        #expect(ChromeExtensionsReader.read(profile: URL(fileURLWithPath: "/nonexistent-profile")).isEmpty)
    }
}
