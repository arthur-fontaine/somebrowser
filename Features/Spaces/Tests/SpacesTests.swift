import BrowserCore
import BrowserTesting
import Foundation
import SwiftUI
import Testing
@testable import FeatureSpaces

@MainActor
struct SpacesTests {
    func harness() throws -> TestHarness { try TestHarness(features: [SpacesFeature.self], manifestDirectory: #filePath) }

    @Test func newSpaceSwitchesAndOpensEditor() throws {
        let h = try harness()
        try h.run("spaces.new")
        #expect(h.runtime.tabs.spaces.count == 2)
        #expect(h.window.spaceID == h.runtime.tabs.spaces[1].id)
        #expect(h.window.flags.contains(SpacesFeature.editFlag))
    }

    @Test func numberAndArrowSwitching() throws {
        let h = try harness()
        try h.run("spaces.new")
        try h.run("spaces.new")
        try h.run("spaces.select-1")
        #expect(h.window.spaceID == h.runtime.tabs.spaces[0].id)
        try h.run("spaces.next")
        #expect(h.window.spaceID == h.runtime.tabs.spaces[1].id)
        try h.run("spaces.previous")
        #expect(h.window.spaceID == h.runtime.tabs.spaces[0].id)
        #expect(!h.runtime.commands.canRun("spaces.select-4"))
    }

    @Test func eachSpaceKeepsItsTabs() throws {
        let h = try harness()
        let a = h.openTab("https://a.example")
        try h.run("spaces.new")
        let b = h.openTab("https://b.example")
        #expect(h.runtime.tabs.spaceID(of: b.id) == h.window.spaceID)
        try h.run("spaces.select-1")
        #expect(h.selectedTab?.id == a.id)
    }

    @Test func deleteMovesWindowsAway() throws {
        let h = try harness()
        try h.run("spaces.new")
        let doomed = h.window.spaceID
        h.openTab("https://b.example")
        try h.run("spaces.delete")
        #expect(h.runtime.tabs.space(doomed) == nil)
        #expect(h.window.spaceID == h.runtime.tabs.spaces[0].id)
        #expect(h.runtime.tabs.tabCount == 0)
        #expect(!h.runtime.commands.canRun("spaces.delete"))
    }

    @Test func hexColors() {
        #expect(Color(hex: "#6E5BFF") != nil)
        #expect(Color(hex: "nope") == nil)
    }
}
