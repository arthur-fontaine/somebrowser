@testable import EngineCEF
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
}
