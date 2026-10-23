import BrowserCore
@testable import EngineCEF
@testable import EngineWebKit
import Foundation
import Testing

struct CookieStoreTests {
    // Within the 400 days cookie stores keep.
    let expires = Date(timeIntervalSince1970: (Date.now.timeIntervalSince1970 + 86_400 * 30).rounded())

    @Test func bridgeCookiesKeepEveryField() {
        let c = BrowserCookie(name: "sid", value: "abc", domain: ".example.com", path: "/app", isSecure: true, isHTTPOnly: true,
                              expires: expires, sameSite: .noRestriction)
        let d = ProtectedMedia.bridgeCookie(c)
        #expect(d["domain"] as? String == ".example.com" && d["path"] as? String == "/app")
        #expect(d["secure"] as? Bool == true && d["httpOnly"] as? Bool == true)
        #expect(d["expires"] as? Date == expires && d["sameSite"] as? String == "none")
        // And it reads back the way the bridge hands cookies out.
        let back = ProtectedMedia.httpCookie(d)
        #expect(back?.domain == ".example.com" && back?.value == "abc" && back?.isHTTPOnly == true)

        let session = ProtectedMedia.bridgeCookie(BrowserCookie(name: "s", value: "1", domain: "www.example.com"))
        #expect(session["expires"] == nil && session["sameSite"] == nil)
    }

    @Test func webKitCookiesAreHostOnlyWithoutALeadingDot() throws {
        let host = try #require(WebKitEngine.httpCookie(BrowserCookie(name: "a", value: "1", domain: "www.example.com", sameSite: .lax)))
        #expect(host.domain == "www.example.com" && host.isSessionOnly && host.sameSitePolicy == .sameSiteLax)
        let domain = try #require(WebKitEngine.httpCookie(BrowserCookie(name: "b", value: "2", domain: ".example.com", isSecure: true, expires: expires)))
        #expect(domain.domain == ".example.com" && domain.isSecure && domain.expiresDate == expires)
    }
}
