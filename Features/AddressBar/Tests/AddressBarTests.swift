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

    @Test func pillFollowsPositionSetting() throws {
        let h = try TestHarness(features: [AddressBarFeature.self], manifestDirectory: #filePath)
        #expect(h.runtime.ui.views(for: "sidebar.address").count == 1)
        h.runtime.settings.set("address-bar.position", .string("toolbar"))
        #expect(h.runtime.ui.views(for: "sidebar.address").isEmpty)
        #expect(h.runtime.ui.views(for: "toolbar.center").count == 1)
    }
}
