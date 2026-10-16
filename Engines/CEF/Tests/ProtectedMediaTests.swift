@testable import EngineCEF
@testable import EngineWebKit
import Foundation
import Testing

struct ProtectedMediaTests {
    @Test func sitesAreRegistrableHosts() {
        func site(_ s: String) -> String? { ProtectedMedia.site(of: URL(string: s)!) }
        #expect(site("https://www.netflix.com/watch/1") == "netflix.com")
        #expect(site("https://assets.nflxext.com/x.js") == "nflxext.com")
        #expect(site("https://www.bbc.co.uk/iplayer") == "bbc.co.uk")
        #expect(site("https://disneyplus.com/") == "disneyplus.com")
        #expect(site("http://127.0.0.1:8931/") == "127.0.0.1")
        #expect(site("http://[::1]:80/") == "::1")
        #expect(site("chrome://extensions") == nil)
    }

    /// Remembered sites go to WebKit (and are kept between launches); other modes keep everything in Chromium.
    @Test func remembersSitesThatAskedForProtectedMedia() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("pm-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let media = ProtectedMedia(mode: .webkit, file: file)
        #expect(!media.needsWebKit(URL(string: "https://www.streamer.example/browse")))
        media.remember(URL(string: "https://www.streamer.example/watch/1")!)
        #expect(media.needsWebKit(URL(string: "https://www.streamer.example/browse")))
        #expect(!media.needsWebKit(URL(string: "https://example.com/")))
        #expect(ProtectedMedia(mode: .webkit, file: file).needsWebKit(URL(string: "https://streamer.example/")))
        #expect(!ProtectedMedia(mode: .chromium, file: file).needsWebKit(URL(string: "https://streamer.example/")))
    }

    /// Streaming services open in WebKit from their first page (signing in happens there), subdomains included.
    @Test func knownStreamingSitesOpenInWebKit() {
        let media = ProtectedMedia(mode: .webkit, file: nil)
        for url in ["https://www.netflix.com/", "https://netflix.com/login", "https://www.disneyplus.com/", "https://tv.apple.com/"] {
            #expect(media.needsWebKit(URL(string: url)), "\(url)")
        }
        for url in ["https://www.apple.com/", "https://notnetflix.com/", "https://example.com/"] {
            #expect(!media.needsWebKit(URL(string: url)), "\(url)")
        }
        #expect(!ProtectedMedia(mode: .chromium, file: nil).needsWebKit(URL(string: "https://www.netflix.com/")))
    }

    /// Chromium's cookies go to WebKit once per site (kept between launches); private sessions take them each time.
    @Test func cookiesGoToWebKitOncePerSite() {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("pm-\(UUID().uuidString).json")
        defer {
            try? FileManager.default.removeItem(at: file)
            try? FileManager.default.removeItem(at: file.deletingPathExtension().appendingPathExtension("cookies.json"))
        }
        let media = ProtectedMedia(mode: .webkit, file: file)
        #expect(media.takeCookies(for: URL(string: "https://www.netflix.com/watch/1")!, isPrivate: false))
        #expect(!media.takeCookies(for: URL(string: "https://netflix.com/browse")!, isPrivate: false))
        #expect(media.takeCookies(for: URL(string: "https://www.netflix.com/")!, isPrivate: true))
        #expect(media.takeCookies(for: URL(string: "https://www.disneyplus.com/")!, isPrivate: false))
        #expect(!ProtectedMedia(mode: .webkit, file: file).takeCookies(for: URL(string: "https://netflix.com/")!, isPrivate: false))
    }

    /// Chromium's cookies keep their attributes in WebKit: HttpOnly, Secure, SameSite, expiry or session.
    @Test func chromiumCookiesKeepTheirAttributes() throws {
        let expires = Date(timeIntervalSinceNow: 3600)
        let signedIn = try #require(ProtectedMedia.httpCookie(["name": "NetflixId", "value": "v", "domain": ".netflix.com", "path": "/",
                                                                "secure": true, "httpOnly": true, "expires": expires, "sameSite": "lax"]))
        #expect(signedIn.isHTTPOnly && signedIn.isSecure && !signedIn.isSessionOnly)
        #expect(signedIn.domain == ".netflix.com")
        #expect(abs((signedIn.expiresDate ?? .distantPast).timeIntervalSince(expires)) < 1)
        #expect(signedIn.sameSitePolicy == .sameSiteLax)
        let session = try #require(ProtectedMedia.httpCookie(["name": "s", "value": "1", "domain": "www.netflix.com", "path": "",
                                                              "secure": false, "httpOnly": false]))
        #expect(session.isSessionOnly && !session.isHTTPOnly && session.path == "/")
        #expect(ProtectedMedia.httpCookie(["value": "no name"]) == nil)
    }

    /// WebKit pages of an isolated profile (BROWSER_DATA_DIR) keep their own store, apart from the user's and from
    /// other profiles'; the browser's own profile keeps its fixed store.
    @Test func isolatedProfilesHaveTheirOwnWebKitStore() {
        let a = URL(fileURLWithPath: "/tmp/e2e-aaaa/data"), b = URL(fileURLWithPath: "/tmp/e2e-bbbb/data")
        let own = WebKitEngine.storeIdentifier(options: [:], profileDirectory: a, isolated: false)
        #expect(own == UUID(uuidString: "5A3E9C2B-6D1F-4B8E-9C4A-1F2E3D4C5B6A"))
        let isolatedA = WebKitEngine.storeIdentifier(options: [:], profileDirectory: a, isolated: true)
        #expect(isolatedA != own)
        #expect(isolatedA != WebKitEngine.storeIdentifier(options: [:], profileDirectory: b, isolated: true))
        #expect(isolatedA == WebKitEngine.storeIdentifier(options: [:], profileDirectory: a, isolated: true))
    }
}

struct NativeMessagingHostsTests {
    /// Chrome's manifests (Claude Code's, 1Password's…) reach the profile's folder; unchanged ones aren't rewritten,
    /// and files that aren't manifests are left alone.
    @Test func chromeManifestsAreMirrored() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("nm-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let chrome = root.appendingPathComponent("chrome"), profile = root.appendingPathComponent("profile")
        try FileManager.default.createDirectory(at: chrome, withIntermediateDirectories: true)
        let manifest = #"{"name":"com.anthropic.claude_code_browser_extension","path":"/x","type":"stdio","allowed_origins":["chrome-extension://fcoeoabgfenejglbffodgkkbkcdhcgfn/"]}"#
        try manifest.write(to: chrome.appendingPathComponent("com.anthropic.claude_code_browser_extension.json"), atomically: true, encoding: .utf8)
        try "not json".write(to: chrome.appendingPathComponent("broken.json"), atomically: true, encoding: .utf8)
        try "x".write(to: chrome.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
        #expect(NativeMessagingHosts.mirror(from: chrome, into: profile) == ["com.anthropic.claude_code_browser_extension.json"])
        #expect(try String(contentsOf: profile.appendingPathComponent("com.anthropic.claude_code_browser_extension.json"), encoding: .utf8) == manifest)
        #expect(NativeMessagingHosts.mirror(from: chrome, into: profile).isEmpty)
    }
}
