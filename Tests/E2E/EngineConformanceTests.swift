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
        "/field": "<!doctype html><title>Field</title><body><input id='i' value='hello world'></body>",
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

    /// A click on a tab puts its page on screen within a frame or two: the page turns visible and paints (two animation
    /// frames: one presented) right after the click, Chromium's side included.
    @Test func clickedTabsPaintAtOnce() throws {
        // Each page notes when it turns visible and when it has painted since.
        let script = "<script>window.__shown=[];document.addEventListener('visibilitychange',()=>{if(!document.hidden){const t=performance.timeOrigin+performance.now();requestAnimationFrame(()=>requestAnimationFrame(()=>__shown.push(performance.timeOrigin+performance.now())));}});</script>"
        let server = try TestHTTPServer(pages: ["/a": "<!doctype html><title>A</title>\(script)<body>a", "/b": "<!doctype html><title>B</title>\(script)<body>b"])
        let app = try AppDriver(executable: AppDriver.executableFromEnvironment!)
        try app.open(server.url("/a"))
        try app.open(server.url("/b"))
        try app.waitUntil(timeout: 15) { Set(try app.tabs().map(\.title)).isSuperset(of: ["A", "B"]) }
        var delays: [Double] = []
        for target in ["A", "B", "A", "B", "A", "B", "A", "B"] {
            Thread.sleep(forTimeInterval: 0.4)
            let clicked = Date().timeIntervalSince1970 * 1000
            #expect(try app.call(["op": "clickTitle", "title": target])["ok"] as? Bool == true)
            var painted: Double?
            try app.waitUntil(timeout: 3) {
                painted = Double(try app.eval("String(__shown[__shown.length - 1] || '')") as? String ?? "")
                return try app.eval("document.title") as? String == target && painted.map { $0 > clicked } == true
            }
            delays.append(painted! - clicked)
        }
        delays.sort()
        print("click to painted ms:", delays.map { Int($0) })
        #expect(delays[delays.count / 2] < 33)
        try app.quit()
    }

    /// With the sidebar hidden there's no top bar: the page reaches the window's top edge (but for the content inset),
    /// as it reaches its left edge. Everything lives in the sidebar.
    @Test func hiddenSidebarLeavesNoTopBar() throws {
        let (app, server) = try launch()
        guard try app.state()["engine"] as? String == "cef-chrome" else { return try app.quit() }  // pages are windows
        try app.open(server.url("/one"))
        try app.waitUntil(timeout: 15) { try app.eval("document.title") as? String == "One" }
        func frames() throws -> (shell: NSRect, page: NSRect) {
            let windows = try app.call(["op": "views"])["windows"] as? [[String: Any]] ?? []
            let shell = windows.first { $0["class"] as? String == "ShellWindow" }
            let page = windows.first { $0["class"] as? String == "CefNSWindow" && $0["parent"] as? Int == shell?["number"] as? Int }
            return (NSRectFromString(shell?["frame"] as? String ?? ""), NSRectFromString(page?["frame"] as? String ?? ""))
        }
        let shown = try frames()
        #expect(shown.page.minX - shown.shell.minX > 100)  // the sidebar's room
        try app.run("sidebar.toggle")
        try app.waitUntil(timeout: 5) { let f = try frames(); return f.page.minX - f.shell.minX < 10 }
        let hidden = try frames()
        // Only the window's one margin (Design.windowInset, 8 pt) around the page: no bar above it.
        #expect(hidden.shell.maxY - hidden.page.maxY <= 8.5)
        #expect(hidden.page.minX - hidden.shell.minX <= 8.5)
        try app.quit()
    }

    /// A download is the browser's own (the Downloads feature): Chrome's download bubble doesn't pop up beside it, nor
    /// its "download started" animation flying to its (hidden) downloads button.
    @Test func downloadsShowNoChromeBubble() throws {
        let server = try TestHTTPServer(pages: [:], responders: [
            "/file": { _ in (["Content-Disposition: attachment; filename=\"file.bin\""], String(repeating: "x", count: 100_000)) },
        ])
        let app = try AppDriver(executable: AppDriver.executableFromEnvironment!)
        try app.open(server.url("/file"))
        var bubbles: [String] = []
        for _ in 0..<80 {
            let windows = try app.call(["op": "views"])["windows"] as? [[String: Any]] ?? []
            // Chrome's bubble (a views widget of its own, 320 points wide) or its 64-point animation, shown.
            bubbles += windows.filter { w in w["class"] as? String == "NativeWidgetMacNSWindow" && w["visible"] as? Bool == true
                && (w["alpha"] as? Double ?? 0) > 0 && ["{320,", "{64, 64}"].contains { (w["frame"] as? String ?? "").contains($0) } }
                .compactMap { $0["frame"] as? String }
            Thread.sleep(forTimeInterval: 0.03)
        }
        let downloads = app.directory.appendingPathComponent("data/Downloads/file.bin")
        try app.waitUntil(timeout: 10) { FileManager.default.fileExists(atPath: downloads.path) }
        #expect(bubbles.isEmpty)
        try app.quit()
    }

    /// A form posted to another site (Google Lens's upload from google.com) arrives with its data, in its tab: Link
    /// Tree opens links to other sites as child tabs, which would load the URL without the form's data.
    @Test func formsPostToOtherSitesInPlace() throws {
        let server = try TestHTTPServer(pages: [:], responders: [
            "/upload": { request in ([], "<!doctype html><title>\(request.contains("picture=cat") ? "Received" : "Empty")</title>") },
        ])
        let page = """
            <!doctype html><title>Form</title><form method=post action="http://localhost:\(server.port)/upload">
            <input type=hidden name=picture value=cat><button style="position:fixed;left:0;top:0;width:200px;height:80px">Send</button></form>
            """
        let pages = try TestHTTPServer(pages: ["/form": page])
        let app = try AppDriver(executable: AppDriver.executableFromEnvironment!)
        try app.open(pages.url("/form"))
        try app.waitUntil(timeout: 15) { try app.eval("document.title") as? String == "Form" }
        try app.click(x: 60, y: 30)
        try app.waitUntil(timeout: 15) { try app.tabs().contains { $0.title == "Received" || $0.title == "Empty" } }
        #expect(try app.tabs().map(\.title) == ["Received"])
        try app.quit()
    }

    /// A hovered (here focused) link shows in the browser's own box (Link Tree), not in Chrome's status bubble at the
    /// page's corner too.
    @Test func hoveredLinksShowNoChromeBubble() throws {
        let server = try TestHTTPServer(pages: ["/link": "<!doctype html><title>Link</title><a href='https://example.org/somewhere'>link</a>"])
        let app = try AppDriver(executable: AppDriver.executableFromEnvironment!)
        guard try app.state()["engine"] as? String == "cef-chrome" else { try app.quit(); return }
        try app.open(server.url("/link"))
        try app.waitUntil(timeout: 15) { try app.eval("document.title") as? String == "Link" }
        _ = try app.eval("document.querySelector('a').focus(); 1")
        var bubbles: [String] = []
        for _ in 0..<40 {
            let windows = try app.call(["op": "views"])["windows"] as? [[String: Any]] ?? []
            bubbles += windows.filter { w in w["class"] as? String == "NativeWidgetMacNSWindow" && w["visible"] as? Bool == true
                && (w["alpha"] as? Double ?? 0) > 0 && !(w["frame"] as? String ?? "").hasSuffix("{1, 1}}") }.compactMap { $0["frame"] as? String }
            Thread.sleep(forTimeInterval: 0.03)
        }
        #expect(bubbles.isEmpty, "Chrome windows shown: \(bubbles)")
        try app.quit()
    }

    /// A tab Claude acts on (the Claude in Chrome extension marks it with its glow, in a closed shadow root) moves to the
    /// Claude space.
    @Test func claudesTabsGoToTheClaudeSpace() throws {
        let server = try TestHTTPServer(pages: [
            "/mine": "<!doctype html><title>Mine</title><body>mine</body>",
            "/claude": """
            <!doctype html><title>Claude</title><body><script>setTimeout(() => {
              const host = document.createElement('div'), root = host.attachShadow({ mode: 'closed' });
              root.innerHTML = '<style>:host { all: initial !important; display: contents !important; }</style><div id="claude-agent-glow-border"></div>';
              document.body.appendChild(host);
            }, 300);</script></body>
            """,
        ])
        let app = try AppDriver(executable: AppDriver.executableFromEnvironment!)
        try app.open(server.url("/mine"))
        try app.open(server.url("/claude"))
        func spaces() throws -> [[String: Any]] { try app.state()["spaces"] as? [[String: Any]] ?? [] }
        try app.waitUntil(timeout: 15) { try spaces().contains { $0["kind"] as? String == "claude" } }
        let claude = try spaces().first { $0["kind"] as? String == "claude" }
        #expect((claude?["today"] as? [[String: Any]])?.map { $0["title"] as? String } == ["Claude"])
        let normal = try spaces().first { $0["kind"] as? String == "normal" }
        #expect((normal?["today"] as? [[String: Any]])?.compactMap { $0["title"] as? String } == ["Mine"])
        try app.quit()
    }

    /// A page's confirm and a site's sign-in are the browser's own dialogs (no Chrome or WebKit dialog window), and their
    /// answers reach the page.
    @Test func pageDialogsAreTheBrowsers() throws {
        let server = try TestHTTPServer(pages: [
            "/confirm": "<!doctype html><title>start</title><body><script>setTimeout(() => { document.title = confirm('Sure?') ? 'yes' : 'no'; }, 200);</script></body>",
        ], responders: [
            "/members": { request in
                request.contains("Authorization: Basic bWU6cHc=")  // me:pw
                    ? ([], "<!doctype html><title>Welcome me</title>")
                    : (["Status: 401 Unauthorized", "WWW-Authenticate: Basic realm=\"Members\""], "<!doctype html><title>Denied</title>")
            },
        ])
        let app = try AppDriver(executable: AppDriver.executableFromEnvironment!)
        func otherWindows() throws -> [String] {
            (try app.call(["op": "views"])["windows"] as? [[String: Any]] ?? []).filter {
                $0["visible"] as? Bool == true && !["ShellWindow", "CefNSWindow"].contains($0["class"] as? String ?? "")
                    && !($0["frame"] as? String ?? "").contains("{1, 1}")
            }.compactMap { "\($0["class"] ?? "") \($0["frame"] ?? "")" }
        }
        func answer(_ args: [String: String] = [:]) throws {
            try app.waitUntil(timeout: 15) { try app.call(["op": "run", "command": "dialogs.accept", "args": args])["ok"] as? Bool == true }
        }
        try app.open(server.url("/confirm"))
        try app.waitUntil(timeout: 15) { try app.call(["op": "run", "command": "dialogs.accept", "args": [:]])["ok"] as? Bool == false
            && app.tabs().contains { $0.title == "start" } }
        Thread.sleep(forTimeInterval: 0.6)
        #expect(try otherWindows().isEmpty)
        try answer()
        try app.waitUntil(timeout: 10) { try app.eval("document.title") as? String == "yes" }

        try app.navigate(server.url("/members"))
        Thread.sleep(forTimeInterval: 0.6)
        let shown = try otherWindows()
        #expect(shown.isEmpty, "\(shown)")
        try answer(["username": "me", "password": "pw"])
        try app.waitUntil(timeout: 10) { try app.eval("document.title") as? String == "Welcome me" }
        try app.quit()
    }

    /// A site that can't be reached shows the browser's own page at its address (not Chrome's, not WebKit's blank one).
    @Test func unreachableSitesShowTheBrowsersPage() throws {
        let app = try AppDriver(executable: AppDriver.executableFromEnvironment!)
        // A port nothing listens on: the connection is refused.
        let port = try { try TestHTTPServer(pages: [:]).port }()  // the server is gone once its port is known
        let url = "http://127.0.0.1:\(port)/nothing"
        Thread.sleep(forTimeInterval: 0.3)
        try app.open(url)
        try app.waitUntil(timeout: 15) { try app.eval("document.title") as? String == "Can’t Open 127.0.0.1" }
        #expect(try app.eval("location.href") as? String == url)
        #expect(try app.eval("document.querySelector('button').textContent") as? String == "Try Again")
        try app.quit()
    }

    /// Chrome's own password, autofill and translate offers stay off (the browser's own features replace them).
    @Test func chromesOwnOffersAreOff() throws {
        let server = try TestHTTPServer(pages: ["/one": "<!doctype html><title>One</title>"])
        let app = try AppDriver(executable: AppDriver.executableFromEnvironment!)
        guard try app.state()["engine"] as? String == "cef-chrome" else { try app.quit(); return }
        try app.open(server.url("/one"))
        try app.waitUntil(timeout: 15) { try app.tabs().contains { $0.title == "One" } }
        try app.quit()
        let file = app.directory.appendingPathComponent("data/Engine/cef-chrome/Default/Preferences")
        let prefs = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        #expect(prefs["credentials_enable_service"] as? Bool == false)
        #expect((prefs["autofill"] as? [String: Any])?["profile_enabled"] as? Bool == false)
        #expect((prefs["autofill"] as? [String: Any])?["credit_card_enabled"] as? Bool == false)
        #expect((prefs["translate"] as? [String: Any])?["enabled"] as? Bool == false)
    }

    /// Chrome's new-tab page (Google's; an extension's `tabs.create({url: "chrome://newtab"})` asks for it) never
    /// shows: the page shows the browser's own new tab, blank.
    @Test func chromesNewTabPageIsTheBrowsers() throws {
        let server = try TestHTTPServer(pages: ["/one": "<!doctype html><title>One</title>"])
        let app = try AppDriver(executable: AppDriver.executableFromEnvironment!)
        guard try app.state()["engine"] as? String == "cef-chrome" else { try app.quit(); return }
        try app.open(server.url("/one"))
        try app.waitUntil(timeout: 15) { try app.tabs().contains { $0.title == "One" } }
        try app.navigate("chrome://newtab/")
        try app.waitUntil(timeout: 10) { try app.eval("location.href") as? String == "about:blank" }
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

    /// In a website's text field, ⌘← is the field's (to the line's start), not the browser's Back; out of it, Back.
    @Test func textFieldsKeepTheirEditingKeys() throws {
        let (app, server) = try launch()
        try app.open(server.url("/one"))
        try app.waitUntil(timeout: 15) { try app.eval("document.title") as? String == "One" }
        try app.navigate(server.url("/field"))
        try app.waitUntil(timeout: 15) { try app.eval("document.title") as? String == "Field" }
        let cmdLeft = { try app.key("\u{F702}", modifiers: ["cmd"], keyCode: 123, inPage: true) }
        _ = try app.eval("const i = document.getElementById('i'); i.focus(); i.setSelectionRange(11, 11); 1")
        try cmdLeft()
        try app.waitUntil(timeout: 5) { try app.eval("String(document.getElementById('i').selectionStart)") as? String == "0" }
        Thread.sleep(forTimeInterval: 0.6)
        #expect(try app.eval("document.title") as? String == "Field")
        _ = try app.eval("document.activeElement.blur(); 1")
        try cmdLeft()
        try app.waitUntil(timeout: 15) { try app.eval("document.title") as? String == "One" }
        try app.quit()
    }

    /// While Settings has the keyboard, the browser's shortcuts stay off: ⌘← doesn't take the page back, ⌘W closes
    /// Settings, not the tab. Back in the browser, ⌘← is Back again.
    @Test func settingsKeepsItsKeys() throws {
        let (app, server) = try launch()
        try app.open(server.url("/one"))
        try app.waitUntil(timeout: 15) { try app.eval("document.title") as? String == "One" }
        try app.navigate(server.url("/three"))
        try app.waitUntil(timeout: 15) { try app.eval("document.title") as? String == "Three" }
        let keyWindow = { try app.call(["op": "views"])["keyWindow"] as? String ?? "" }
        let back = { try app.key("\u{F702}", modifiers: ["cmd"], keyCode: 123, inPage: false) }

        try app.key(",", modifiers: ["cmd"], keyCode: 43, inPage: false)
        // Settings gets the keyboard only in the frontmost app: with another app in front (a person using theirs,
        // which macOS won't let a test take over), there's nothing to check.
        var hasKeyboard = false
        withKnownIssue("the app isn't frontmost", isIntermittent: true) {
            try app.waitUntil(timeout: 5) { try keyWindow().hasPrefix("SettingsWindow") }
            hasKeyboard = true
        }
        guard hasKeyboard else { return try app.quit() }
        try back()
        Thread.sleep(forTimeInterval: 1)
        #expect(try app.eval("document.title") as? String == "Three")
        try app.key("w", modifiers: ["cmd"], keyCode: 13, inPage: false)
        try app.waitUntil(timeout: 5) { try !keyWindow().hasPrefix("SettingsWindow") }
        #expect(try app.tabs().count == 1)

        try back()
        try app.waitUntil(timeout: 15) { try app.eval("document.title") as? String == "One" }
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
    /// Pinned ones press their (hidden) toolbar button; one not pinned at launch is pinned once listed (Chrome's menu runs
    /// it until then).
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
