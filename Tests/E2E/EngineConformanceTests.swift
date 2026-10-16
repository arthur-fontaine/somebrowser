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
        "/article": article(csp: nil),
        "/strict-article": article(csp: "script-src 'none'; style-src 'none'; require-trusted-types-for 'script'"),
        "/boost": "<!doctype html><title>Boost</title><body><div id='zapme'>ad</div><script>window.__seen = getComputedStyle(document.body).backgroundColor + ' ' + getComputedStyle(document.getElementById('zapme')).display;</script></body>",
        "/early": "<!doctype html><title>Pending</title><script>document.title = window.__early === 1 ? 'early' : 'late';</script><body>early</body>",
        "/spoof": "<!doctype html><title>Spoof</title><script>setInterval(() => { if (window.__browser) for (let i = 0; i < 200; i++) window.__browser.post('__eval', { id: i, ok: true, value: 'spoofed' }); }, 5);</script><body>spoof</body>",
        "/click": "<!doctype html><title>Click</title><body style='margin:0'><button style='position:absolute;left:20px;top:20px;width:120px;height:60px'>b</button><script>addEventListener('click', e => document.title = 'Clicked ' + e.target.tagName);</script></body>",
        "/strict": "<!doctype html><meta http-equiv='Content-Security-Policy' content=\"script-src 'none'; require-trusted-types-for 'script'\"><title>Strict</title><body>strict</body>",
    ]

    static func article(csp: String?) -> String {
        let paragraph = "The committee met on Tuesday to review the proposal in detail, weighing the costs of the new transit line against the benefits for the neighborhoods it would serve, and heard from residents who had waited years for a faster way into the city center."
        return "<!doctype html>" + (csp.map { "<meta http-equiv='Content-Security-Policy' content=\"\($0)\">" } ?? "")
            + "<title>Transit plan</title><body><nav><a href='/'>Home</a> <a href='/one'>One</a></nav><article><h1>City approves the transit plan</h1>"
            + String(repeating: "<p>\(paragraph)</p>", count: 8) + "</article><footer>© Example News</footer></body>"
    }

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

    /// Simulated responses keep the URL's origin (Sign in with Apple hands back appleid.apple.com's page).
    /// Clicking a tab in the sidebar selects it at once: a double-click gesture on the row once held every click for the
    /// double-click interval (~0.5 s) before selecting.
    @Test func sidebarClicksSelectAtOnce() throws {
        let (app, server) = try launch()
        try app.open(server.url("/one"))
        try app.open(server.url("/two"))
        try app.waitUntil(timeout: 15) { Set(try app.tabs().map(\.title)).isSuperset(of: ["One", "Two"]) }
        func selectedTitle() throws -> String? {
            let s = try app.state()
            let id = (s["windows"] as? [[String: Any]])?.first?["selected"] as? String
            let tabs = (s["spaces"] as? [[String: Any]] ?? []).flatMap { ($0["pinned"] as? [[String: Any]] ?? []) + ($0["today"] as? [[String: Any]] ?? []) }
            return tabs.first { $0["id"] as? String == id }?["title"] as? String
        }
        let target = try selectedTitle() == "One" ? "Two" : "One"
        let start = Date()
        #expect(try app.call(["op": "clickTitle", "title": target])["ok"] as? Bool == true)
        try app.waitUntil(timeout: 3) { try selectedTitle() == target }
        #expect(Date().timeIntervalSince(start) < 0.25)
        try app.quit()
    }

    /// A click reaches the page: nothing of the window's own covers it (Chromium routes clicks by the views under the
    /// pointer, and CEF's overlay host view once took them all).
    @Test func clicksReachThePage() throws {
        let (app, server) = try launch()
        try app.open(server.url("/click"))
        try app.waitUntil(timeout: 15) { try app.tabs().contains { $0.title == "Click" } }
        let hit = try app.click(x: 60, y: 40)
        try app.waitUntil(timeout: 5) { try app.eval("document.title") as? String == "Clicked BUTTON" }
        #expect(!hit.isEmpty)
        try app.quit()
    }

    @Test func simulatedResponsesKeepTheirOrigin() throws {
        let (app, server) = try launch()
        try app.open(server.url("/one"))
        try app.waitUntil(timeout: 15) { try app.eval("document.title") as? String == "One" }
        try app.simulate("https://simulated.example/callback", html: "<!doctype html><title>Simulated</title><body>ok</body>")
        try app.waitUntil(timeout: 15) { try app.eval("document.title + ' ' + location.origin") as? String == "Simulated https://simulated.example" }
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

    /// Document-start scripts run before the page's own scripts, ignore page CSP, and don't follow later navigations.
    @Test func documentStartScriptsRunBeforeThePage() throws {
        let (app, server) = try launch()
        try app.documentStart("window.__early = 1;", prefix: server.url("/early"))
        try app.documentStart("document.addEventListener('DOMContentLoaded', () => { document.title += '+'; });", prefix: server.url("/strict"))
        try app.open(server.url("/early"))
        try app.waitUntil(timeout: 15) { try app.eval("document.title") as? String == "early" }
        try app.navigate(server.url("/strict"))
        try app.waitUntil(timeout: 15) { try app.eval("document.title") as? String == "Strict+" }
        try app.navigate(server.url("/one"))
        try app.waitUntil(timeout: 15) { try app.eval("document.title") as? String == "One" }
        #expect(try app.eval("String(window.__early)") as? String == "undefined")
        try app.quit()
    }

    /// Performance budgets: switching tabs costs under 16 ms of main-thread time (drawing included, median), and the
    /// app process stays under 150 MB with pages open (renderers and GPU are separate processes).
    @Test func staysWithinPerformanceBudgets() throws {
        let (app, server) = try launch()
        for page in ["/one", "/two", "/three", "/early"] { try app.open(server.url(page)) }
        try app.waitUntil(timeout: 20) { try app.tabs().filter { $0.url.contains("127.0.0.1") && !$0.title.isEmpty }.count == 4 }
        // One switch at a time, as a person would (each measured on its own, not queued behind the previous).
        let runs = try (0..<24).map { _ in
            Thread.sleep(forTimeInterval: 0.1)
            return try app.run("tabs.next")
        }
        let switches = runs.map(\.drawn).sorted()
        let median = switches[switches.count / 2]
        print("tab switch ms: median \(median), max \(switches.last!), command median \(runs.map(\.ms).sorted()[runs.count / 2])")
        #expect(median < 16)
        // Steady state: graphics memory from the switches is reclaimed within moments.
        var footprint = try app.footprint()
        for _ in 0..<20 where footprint >= 150 << 20 { Thread.sleep(forTimeInterval: 0.5); footprint = try app.footprint() }
        print("app footprint MB:", footprint >> 20)
        #expect(footprint > 0 && footprint < 150 << 20)
        try app.quit()
    }

    /// Reader shows the article over the page, closes again, and works on a page with a strict CSP.
    @Test func readerShowsTheArticle() throws {
        let (app, server) = try launch()
        let shown = "String((document.getElementById('__browser_reader')?.shadowRoot?.textContent || '').includes('City approves the transit plan'))"
        for page in ["/article", "/strict-article"] {
            try app.open(server.url(page))
            try app.waitUntil(timeout: 15) { try app.eval("document.title") as? String == "Transit plan" }
            try app.run("reader.toggle")
            try app.waitUntil(timeout: 10) { try app.eval(shown) as? String == "true" }
            try app.run("reader.toggle")
            try app.waitUntil(timeout: 10) { try app.eval("String(!document.getElementById('__browser_reader'))") as? String == "true" }
        }
        // Not an article: nothing opens.
        try app.open(server.url("/two"))
        try app.waitUntil(timeout: 15) { try app.eval("document.title") as? String == "Two" }
        try app.run("reader.toggle")
        Thread.sleep(forTimeInterval: 0.5)
        #expect(try app.eval("String(!!document.getElementById('__browser_reader'))") as? String == "false")
        try app.quit()
    }

    /// A tab with typed input isn't hibernated.
    @Test func editedTabsAreNotHibernated() throws {
        let (app, server) = try launch()
        try app.open(server.url("/article"))
        try app.waitUntil(timeout: 15) { try app.eval("document.title") as? String == "Transit plan" }
        _ = try app.eval("(() => { const i = document.createElement('textarea'); document.body.append(i); i.value = 'draft'; i.dispatchEvent(new Event('input', { bubbles: true })); return 'typed'; })()")
        Thread.sleep(forTimeInterval: 0.5)
        try app.open(server.url("/two"))
        try app.waitUntil(timeout: 15) { try app.eval("document.title") as? String == "Two" }
        try app.run("hibernation.hibernate-background")
        let loaded = try app.state()["spaces"].flatMap { spaces -> Bool? in
            for space in spaces as? [[String: Any]] ?? [] {
                for t in (space["today"] as? [[String: Any]] ?? []) where (t["url"] as? String)?.hasSuffix("/article") == true { return t["loaded"] as? Bool }
            }
            return nil
        }
        #expect(loaded == true)
        try app.quit()
    }

    /// A Boost's CSS (zapped elements included) is in place before the page's scripts run; its script runs once parsed.
    @Test func boostsApplyBeforeThePage() throws {
        let (app, server) = try launch()
        let boost = ##"{"enabled":true,"css":"body { background: rgb(1, 2, 3) !important; }","js":"document.title += ' boosted';","zapped":["#zapme"]}"##
        try app.call(["op": "setting", "key": "boosts.boost", "value": boost, "site": "127.0.0.1"])
        try app.open(server.url("/boost"))
        try app.waitUntil(timeout: 15) { try app.eval("document.title") as? String == "Boost boosted" }
        #expect(try app.eval("window.__seen") as? String == "rgb(1, 2, 3) none")
        try app.quit()
    }

    /// Air Traffic Control: links from other apps follow the rules; a main-window rule beats mini windows.
    @Test func linksFromOtherAppsFollowTheRules() throws {
        let server = try TestHTTPServer(pages: Self.pages)
        let data = FileManager.default.temporaryDirectory.appendingPathComponent("e2e-atc-\(UUID().uuidString.prefix(6))")
        defer { try? FileManager.default.removeItem(at: data) }
        let rules = data.appendingPathComponent("Features/air-traffic/rules.json")
        try FileManager.default.createDirectory(at: rules.deletingLastPathComponent(), withIntermediateDirectories: true)
        let json = #"[{"id":"\#(UUID())","pattern":"127.0.0.1/one","destination":{"mainWindow":{}}},"#
            + #"{"id":"\#(UUID())","pattern":"127.0.0.1/two","destination":{"miniWindow":{}}}]"#
        try json.write(to: rules, atomically: true, encoding: .utf8)
        let app = try AppDriver(executable: AppDriver.executableFromEnvironment!, extraEnvironment: ["BROWSER_DATA_DIR": data.path])
        let windows = { (try app.state()["windows"] as? [[String: Any]]) ?? [] }
        let start = try windows().count
        try app.call(["op": "openExternal", "url": server.url("/one")])
        try app.waitUntil(timeout: 15) { try app.tabs().contains { $0.url.hasSuffix("/one") } }
        #expect(try windows().count == start)
        // No rule: mini windows take links from other apps (the default), which the rule above overrode.
        try app.call(["op": "openExternal", "url": server.url("/three")])
        try app.waitUntil(timeout: 15) { try windows().count == start + 1 }
        try app.call(["op": "openExternal", "url": server.url("/two")])
        try app.waitUntil(timeout: 15) { try windows().filter { ($0["flags"] as? [String])?.contains("mini-window") == true }.count == 2 }
        try app.quit()
    }

    /// Split view: two pages side by side; switching panes swaps them; closing leaves one.
    @Test func splitViewShowsTwoPages() throws {
        let (app, server) = try launch()
        try app.open(server.url("/one"))
        try app.open(server.url("/two"))
        try app.waitUntil(timeout: 15) { try app.eval("document.title") as? String == "Two" }
        /// Page frames on screen: Chromium pages are child windows, WebKit pages are web views.
        let pages = { () throws -> [String] in
            let views = try app.call(["op": "views"])
            let windows = (views["windows"] as? [[String: Any]] ?? []).filter { $0["class"] as? String == "CefNSWindow" && $0["visible"] as? Bool == true }
            let webViews = (views["views"] as? [[String: Any]] ?? []).filter { $0["class"] as? String == "WKWebView" && $0["hidden"] as? Bool == false }
            return (windows + webViews).compactMap { $0["frame"] as? String }
        }
        #expect(try pages().count == 1)
        try app.run("split-view.open")
        try app.waitUntil(timeout: 10) { try Set(pages()).count == 2 }
        try app.run("split-view.swap")
        try app.waitUntil(timeout: 10) { try app.eval("document.title") as? String == "One" }
        try app.waitUntil(timeout: 10) { try Set(pages()).count == 2 }
        try app.run("split-view.close")
        try app.waitUntil(timeout: 10) { try pages().count == 1 }
        try app.quit()
    }

    /// A hibernated tab wakes on its page with its back/forward history.
    @Test func hibernatedTabsWakeWithTheirHistory() throws {
        let (app, server) = try launch()
        try app.open(server.url("/one"))
        try app.waitUntil(timeout: 15) { try app.eval("document.title") as? String == "One" }
        try app.navigate(server.url("/three"))
        try app.waitUntil(timeout: 15) { try app.eval("document.title") as? String == "Three" }
        try app.open(server.url("/two"))
        try app.waitUntil(timeout: 15) { try app.eval("document.title") as? String == "Two" }
        let loaded = { (suffix: String) throws -> Bool? in
            var found: Bool?
            func walk(_ t: [String: Any]) {
                if (t["url"] as? String)?.hasSuffix(suffix) == true { found = t["loaded"] as? Bool }
                for c in t["children"] as? [[String: Any]] ?? [] { walk(c) }
            }
            for space in try app.state()["spaces"] as? [[String: Any]] ?? [] {
                for t in (space["pinned"] as? [[String: Any]] ?? []) + (space["today"] as? [[String: Any]] ?? []) { walk(t) }
            }
            return found
        }
        try app.run("hibernation.hibernate-background")
        #expect(try loaded("/three") == false)
        #expect(try loaded("/two") == true)
        try app.run("tabs.select-last")
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

    /// MV3: a content script runs on the page and talks to its service worker (messaging and storage).
    @Test func contentScriptsTalkToTheirWorker() throws {
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/ContentScriptExtension")
        let data = FileManager.default.temporaryDirectory.appendingPathComponent("e2e-cs-\(UUID().uuidString.prefix(6))")
        defer { try? FileManager.default.removeItem(at: data) }
        let server = try TestHTTPServer(pages: Self.pages)
        let app = try AppDriver(executable: AppDriver.executableFromEnvironment!, extraEnvironment: ["BROWSER_DATA_DIR": data.path],
                                arguments: ["--load-extension=\(fixture.path)"])
        guard try app.state()["engine"] as? String == "cef-chrome" else { try app.quit(); return }
        try app.open(server.url("/one"))
        try app.waitUntil(timeout: 20) { try app.eval("String(document.documentElement.dataset.extension)") as? String == "worker:32" }
        try app.quit()
    }

    @Test func quitsCleanly() throws {
        let (app, _) = try launch()
        try app.quit(timeout: 8)
        #expect(!app.process.isRunning)
    }
}
