import BrowserTesting
import Foundation
import Testing

/// The console (⌥⌘J) and Inspect Element (⌥⌘C) open DevTools in a window of their own, not as a tab. Chromium only
/// (WebKit's inspector has no public way in).
@Suite(.serialized, .enabled(if: AppDriver.executableFromEnvironment != nil, "set BROWSER_E2E_APP (./forkctl test --e2e)"))
struct DeveloperToolsTests {
    @Test func consoleAndInspectorOpenInTheirOwnWindow() throws {
        let server = try TestHTTPServer(pages: ["/p": "<!doctype html><title>P</title><body>p</body>"])
        let app = try AppDriver(executable: AppDriver.executableFromEnvironment!)
        guard try app.state()["engine"] as? String == "cef-chrome" else { try app.quit(); return }
        try app.open(server.url("/p"))
        try app.waitUntil(timeout: 15) { try app.eval("document.title") as? String == "P" }
        let devToolsWindowShown = {
            let windows = try app.call(["op": "views"])["windows"] as? [[String: Any]] ?? []
            return windows.contains { $0["class"] as? String == "CefNSWindow" && $0["visible"] as? Bool == true && $0["parent"] as? Int == 0 }
        }
        for command in ["navigation.console", "navigation.inspect-element"] {
            _ = try app.run(command)
            try app.waitUntil(timeout: 15, devToolsWindowShown)
            #expect(try app.tabs().count == 1)
        }
        try app.quit()
    }
}
