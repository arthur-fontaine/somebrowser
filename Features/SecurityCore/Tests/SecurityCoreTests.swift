import BrowserCore
import BrowserTesting
import Foundation
import Testing
@testable import FeatureSecurityCore

@MainActor
struct SecurityCoreTests {
    func entry(_ host: String, _ purpose: String, _ source: String, minutesAgo: Double, failed: Bool = false) -> OutboundConnections.Entry {
        OutboundConnections.Entry(date: Date().addingTimeInterval(-minutesAgo * 60), url: "https://\(host)/", host: host, purpose: purpose,
                                  source: source, status: failed ? 503 : 200)
    }

    @Test func groupsConnectionsByHostNewestFirst() {
        let entries = [
            entry("duckduckgo.com", "search suggestions", "search", minutesAgo: 1),
            entry("easylist.to", "filter list update", "adblock", minutesAgo: 5),
            entry("duckduckgo.com", "search suggestions", "search", minutesAgo: 9, failed: true),
            entry("github.com", "filter list update", "adblock", minutesAgo: 3),
        ]
        let hosts = HostActivity.group(entries)
        #expect(hosts.map(\.host) == ["duckduckgo.com", "github.com", "easylist.to"])
        #expect(hosts[0].count == 2 && hosts[0].failures == 1 && hosts[0].sources == ["search"])
        #expect(HostActivity.group(entries, purpose: "filter list update").map(\.host) == ["github.com", "easylist.to"])
    }

    @Test func commandShowsAndHidesThePanel() throws {
        let h = try TestHarness(features: [SecurityCoreFeature.self], manifestDirectory: #filePath)
        try h.run("security-core.show")
        #expect(h.window.flags.contains(SecurityCoreFeature.panelFlag))
        try h.run("security-core.show")
        #expect(!h.window.flags.contains(SecurityCoreFeature.panelFlag))
    }
}
