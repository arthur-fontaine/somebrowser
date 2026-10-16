import BrowserTesting
import Foundation
import Testing

/// Chrome extension APIs whose plumbing differs here from Chrome's (pages live in windows of their own, without
/// Chrome's window chrome): a probe extension runs each one on request. Chromium engine only.
@Suite(.serialized, .enabled(if: AppDriver.executableFromEnvironment != nil, "set BROWSER_E2E_APP (./forkctl test --e2e)"))
struct ExtensionAPITests {
    static let pages = [
        "/one": "<!doctype html><title>One</title><body>one</body>",
        "/two": "<!doctype html><title>Two</title><body>two</body>",
        "/three": "<!doctype html><title>Three</title><body>three</body>",
        // A sign-in page that takes a moment, then sends the browser to the extension's redirect URL.
        "/auth": "<!doctype html><title>Sign in</title><script>setTimeout(() => location.replace(new URLSearchParams(location.search).get('to') + '?code=42'), 300)</script>",
    ]
    static let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures/ApiProbeExtension")

    struct Session {
        let app: AppDriver
        let server: TestHTTPServer
        let data: URL

        /// The probe's id (unpacked extensions get one from their path).
        func extensionID() throws -> String {
            var id: String?
            try app.waitUntil(timeout: 20) {
                id = (try app.state()["extensions"] as? [[String: Any]])?.first?["id"] as? String
                return id != nil
            }
            return id ?? ""
        }

        func openProbePage() throws {
            try app.open(server.url("/one"))
            try app.waitUntil(timeout: 20) { try app.eval("String(document.documentElement.dataset.probe)") as? String == "ready" }
        }

        /// Runs one of the worker's probes from the selected page; its answer (JSON) comes back through storage.
        func probe(_ name: String) throws -> String {
            _ = try app.eval("delete document.documentElement.dataset.r_\(name); window.postMessage({ probe: '\(name)' }, '*'); 1")
            var result = ""
            try app.waitUntil(timeout: 20) {
                result = try app.eval("String(document.documentElement.dataset.r_\(name) || '')") as? String ?? ""
                return !result.isEmpty
            }
            return result
        }

        func dataset(_ key: String) throws -> String? { try app.eval("String(document.documentElement.dataset.\(key))") as? String }

        func finish() throws {
            try app.quit()
            try? FileManager.default.removeItem(at: data)
        }
    }

    func launch() throws -> Session? {
        let data = FileManager.default.temporaryDirectory.appendingPathComponent("e2e-api-\(UUID().uuidString.prefix(6))")
        let server = try TestHTTPServer(pages: Self.pages)
        let app = try AppDriver(executable: AppDriver.executableFromEnvironment!, extraEnvironment: ["BROWSER_DATA_DIR": data.path],
                                arguments: ["--load-extension=\(Self.fixture.path)"])
        guard try app.state()["engine"] as? String == "cef-chrome" else {
            try app.quit()
            try? FileManager.default.removeItem(at: data)
            return nil
        }
        return Session(app: app, server: server, data: data)
    }

    @Test func coreAPIsWork() throws {
        guard let s = try launch() else { return }
        try s.openProbePage()
        #expect(try s.probe("script") == "\"One\"")
        #expect(try s.probe("offscreen") == "\"parsed:hi\"")
        // The sign-in page shows in a window of Chrome's; its redirect ends the flow.
        #expect(try s.probe("auth").contains("chromiumapp.org/cb?code=42"))
        #expect(try s.probe("update").hasPrefix("\"ok "))
        try s.app.waitUntil(timeout: 15) { try s.app.eval("document.title") as? String == "Three" }
        try s.finish()
    }

    /// `tabs.create` opens the page as a tab of the window (with our Chromium's `chromium/0005`, as a child of the page
    /// in front, its id lasting; otherwise Chrome makes it in a window of its own, which the browser adopts by URL), and
    /// `tabs.remove` closes it.
    @Test func extensionsOpenAndCloseTabs() throws {
        guard let s = try launch() else { return }
        try s.openProbePage()
        _ = try s.probe("tabs")
        try s.app.waitUntil(timeout: 15) { try s.app.tabs().contains { $0.title == "Two" } }
        let probePage = try #require(try s.app.tabs().firstIndex { $0.title == "One" })
        _ = try s.app.run("tabs.select-\(probePage + 1)")  // back to the probe page
        #expect(try s.probe("remove") == "\"removed 1\"")
        try s.app.waitUntil(timeout: 15) { try !s.app.tabs().contains { $0.title == "Two" } }
        #expect(try s.app.tabs().map(\.title) == ["One"])
        try s.finish()
    }

