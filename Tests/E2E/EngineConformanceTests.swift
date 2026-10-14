import BrowserTesting
import Foundation
import Testing

/// The same scenarios against whichever engine the bundle was built with.
/// Run with `./forkctl test --e2e` (builds the app, then sets BROWSER_E2E_APP).
@Suite(.serialized, .enabled(if: AppDriver.executableFromEnvironment != nil, "set BROWSER_E2E_APP (./forkctl test --e2e)"))
struct EngineConformanceTests {
    static let pages = [
        "/one": "<!doctype html><title>One</title><body><a id='next' href='/two'>two</a><p>needle needle</p>",
        "/two": "<!doctype html><title>Two</title><body>second page</body>",
        "/three": "<!doctype html><title>Three</title><body>third</body>",
        "/spoof": "<!doctype html><title>Spoof</title><script>setInterval(() => { if (window.__browser) for (let i = 0; i < 200; i++) window.__browser.post('__eval', { id: i, ok: true, value: 'spoofed' }); }, 5);</script><body>spoof</body>",
        "/strict": "<!doctype html><meta http-equiv='Content-Security-Policy' content=\"script-src 'none'; require-trusted-types-for 'script'\"><title>Strict</title><body>strict</body>",
    ]

    func launch() throws -> (AppDriver, TestHTTPServer) {
        let server = try TestHTTPServer(pages: Self.pages)
        let app = try AppDriver(executable: AppDriver.executableFromEnvironment!)
        return (app, server)
    }

    @Test func opensPagesAndReportsTitles() throws {
        let (app, server) = try launch()
        try app.open(server.url("/one"))
        try app.waitUntil(timeout: 15) { try app.tabs().contains { $0.title == "One" } }
        #expect(try app.eval("document.title") as? String == "One")
        try app.quit()
    }

    /// Browser-side evaluation (automation, feature scripts) must work on pages whose CSP forbids eval.
    @Test func evaluatesUnderStrictCSP() throws {
        let (app, server) = try launch()
        try app.open(server.url("/strict"))
        try app.waitUntil(timeout: 15) { try app.tabs().contains { $0.title == "Strict" } }
        #expect(try app.eval("document.title + ':' + (1 + 1)") as? String == "Strict:2")
        #expect(try app.eval("({ a: [1, 'x'] }).a.length") as? String == "2")
        try app.quit()
    }

