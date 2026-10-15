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
        #expect(!media.needsWebKit(URL(string: "https://www.netflix.com/browse")))
        media.remember(URL(string: "https://www.netflix.com/watch/1")!)
        #expect(media.needsWebKit(URL(string: "https://www.netflix.com/browse")))
        #expect(!media.needsWebKit(URL(string: "https://example.com/")))
        #expect(ProtectedMedia(mode: .webkit, file: file).needsWebKit(URL(string: "https://netflix.com/")))
        #expect(!ProtectedMedia(mode: .chromium, file: file).needsWebKit(URL(string: "https://netflix.com/")))
    }
}
