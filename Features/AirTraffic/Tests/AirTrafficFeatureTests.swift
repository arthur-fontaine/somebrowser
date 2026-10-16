import BrowserCore
import BrowserTesting
import Foundation
import Testing
@testable import FeatureAirTraffic

@MainActor
struct AirTrafficFeatureTests {
    func url(_ s: String) -> URL { URL(string: s)! }

    @Test func rulesMatchHostsAndAddressPrefixes() {
        let host = TrafficRule(pattern: "GitHub.com", destination: .mainWindow)
        #expect(host.matches(url("https://github.com/swift")) && host.matches(url("https://gist.github.com/x")) && host.matches(url("https://www.github.com/")))
        #expect(!host.matches(url("https://notgithub.com/")) && !host.matches(url("mailto:a@github.com")))
        let prefix = TrafficRule(pattern: "https://docs.google.com/document", destination: .mainWindow)
        #expect(prefix.matches(url("https://docs.google.com/document/d/1")))
        #expect(!prefix.matches(url("https://docs.google.com/spreadsheets/d/1")))
    }

    @Test func linksGoToTheMainWindowAndOthersAreLeftAlone() throws {
        let h = try TestHarness(features: [AirTrafficFeature.self], manifestDirectory: #filePath)
        let feature = try #require(h.runtime.feature(AirTrafficFeature.self))
        feature.model.rules = [TrafficRule(pattern: "github.com", destination: .mainWindow)]
        #expect(feature.route(url("https://github.com/apple/swift")))
        #expect(h.selectedTab?.url?.host() == "github.com")
        #expect(!feature.route(url("https://news.example/")))
        // Rules decide before other handlers (mini windows).
        #expect(h.runtime.externalURLHandlers.first?(url("https://github.com/")) == true)
    }

    @Test func miniWindowRulesUseTheMiniWindowCommand() throws {
        let h = try TestHarness(features: [AirTrafficFeature.self], manifestDirectory: #filePath)
        let feature = try #require(h.runtime.feature(AirTrafficFeature.self))
        feature.model.rules = [TrafficRule(pattern: "meet.example", destination: .miniWindow)]
        #expect(!feature.route(url("https://meet.example/abc")))  // no mini windows: the usual behavior
        h.runtime.commands.register([CommandDescriptor(id: "mini-window.new", title: "New Mini Window")])
        var opened: String?
        h.runtime.commands.handle("mini-window.new") { inv in opened = inv.arguments["url"] }
        #expect(feature.route(url("https://meet.example/abc")))
        #expect(opened == "https://meet.example/abc")
    }

    @Test func rulesPersist() throws {
        let h = try TestHarness(features: [AirTrafficFeature.self], manifestDirectory: #filePath)
        let feature = try #require(h.runtime.feature(AirTrafficFeature.self))
        feature.model.rules = [TrafficRule(pattern: "github.com", destination: .mainWindow)]
        feature.save()
        let again = AirTrafficFeature(context: h.context)
        again.activate()
        #expect(again.model.rules.map(\.pattern) == ["github.com"])
    }

    /// Rules from when spaces were the user's own may name a space: they now send links to the main window.
    @Test func spaceRulesBecomeMainWindowRules() throws {
        let saved = #"[{"id":"\#(UUID())","pattern":"a.example","destination":{"space":{"_0":"\#(UUID())"}}},"#
            + #"{"id":"\#(UUID())","pattern":"b.example","destination":{"miniWindow":{}}}]"#
        let rules = try JSONDecoder().decode([TrafficRule].self, from: Data(saved.utf8))
        #expect(rules.map(\.destination) == [.mainWindow, .miniWindow])
    }
}