    /// Our Chromium with `chromium/0005` and `cef/0002` (`--views-hosted-new-tabs`): an extension's new tab is the
    /// browser's from the start, so its id lasts, and pages are normal windows that hold a tab group: what Claude in
    /// Chrome does for a session (ADR-0005). Runs when BROWSER_E2E_CEF_PATCHES lists 0005.
    @Test func extensionTabsKeepTheirIds() throws {
        guard ProcessInfo.processInfo.environment["BROWSER_E2E_CEF_PATCHES"]?.contains("0005") == true, let s = try launch() else { return }
        try s.openProbePage()
        #expect(try s.probe("claude") == "\"ok\"")
        try s.app.waitUntil(timeout: 15) { try s.app.tabs().contains { $0.title == "Two" } }
        #expect(try s.probe("window") == "\"ok\"")
        try s.app.waitUntil(timeout: 15) { try s.app.tabs().contains { $0.title == "Three" } }
        #expect(try s.app.tabs().first?.title == "One")  // both opened in the background
        try s.finish()
    }

    /// Chrome's own extension prompts (a permission asked for, an extension removing itself) show as the browser's
    /// dialogs: Chrome's windows stay invisible, and the answer given in the browser's dialog is the one Chrome gets.
    /// With our Chromium (the answer shows in the extension's badge, `chromium/0001`).
    @Test func extensionPromptsAreTheBrowsers() throws {
        let fixture = Self.fixture.deletingLastPathComponent().appendingPathComponent("PromptExtension")
        let data = FileManager.default.temporaryDirectory.appendingPathComponent("e2e-prompt-\(UUID().uuidString.prefix(6))")
        defer { try? FileManager.default.removeItem(at: data) }
        let server = try TestHTTPServer(pages: Self.pages)
        let app = try AppDriver(executable: AppDriver.executableFromEnvironment!, extraEnvironment: ["BROWSER_DATA_DIR": data.path],
                                arguments: ["--load-extension=\(fixture.path)"])
        guard try app.state()["engine"] as? String == "cef-chrome" else { try app.quit(); return }
        try app.open(server.url("/one"))
        try app.waitUntil(timeout: 15) { try app.eval("document.title") as? String == "One" }
        guard try (app.eval("navigator.userAgent") as? String ?? "").contains("Chrome/156") else { try app.quit(); return }
        var id = ""
        try app.waitUntil(timeout: 20) {
            id = (try app.state()["extensions"] as? [[String: Any]])?.first?["id"] as? String ?? ""
            return !id.isEmpty
        }
        let badge = { (try app.state()["extensions"] as? [[String: Any]])?.first?["badge"] as? String }
        // Chrome's views windows big enough to show something (its hidden toolbar is 1×1): shown, or kept invisible by
        // the browser (and clicks go through).
        let chromeWindows = { (visible: Bool) in
            ((try app.call(["op": "views"])["windows"] as? [[String: Any]]) ?? []).filter {
                $0["class"] as? String == "NativeWidgetMacNSWindow" && !(($0["frame"] as? String) ?? "").hasSuffix("{1, 1}}")
                    && (visible ? ($0["alpha"] as? Double ?? 0) > 0 : $0["alpha"] as? Double == 0 && $0["ignoresMouse"] as? Bool == true)
            }.count
        }
        // A permission, denied in the browser's dialog. The action's button may not be ready at once: press until a
        // prompt comes.
        try app.waitUntil(timeout: 20) {
            if try chromeWindows(false) + chromeWindows(true) > 0 { return true }
            try app.run("extensions.run", ["id": id])
            Thread.sleep(forTimeInterval: 1)
            return false
        }
        try app.waitUntil(timeout: 10) { try chromeWindows(false) == 1 }
        #expect(try chromeWindows(true) == 0)
        try app.waitUntil(timeout: 10) { (try? app.run("dialogs.cancel")) != nil }
        try app.waitUntil(timeout: 30) { try badge() == "N" }
        // Chrome closes its dialog a moment after the answer; a bubble shown meanwhile closes too, as focus moves (no
        // person clicks that fast).
        try app.waitUntil(timeout: 10) { try chromeWindows(false) + chromeWindows(true) == 0 }
        // Removing itself (a bubble, a child window), accepted.
        try app.run("extensions.run", ["id": id])
        try app.waitUntil(timeout: 10) { try chromeWindows(false) == 1 }
        #expect(try chromeWindows(true) == 0)
        try app.waitUntil(timeout: 10) { (try? app.run("dialogs.accept")) != nil }
        try app.waitUntil(timeout: 30) { (try app.state()["extensions"] as? [[String: Any]])?.isEmpty == true }
        try app.quit()
    }