    /// Pages can post anything, including the engine's own eval replies: results must come from the engine.
    @Test func pagesCannotForgeEvalResults() throws {
        let (app, server) = try launch()
        try app.open(server.url("/spoof"))
        try app.waitUntil(timeout: 15) { try app.tabs().contains { $0.title == "Spoof" } }
        for _ in 0..<5 { #expect(try app.eval("21 * 2") as? String == "42") }
        try app.quit()
    }

    @Test func historyNavigation() throws {
        let (app, server) = try launch()
        try app.open(server.url("/one"))
        try app.waitUntil(timeout: 15) { try app.eval("document.title") as? String == "One" }
        // Browser-initiated (Chromium skips script-created history entries without a user gesture).
        try app.navigate(server.url("/three"))
        try app.waitUntil(timeout: 15) { try app.eval("document.title") as? String == "Three" }
        try app.run("navigation.back")
        try app.waitUntil(timeout: 15) { try app.eval("document.title") as? String == "One" }
        try app.run("navigation.forward")
        try app.waitUntil(timeout: 15) { try app.eval("document.title") as? String == "Three" }
        try app.quit()
    }

    @Test func closeAndReopenTabs() throws {
        let (app, server) = try launch()
        try app.open(server.url("/one"))
        try app.open(server.url("/two"))
        try app.waitUntil(timeout: 15) { try app.tabs().filter { $0.url.contains("127.0.0.1") }.count == 2 }
        try app.run("tabs.close")
        try app.waitUntil(timeout: 10) { try app.tabs().filter { $0.url.contains("127.0.0.1") }.count == 1 }
        try app.run("tabs.reopen")
        try app.waitUntil(timeout: 10) { try app.tabs().contains { $0.url.hasSuffix("/two") } }
        try app.quit()
    }

    @Test func commandBarOpensAndCloses() throws {
        let (app, server) = try launch()
        try app.open(server.url("/one"))
        try app.run("command-bar.open")
        let flags = { ((try app.state()["windows"] as? [[String: Any]])?.first?["flags"] as? [String]) ?? [] }
        #expect(try flags().contains("command-bar"))
        try app.run("command-bar.open")
        #expect(try !flags().contains("command-bar"))
        try app.quit()
    }

    @Test func sessionSurvivesRelaunch() throws {
        let server = try TestHTTPServer(pages: Self.pages)
        let data = FileManager.default.temporaryDirectory.appendingPathComponent("e2e-session-\(UUID().uuidString.prefix(6))")
        var app = try AppDriver(executable: AppDriver.executableFromEnvironment!, extraEnvironment: ["BROWSER_DATA_DIR": data.path])
        try app.open(server.url("/one"))
        try app.open(server.url("/two"))
        try app.waitUntil(timeout: 15) { try app.tabs().filter { $0.title == "One" || $0.title == "Two" }.count == 2 }
        try app.quit()
        app = try AppDriver(executable: AppDriver.executableFromEnvironment!, extraEnvironment: ["BROWSER_DATA_DIR": data.path])
        let urls = try app.tabs().map(\.url)
        #expect(urls.filter { $0.hasSuffix("/one") || $0.hasSuffix("/two") }.count == 2)
        try app.quit()
        try? FileManager.default.removeItem(at: data)
    }

    /// The browser itself contacts no third party: an idle fresh profile only talks to loopback.
    /// Chromium only (its net log is the evidence); covers sign-in checks, network time, AI-mode probes.
    @Test func idleProfileContactsNoThirdParty() throws {
        let log = FileManager.default.temporaryDirectory.appendingPathComponent("e2e-net-\(UUID().uuidString.prefix(6)).json")
        let app = try AppDriver(executable: AppDriver.executableFromEnvironment!, arguments: ["--log-net-log=\(log.path)"])
        guard try app.state()["engine"] as? String == "cef-chrome" else { try app.quit(); return }
        Thread.sleep(forTimeInterval: 8)
        try app.quit()
        let netLog = try String(contentsOf: log, encoding: .utf8)
        let hosts = Set(netLog.matches(of: /"url":"[a-z-]+:\/\/([^\/:"]+)/).map { String($0.1) })
        #expect(hosts.subtracting(["127.0.0.1", "localhost"]).isEmpty, "contacted \(hosts.sorted())")
        try? FileManager.default.removeItem(at: log)
    }

    /// Extension actions run through Chrome's own toolbar path: the fixture's popup (activeTab + scripting, no host
    /// permissions) can only retitle the page if the click granted activeTab, and the popup must be in front of the page.
    /// Unpinned actions go through Chrome's extensions menu; pinned ones press their (hidden) toolbar button.
    @Test(arguments: [false, true]) func extensionActionGetsActiveTab(pinned: Bool) throws {
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/ActiveTabExtension")
        let id = "efdfmfjfedndlkfjgpagdmphepfimllj"  // from the fixture manifest's `key`
        let data = FileManager.default.temporaryDirectory.appendingPathComponent("e2e-ext-\(UUID().uuidString.prefix(6))")
        defer { try? FileManager.default.removeItem(at: data) }
        if pinned {
            let profile = data.appendingPathComponent("Engine/cef-chrome/Default")
            try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: ["extensions": ["pinned_extensions": [id]]])
                .write(to: profile.appendingPathComponent("Preferences"))
        }
        let server = try TestHTTPServer(pages: Self.pages)
        let app = try AppDriver(executable: AppDriver.executableFromEnvironment!, extraEnvironment: ["BROWSER_DATA_DIR": data.path],
                                arguments: ["--load-extension=\(fixture.path)"])
        guard try app.state()["engine"] as? String == "cef-chrome" else { try app.quit(); return }
        try app.open(server.url("/one"))
        try app.waitUntil(timeout: 15) { try app.eval("document.title") as? String == "One" }
        // Chrome batches preference writes (~10 s); the engine lists extensions once they are on disk.
        try app.waitUntil(timeout: 30) {
            (try app.state()["extensions"] as? [[String: Any]])?.contains { $0["id"] as? String == id && $0["pinned"] as? Bool == pinned } == true
        }
        try app.run("extensions.run", ["id": id])
        try app.waitUntil(timeout: 10) { try app.eval("document.title") as? String == "granted" }
        // Front-to-back: an engine bubble (the popup) comes before the page window.
        let windows = try app.call(["op": "views"])["windows"] as? [[String: Any]] ?? []
        let page = windows.firstIndex { $0["class"] as? String == "CefNSWindow" && $0["visible"] as? Bool == true }
        let popup = windows.firstIndex { $0["class"] as? String == "NativeWidgetMacNSWindow" && $0["visible"] as? Bool == true
            && !(($0["frame"] as? String ?? "").contains("{1, 1}")) }
        #expect(page != nil && popup != nil && popup! < page!, "windows: \(windows)")
        try app.quit()
    }

    @Test func quitsCleanly() throws {
        let (app, _) = try launch()
        try app.quit(timeout: 8)
        #expect(!app.process.isRunning)
    }
}
