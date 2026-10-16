import BrowserTesting
import Foundation
import Testing

/// The private space keeps nothing: its cookies and storage are apart from your tabs', and gone once its last tab
/// closes. Leaving it locks it: coming back shows none of its pages until Touch ID says yes. Every engine.
@Suite(.serialized, .enabled(if: AppDriver.executableFromEnvironment != nil, "set BROWSER_E2E_APP (./forkctl test --e2e)"))
struct PrivateBrowsingTests {
    static let pages = ["/p": "<!doctype html><title>P</title><body>p</body>"]

    func launch(touchID: String) throws -> (AppDriver, URL) {
        let data = FileManager.default.temporaryDirectory.appendingPathComponent("e2e-private-\(UUID().uuidString.prefix(6))")
        let app = try AppDriver(executable: AppDriver.executableFromEnvironment!,
                                extraEnvironment: ["BROWSER_DATA_DIR": data.path, "BROWSER_TEST_TOUCH_ID": touchID])
        return (app, data)
    }

    func window(_ app: AppDriver) throws -> [String: Any] { (try app.state()["windows"] as? [[String: Any]])?.first ?? [:] }
    func spaces(_ app: AppDriver) throws -> [String] { (try app.state()["spaces"] as? [[String: Any]] ?? []).compactMap { $0["kind"] as? String } }

    @Test func privateTabsShareNothingAndForget() throws {
        let server = try TestHTTPServer(pages: Self.pages)
        let (app, data) = try launch(touchID: "allow")
        defer { try? FileManager.default.removeItem(at: data) }
        func title() throws -> String? { try app.eval("document.title") as? String }
        func openPrivatePage() throws {
            _ = try app.run("tabs.new-private-tab")
            try app.navigate(server.url("/p"))
            try app.waitUntil(timeout: 15) { try title() == "P" }
        }

        try app.open(server.url("/p"))
        try app.waitUntil(timeout: 15) { try title() == "P" }
        _ = try app.eval("document.cookie = 'normal=1; max-age=3600'; localStorage.setItem('normal', '1'); 'ok'")
        #expect(try spaces(app) == ["normal"])

        try openPrivatePage()
        #expect(try window(app)["private"] as? Bool == true)
        #expect(try spaces(app) == ["normal", "private"])
        #expect(try app.eval("document.cookie + '|' + localStorage.getItem('normal')") as? String == "|null")
        _ = try app.eval("document.cookie = 'secret=1; max-age=3600'; localStorage.setItem('secret', '1'); 'ok'")

        _ = try app.run("spaces.previous")
        try app.waitUntil(timeout: 5) { try window(app)["private"] as? Bool == false }
        #expect(try app.eval("document.cookie + '|' + localStorage.getItem('secret')") as? String == "normal=1|null")

        // Back in: unlocked by Touch ID (answered yes), the private page again.
        _ = try app.run("spaces.next")
        try app.waitUntil(timeout: 5) { try window(app)["private"] as? Bool == true && window(app)["locked"] as? Bool == false }
        #expect(try app.eval("document.cookie") as? String == "secret=1")

        // Its last tab closed, the private space ends; a new one knows nothing of it.
        _ = try app.run("tabs.close")
        try app.waitUntil(timeout: 10) { try spaces(app) == ["normal"] }
        try openPrivatePage()
        #expect(try app.eval("document.cookie + '|' + localStorage.getItem('secret')") as? String == "|null")
        try app.quit()
    }

    /// The browser window's own controls, as accessibility reads them (the address bar's text).
    func browserControls(_ app: AppDriver) throws -> String {
        let windows = try app.call(["op": "views"])["windows"] as? [[String: Any]] ?? []
        let shell = windows.first { $0["class"] as? String == "ShellWindow" }?["number"] as? Int ?? 0
        return (try app.call(["op": "ax", "number": shell])["ax"] as? [String] ?? []).joined(separator: "\n")
    }

    /// Touch ID refused: the private space stays locked and none of its pages is on screen, nor its address.
    @Test func lockedPrivateSpacesShowNoPage() throws {
        let server = try TestHTTPServer(pages: Self.pages)
        let (app, data) = try launch(touchID: "deny")
        defer { try? FileManager.default.removeItem(at: data) }
        _ = try app.run("tabs.new-private-tab")
        try app.navigate(server.url("/p"))
        try app.waitUntil(timeout: 15) { try app.eval("document.title") as? String == "P" }
        try app.waitUntil(timeout: 5) { try browserControls(app).contains("127.0.0.1") }
        _ = try app.run("spaces.previous")
        _ = try app.run("spaces.next")
        try app.waitUntil(timeout: 5) { try window(app)["locked"] as? Bool == true }
        #expect(try !browserControls(app).contains("127.0.0.1"))
        let views = try app.call(["op": "views"])
        let pageWindows = (views["windows"] as? [[String: Any]] ?? []).filter {
            $0["class"] as? String == "CefNSWindow" && $0["visible"] as? Bool == true && ($0["parent"] as? Int ?? 0) != 0
        }
        let webViews = (views["views"] as? [[String: Any]] ?? []).filter { $0["class"] as? String == "WKWebView" && $0["hidden"] as? Bool == false }
        #expect(pageWindows.isEmpty && webViews.isEmpty)
        try app.quit()
    }
}
