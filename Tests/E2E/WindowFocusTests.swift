import BrowserTesting
import Foundation
import Testing

/// Focus as a person meets it, with the app in front (only the frontmost app has a key window): the page is a child
/// window of the browser window, and clicks from it to the sidebar used to be first clicks that only moved key. It
/// brings the app over whatever is in front, so it runs only when asked to (BROWSER_E2E_FRONTMOST=1).
@Suite(.serialized, .enabled(if: AppDriver.executableFromEnvironment != nil
                                && ProcessInfo.processInfo.environment["BROWSER_E2E_FRONTMOST"] == "1",
                             "set BROWSER_E2E_APP and BROWSER_E2E_FRONTMOST=1 (it takes the screen)"))
struct WindowFocusTests {
    /// The address field, from the browser window's top-left (the docked sidebar's; the floating one lies 8 pt in).
    static let address = (x: 130.0, y: 70.0), floatingAddress = (x: 130.0, y: 78.0)

    func launch() throws -> (AppDriver, TestHTTPServer) {
        let server = try TestHTTPServer(pages: ["/": "<title>Page</title><body style='height:100vh'>page</body>"])
        let app = try AppDriver(executable: AppDriver.executableFromEnvironment!)
        try app.open(server.url("/"))
        try app.waitUntil(timeout: 10) { try app.tabs().contains { $0.title == "Page" } }
        try app.call(["op": "activate"])
        try app.waitUntil(timeout: 5) { try app.state()["appActive"] as? Bool == true }
        return (app, server)
    }

    func click(_ app: AppDriver, _ window: String, _ x: Double, _ y: Double) throws {
        try app.call(["op": "mouse", "window": window, "events": [
            ["type": "move", "x": x, "y": y], ["type": "down", "x": x, "y": y], ["type": "up", "x": x, "y": y],
        ]])
    }

    func window(_ app: AppDriver) throws -> [String: Any] { (try app.state()["windows"] as? [[String: Any]])?.first ?? [:] }

    func setSidebar(_ app: AppDriver, visible: Bool) throws {
        if try window(app)["sidebarVisible"] as? Bool != visible { try app.run("sidebar.toggle") }
        try app.waitUntil(timeout: 5) { try window(app)["sidebarVisible"] as? Bool == visible }
    }

    /// The page takes key; the browser window stays main, so it doesn't draw inactive (traffic lights, glass).
    func focusPage(_ app: AppDriver) throws {
        try click(app, "page", 900, 450)
        try app.waitUntil(timeout: 5) { try app.state()["keyWindow"] as? String == "CefNSWindow" }
        #expect(try app.state()["mainWindow"] as? String == "ShellWindow")
    }

    func editorOpens(_ app: AppDriver) throws {
        try app.waitUntil(timeout: 5) { (try window(app)["flags"] as? [String])?.contains("command-bar") == true }
    }

    @Test func oneClickFromThePageOpensTheDockedAddressEditor() throws {
        let (app, _) = try launch()
        try setSidebar(app, visible: true)
        try focusPage(app)
        try click(app, "browser", Self.address.x, Self.address.y)
        try editorOpens(app)
        try app.quit()
    }

    @Test func oneClickFromThePageOpensTheFloatingAddressEditor() throws {
        let (app, _) = try launch()
        try setSidebar(app, visible: false)
        try focusPage(app)
        try app.call(["op": "peek", "value": true])
        try click(app, "overlay", Self.floatingAddress.x, Self.floatingAddress.y)
        try editorOpens(app)
        try app.quit()
    }
}
