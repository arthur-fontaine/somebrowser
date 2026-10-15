import BrowserTesting
import Foundation
import Testing

/// Private windows keep nothing: their cookies and storage are apart from normal windows', and gone once the last
/// private window closes. Every engine.
@Suite(.serialized, .enabled(if: AppDriver.executableFromEnvironment != nil, "set BROWSER_E2E_APP (./forkctl test --e2e)"))
struct PrivateBrowsingTests {
    @Test func privateWindowsShareNothingAndForget() throws {
        let data = FileManager.default.temporaryDirectory.appendingPathComponent("e2e-private-\(UUID().uuidString.prefix(6))")
        defer { try? FileManager.default.removeItem(at: data) }
        let server = try TestHTTPServer(pages: ["/p": "<!doctype html><title>P</title><body>p</body>"])
        let app = try AppDriver(executable: AppDriver.executableFromEnvironment!, extraEnvironment: ["BROWSER_DATA_DIR": data.path])
        func eval(_ js: String, isPrivate: Bool) throws -> String? {
            try app.call(["op": "eval", "js": js, "private": isPrivate])["value"] as? String
        }
        func openPrivatePage() throws {
            _ = try app.run("tabs.new-private-window")
            try app.waitUntil(timeout: 10) { (try app.state()["windows"] as? [[String: Any]])?.contains { $0["private"] as? Bool == true } == true }
            _ = try app.call(["op": "open", "url": server.url("/p"), "private": true])
            try app.waitUntil(timeout: 15) { try eval("document.title", isPrivate: true) == "P" }
        }

        try app.open(server.url("/p"))
        try app.waitUntil(timeout: 15) { try eval("document.title", isPrivate: false) == "P" }
        _ = try eval("document.cookie = 'normal=1; max-age=3600'; localStorage.setItem('normal', '1'); 'ok'", isPrivate: false)

        try openPrivatePage()
        #expect(try eval("document.cookie + '|' + localStorage.getItem('normal')", isPrivate: true) == "|null")
        _ = try eval("document.cookie = 'secret=1; max-age=3600'; localStorage.setItem('secret', '1'); 'ok'", isPrivate: true)
        #expect(try eval("document.cookie + '|' + localStorage.getItem('secret')", isPrivate: false) == "normal=1|null")

        _ = try app.call(["op": "run", "command": "tabs.close-window", "private": true])
        try app.waitUntil(timeout: 10) { (try app.state()["windows"] as? [[String: Any]])?.contains { $0["private"] as? Bool == true } == false }
        try openPrivatePage()
        #expect(try eval("document.cookie + '|' + localStorage.getItem('secret')", isPrivate: true) == "|null")
        try app.quit()
    }
}
