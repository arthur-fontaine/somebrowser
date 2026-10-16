import Foundation
import Testing
@testable import BrowserCore

struct ChromiumExtensionsTests {
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
            "ublockid": ["location": 1, "path": "ublockid/1.0_0", "disable_reasons": [], "from_webstore": true,
                         "manifest": ["name": "__MSG_extName__", "default_locale": "en",
                                      "action": ["default_icon": ["16": "img/16.png", "32": "img/32.png", "64": "img/64.png"]]]],
            "unpacked": ["location": 4, "path": "/Users/me/dev/my-ext", "state": 1,
                         "manifest": ["name": "My Ext", "icons": ["128": "icon.png"]]],
            "disabled": ["location": 1, "path": "disabled/1_0", "disable_reasons": [1], "manifest": ["name": "Off"]],
            "pdf": ["location": 5, "path": "/internal/pdf", "manifest": ["name": "Chromium PDF Viewer"]],
            "alpha": ["location": 1, "path": "alpha/2_0", "open_side_panel_on_icon_click": true,
                      "manifest": ["name": "Alpha", "action": ["default_icon": "a.png"], "side_panel": ["default_path": "panel.html"],
                                   "chrome_url_overrides": ["newtab": "/tab.html"], "options_ui": ["page": "options.html"]]],
        ]
        try write(["extensions": ["settings": settings]], "Secure Preferences")
        try write(["extensions": ["pinned_extensions": ["unpacked", "ublockid"]]], "Preferences")
        try write(["extName": ["message": "uBlock Origin Lite"]], "Extensions/ublockid/1.0_0/_locales/en/messages.json")
        try write(["extName": ["message": "uBlock Origin Lite (fr)"]], "Extensions/ublockid/1.0_0/_locales/fr/messages.json")
        return profile
    }

    /// Every extension gets pinned in Chrome's toolbar (its pins first, in order), keeping the rest of the file; the
    /// options page comes from the manifest.
    @Test func pinsEveryExtensionInChrome() throws {
        let profile = try makeProfile()
        defer { try? FileManager.default.removeItem(at: profile) }
        ChromiumExtensions.pinAll(profile: profile)
        #expect(ChromiumExtensions.pinned(profile: profile) == ["unpacked", "ublockid", "alpha"])
        #expect(ChromiumExtensions.read(profile: profile).allSatisfy { $0.isPinned })
        #expect(ChromiumExtensions.read(profile: profile).first { $0.id == "alpha" }?.optionsPath == "options.html")
    }

    /// A pin of an extension Chrome hasn't listed yet (unpacked, loaded at launch) stays.
    @Test func pinsOfExtensionsNotListedYetStay() throws {
        let profile = FileManager.default.temporaryDirectory.appendingPathComponent("ext-pins-\(UUID().uuidString.prefix(6))")
        defer { try? FileManager.default.removeItem(at: profile) }
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["extensions": ["pinned_extensions": ["loaded-later"]]]).write(to: profile.appendingPathComponent("Preferences"))
        ChromiumExtensions.pinAll(profile: profile)
        #expect(ChromiumExtensions.pinned(profile: profile) == ["loaded-later"])
    }

    @Test func listsEnabledUserExtensionsPinnedFirst() throws {
        let profile = try makeProfile()
        defer { try? FileManager.default.removeItem(at: profile) }
        let list = ChromiumExtensions.read(profile: profile, locale: "en-GB")
        #expect(list.map(\.id) == ["unpacked", "ublockid", "alpha"])
        #expect(list.map(\.isPinned) == [true, true, false])
        #expect(list[1].name == "uBlock Origin Lite")
        #expect(list.map(\.isFromWebStore) == [false, true, false])
        #expect(list[0].icon?.path == "/Users/me/dev/my-ext/icon.png")
        #expect(list[1].icon?.lastPathComponent == "32.png")
        #expect(list[2].icon?.path.hasSuffix("Extensions/alpha/2_0/a.png") == true)
    }

    @Test func readsSidePanelAndNewTabPage() throws {
        let profile = try makeProfile()
        defer { try? FileManager.default.removeItem(at: profile) }
        let list = ChromiumExtensions.read(profile: profile)
        let alpha = try #require(list.first { $0.id == "alpha" })
        #expect(alpha.sidePanelPath == "panel.html" && alpha.opensSidePanelOnClick)
        #expect(alpha.newTabPagePath.flatMap(alpha.page)?.absoluteString == "chrome-extension://alpha/tab.html")
        let other = try #require(list.first { $0.id == "ublockid" })
        #expect(other.sidePanelPath == nil && !other.opensSidePanelOnClick && other.newTabPagePath == nil)
    }

    @Test func localizesNamesWithFallbacks() throws {
        let profile = try makeProfile()
        defer { try? FileManager.default.removeItem(at: profile) }
        #expect(ChromiumExtensions.read(profile: profile, locale: "fr-FR").first { $0.id == "ublockid" }?.name == "uBlock Origin Lite (fr)")
        #expect(ChromiumExtensions.read(profile: profile, locale: "de").first { $0.id == "ublockid" }?.name == "uBlock Origin Lite")
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
        let dev = ChromiumExtensions.read(profile: profile).first { $0.id == "devext" }
        #expect(dev?.name == "Dev Ext")
        #expect(dev?.icon?.lastPathComponent == "i.png")
    }

    @Test func emptyProfileHasNoExtensions() {
        #expect(ChromiumExtensions.read(profile: URL(fileURLWithPath: "/nonexistent-profile")).isEmpty)
    }
}
