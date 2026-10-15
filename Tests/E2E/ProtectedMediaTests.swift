import BrowserTesting
import Foundation
import Testing

/// Netflix and other DRM sites: a page asking for a DRM key system moves to a WebKit tab (FairPlay), and its site's
/// next pages open there directly. Chromium engine only (WebKit is the fallback it hosts).
@Suite(.serialized, .enabled(if: AppDriver.executableFromEnvironment != nil, "set BROWSER_E2E_APP (./forkctl test --e2e)"))
struct ProtectedMediaTests {
    static let pages = [
        "/drm": """
        <!doctype html><title>DRM</title><script>
        navigator.requestMediaKeySystemAccess('com.widevine.alpha', [{ initDataTypes: ['cenc'],
          videoCapabilities: [{ contentType: 'video/mp4; codecs="avc1.42E01E"' }] }]).then(() => {}, () => {});
        </script>
        """,
        "/plain": "<!doctype html><title>Plain</title><body>plain</body>",
    ]

    /// Only WebKit has Apple's legacy key API: which engine runs the selected page.
    func inWebKit(_ app: AppDriver) throws -> Bool { try app.eval("typeof WebKitMediaKeys") as? String == "function" }

    @Test func protectedMediaPlaysInWebKit() throws {
        let server = try TestHTTPServer(pages: Self.pages)
        let data = FileManager.default.temporaryDirectory.appendingPathComponent("e2e-drm-\(UUID().uuidString.prefix(6))")
        defer { try? FileManager.default.removeItem(at: data) }
        let app = try AppDriver(executable: AppDriver.executableFromEnvironment!, extraEnvironment: ["BROWSER_DATA_DIR": data.path])
        guard try app.state()["engine"] as? String == "cef-chrome" else { try app.quit(); return }

        try app.open(server.url("/plain"))
        try app.waitUntil(timeout: 15) { try app.tabs().contains { $0.title == "Plain" } }
        #expect(try !inWebKit(app))

        try app.open(server.url("/drm"))
        try app.waitUntil(timeout: 20) { try inWebKit(app) && app.eval("document.title") as? String == "DRM" }
        let fairPlay = "navigator.requestMediaKeySystemAccess('com.apple.fps', [{ initDataTypes: ['skd'], videoCapabilities: [{ contentType: 'application/vnd.apple.mpegurl' }] }]).then(() => document.title = 'fps', () => document.title = 'no fps'); 1"
        _ = try app.eval(fairPlay)
        try app.waitUntil(timeout: 10) { try app.eval("document.title") as? String == "fps" }
        #expect(try app.eval("navigator.userAgent") as? String ?? "" ~= "Safari/")

        // The site is remembered: its next page opens in WebKit at once.
        try app.open(server.url("/plain?again"))
        try app.waitUntil(timeout: 15) { try app.eval("document.title") as? String == "Plain" }
        #expect(try inWebKit(app))
        #expect(try app.tabs().count == 3)
        try app.quit()
    }
}

private func ~= (string: String, part: String) -> Bool { string.contains(part) }
