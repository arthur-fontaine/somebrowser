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

    /// `tabs.create` opens the page as a tab of the window (Chrome makes it in a window of its own, which the browser
    /// adopts: the id returned to the extension doesn't last; see the Extensions README), and `tabs.remove` closes it.
    @Test func extensionsOpenAndCloseTabs() throws {
        guard let s = try launch() else { return }
        try s.openProbePage()
        _ = try s.probe("tabs")
        try s.app.waitUntil(timeout: 15) { try s.app.tabs().contains { $0.title == "Two" } }
        _ = try s.app.run("tabs.select-2")  // back to the probe page
        #expect(try s.probe("remove") == "\"removed 1\"")
        try s.app.waitUntil(timeout: 15) { try !s.app.tabs().contains { $0.title == "Two" } }
        #expect(try s.app.tabs().map(\.title) == ["One"])
        try s.finish()
    }

    /// With no page open (a first launch), an extension's welcome page still opens as a tab: `tabs.create` needs a
    /// Chrome window to start from, and each page here is one ("No current window" before).
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