    /// Extensions are managed from the browser's panel, through Chrome's extensions page never shown: turned off and on,
    /// site access, private windows, and removal confirmed in the browser's own dialog. Chrome's page and windows never
    /// show, and that page contacts nobody.
    @Test func extensionsAreManagedWithoutChromesPage() throws {
        let fixture = Self.fixture.deletingLastPathComponent().appendingPathComponent("PromptExtension")
        let data = FileManager.default.temporaryDirectory.appendingPathComponent("e2e-manage-\(UUID().uuidString.prefix(6))")
        let log = data.appendingPathExtension("json")
        defer { try? FileManager.default.removeItem(at: data); try? FileManager.default.removeItem(at: log) }
        let server = try TestHTTPServer(pages: Self.pages)
        let app = try AppDriver(executable: AppDriver.executableFromEnvironment!, extraEnvironment: ["BROWSER_DATA_DIR": data.path],
                                arguments: ["--load-extension=\(fixture.path)", "--log-net-log=\(log.path)"])
        guard try app.state()["engine"] as? String == "cef-chrome" else { try app.quit(); return }
        try app.open(server.url("/one"))
        var id = ""
        try app.waitUntil(timeout: 20) {
            id = (try app.state()["extensions"] as? [[String: Any]])?.first?["id"] as? String ?? ""
            return !id.isEmpty
        }
        let details = { (try app.call(["op": "extension", "id": id])["details"] as? [String: Any]) ?? [:] }
        try app.waitUntil(timeout: 20) { try details()["version"] as? String == "1.0" }
        #expect(try details()["siteAccess"] as? String == "ON_ALL_SITES")

        try app.run("extensions.set-enabled", ["id": id, "enabled": "false"])
        try app.waitUntil(timeout: 10) { try details()["enabled"] as? Bool == false }
        #expect((try app.state()["extensions"] as? [[String: Any]])?.first?["enabled"] as? Bool == false)
        try app.run("extensions.set-enabled", ["id": id, "enabled": "true"])
        try app.waitUntil(timeout: 10) { try details()["enabled"] as? Bool == true }
        try app.run("extensions.site-access", ["id": id, "access": "ON_CLICK"])
        try app.waitUntil(timeout: 10) { try details()["siteAccess"] as? String == "ON_CLICK" }
        try app.run("extensions.allow-private", ["id": id, "allowed": "true"])
        try app.waitUntil(timeout: 10) { try details()["allowedInPrivate"] as? Bool == true }

        // Removing: Chrome asks to confirm, in a window of its own kept invisible; the browser's dialog answers.
        try app.run("extensions.remove", ["id": id])
        try app.waitUntil(timeout: 10) { (try? app.run("dialogs.accept")) != nil }
        try app.waitUntil(timeout: 10) { (try app.state()["extensions"] as? [[String: Any]])?.isEmpty == true }
        let shown = ((try app.call(["op": "views"])["windows"] as? [[String: Any]]) ?? []).filter {
            ["NativeWidgetMacNSWindow", "CefNSWindow"].contains($0["class"] as? String ?? "") && ($0["alpha"] as? Double ?? 0) > 0
                && $0["visible"] as? Bool == true && !(($0["frame"] as? String) ?? "").hasSuffix("{1, 1}}")
        }
        #expect(shown.count == 1, "only the page shows: \(shown)")
        try app.quit()
        let hosts = Set(try String(contentsOf: log, encoding: .utf8).matches(of: /"url":"[a-z-]+:\/\/([^\/:"]+)/).map { String($0.1) })
        #expect(hosts.subtracting(["127.0.0.1", "localhost"]).isEmpty, "contacted \(hosts.sorted())")
    }

    /// With no page open (a first launch), an extension's welcome page still opens as a tab: `tabs.create` needs a
    /// Chrome window to start from, and each page here is one ("No current window" before); the page-less anchor
    /// stands in (with `chromium/0005`, the tab opens from it as its popups would, and the browser adopts it). With every tab closed
    /// again, the browser still quits cleanly (only that page-less window left).
    @Test func welcomePagesOpenWithNoPageOpen() throws {
        let fixture = Self.fixture.deletingLastPathComponent().appendingPathComponent("WelcomeExtension")
        let data = FileManager.default.temporaryDirectory.appendingPathComponent("e2e-welcome-\(UUID().uuidString.prefix(6))")
        let app = try AppDriver(executable: AppDriver.executableFromEnvironment!, extraEnvironment: ["BROWSER_DATA_DIR": data.path],
                                arguments: ["--load-extension=\(fixture.path)"])
        defer { try? FileManager.default.removeItem(at: data) }
        guard try app.state()["engine"] as? String == "cef-chrome" else { try app.quit(); return }
        try app.waitUntil(timeout: 20) { try app.tabs().contains { $0.title == "Welcome" } }
        _ = try app.eval("chrome.storage.local.get().then(r => document.title = r.welcome); 1")
        try app.waitUntil(timeout: 10) { try app.eval("document.title") as? String == "ok" }
        _ = try app.run("tabs.close")
        try app.waitUntil(timeout: 10) { try app.tabs().isEmpty }
        try app.quit()
    }

    /// Our Chromium build (Engines/CEF/patches): a pinned action's badge reaches the sidebar, and a download an
    /// extension's service worker starts goes through the browser instead of being canceled. Skipped on stock CEF.
    @Test func badgesAndWorkerDownloadsWithOurChromium() throws {
        let fixture = Self.fixture.deletingLastPathComponent().appendingPathComponent("BadgeExtension")
        let id = "efegbkdelhbcpnapggllgffbmklhmlgf"  // from the fixture manifest's `key`
        let data = FileManager.default.temporaryDirectory.appendingPathComponent("e2e-badge-\(UUID().uuidString.prefix(6))")
        defer { try? FileManager.default.removeItem(at: data) }
        let profile = data.appendingPathComponent("Engine/cef-chrome/Default")
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["extensions": ["pinned_extensions": [id]]]).write(to: profile.appendingPathComponent("Preferences"))
        let server = try TestHTTPServer(pages: Self.pages)
        let app = try AppDriver(executable: AppDriver.executableFromEnvironment!, extraEnvironment: ["BROWSER_DATA_DIR": data.path],
                                arguments: ["--load-extension=\(fixture.path)"])
        guard try app.state()["engine"] as? String == "cef-chrome" else { try app.quit(); return }
        try app.open(server.url("/one"))
        try app.waitUntil(timeout: 15) { try app.eval("document.title") as? String == "One" }
        guard try (app.eval("navigator.userAgent") as? String ?? "").contains("Chrome/156") else { try app.quit(); return }
        let badge = { (try app.state()["extensions"] as? [[String: Any]])?.first { $0["id"] as? String == id }?["badge"] as? String }
        try app.waitUntil(timeout: 30) { try badge() == "7" }
        let downloads = data.appendingPathComponent("Downloads")
        try app.waitUntil(timeout: 20) {
            let files = (try? FileManager.default.contentsOfDirectory(at: downloads, includingPropertiesForKeys: nil)) ?? []
            return files.contains { (try? String(contentsOf: $0, encoding: .utf8)) == "hello" }
        }
        try app.quit()
    }

    /// Chrome would draw the panel in its window chrome: the button opens it in a pane beside the content.
    @Test func sidePanelOpensFromTheButton() throws {
        guard let s = try launch() else { return }
        let id = try s.extensionID()
        try s.openProbePage()
        let panelShown = {
            let windows = try s.app.call(["op": "views"])["windows"] as? [[String: Any]] ?? []
            return windows.contains { ($0["visible"] as? Bool) == true && ($0["frame"] as? String)?.contains("{360, ") == true }
        }
        // The extension asks for its panel on the button once installed: retry until the browser has read that.
        try s.app.waitUntil(timeout: 20) {
            if try panelShown() { return true }
            _ = try s.app.run("extensions.run", ["id": id])
            return try panelShown()
        }
        try s.app.waitUntil(timeout: 15) { try s.dataset("panel") == "/panel.html" }
        #expect(try s.app.tabs().count == 1)
        try s.finish()
    }

    @Test func newTabsOpenOnTheExtensionsNewTabPage() throws {
        guard let s = try launch() else { return }
        _ = try s.extensionID()
        try s.openProbePage()
        try s.app.waitUntil(timeout: 20) {
            _ = try s.app.run("command-bar.open")
            if try s.app.tabs().contains(where: { $0.url.hasSuffix("/newtab.html") }) { return true }
            _ = try s.app.run("command-bar.open")  // the command bar opened: the extension isn't known yet
            return false
        }
        try s.app.waitUntil(timeout: 15) { try s.app.eval("document.title") as? String == "Probe new tab" }
        try s.finish()
    }

    /// DevTools keep their own window (not a tab), and extensions add their panels to it.
    @Test func devToolsKeepTheirWindowWithExtensionPanels() throws {
        guard let s = try launch() else { return }
        try s.openProbePage()
        _ = try s.app.run("navigation.devtools")
        try s.app.waitUntil(timeout: 20) { try s.dataset("devtools") == "panel created" }
        #expect(try s.app.tabs().count == 1)
        #expect(try s.app.eval("document.title") as? String == "One")
        try s.finish()
    }

    @Test func extensionShortcutsReachTheExtension() throws {
        guard let s = try launch() else { return }
        try s.openProbePage()
        try s.app.waitUntil(timeout: 20) {
            try s.app.key("y", modifiers: ["ctrl", "shift"], keyCode: 16)
            return try s.dataset("command")?.hasPrefix("probe:") == true
        }
        try s.finish()
    }
}
