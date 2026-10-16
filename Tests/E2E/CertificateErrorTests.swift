import BrowserTesting
import Foundation
import Testing

/// An invalid certificate shows the browser's own page (not Chrome's interstitial); Visit Anyway opens the site. Uses
/// badssl.com's expired certificate: opt-in with BROWSER_E2E_NETWORK=1. Every engine.
@Suite(.serialized, .enabled(if: AppDriver.executableFromEnvironment != nil && ProcessInfo.processInfo.environment["BROWSER_E2E_NETWORK"] != nil,
                             "set BROWSER_E2E_APP and BROWSER_E2E_NETWORK=1"))
struct CertificateErrorTests {
    @Test func invalidCertificatesShowTheBrowsersPage() throws {
        let app = try AppDriver(executable: AppDriver.executableFromEnvironment!)
        try app.open("https://expired.badssl.com/")
        try app.waitUntil(timeout: 20) { try app.eval("document.title") as? String == "This Connection Isn’t Private" }
        _ = try app.eval("document.querySelector('a.quiet').click(); 1")
        try app.waitUntil(timeout: 20) { try app.eval("document.title") as? String == "expired.badssl.com" }
        try app.quit()
    }
}
