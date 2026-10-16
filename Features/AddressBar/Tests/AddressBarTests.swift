import BrowserCore
import BrowserTesting
import Foundation
import Testing
@testable import FeatureAddressBar

@MainActor
struct AddressBarTests {
    @Test func formatsLikeArc() {
        #expect(AddressFormatter.display(URL(string: "https://www.apple.com/iphone/")!, full: false) == "apple.com")
        #expect(AddressFormatter.display(URL(string: "https://www.apple.com/iphone/")!, full: true) == "https://www.apple.com/iphone/")
        #expect(AddressFormatter.display(URL(string: "file:///tmp/notes.html")!, full: false) == "notes.html")
        #expect(AddressFormatter.display(nil, full: false) == "")
        #expect(AddressFormatter.symbol(for: .insecure) != nil)
        #expect(AddressFormatter.symbol(for: .secure) == nil)
    }

    /// Developer mode (Arc): on for local servers, ⌃D for any site; the address shows port, path and query.
    @Test func developerModeShowsWhereYouReallyAre() throws {
        let h = try TestHarness(features: [AddressBarFeature.self], manifestDirectory: #filePath)
        let local = URL(string: "http://localhost:5173/app/settings?tab=2")!, remote = URL(string: "https://www.example.com/docs/a")!
        #expect(AddressFormatter.developerMode(local, store: h.runtime.siteSettings))
        #expect(!AddressFormatter.developerMode(remote, store: h.runtime.siteSettings))
        #expect(AddressFormatter.developerDisplay(local) == "localhost:5173/app/settings?tab=2")
        #expect(AddressFormatter.developerDisplay(URL(string: "http://127.0.0.1:8000/")!) == "127.0.0.1:8000")
        _ = h.openTab(remote.absoluteString)
        try h.run("address-bar.developer-mode")
        #expect(AddressFormatter.developerMode(remote, store: h.runtime.siteSettings))
        try h.run("address-bar.developer-mode")
        #expect(!AddressFormatter.developerMode(remote, store: h.runtime.siteSettings))
    }

    @Test func pillLivesInTheSidebar() throws {
        let h = try TestHarness(features: [AddressBarFeature.self], manifestDirectory: #filePath)
        #expect(h.runtime.ui.views(for: "sidebar.address").count == 1)
    }
}
