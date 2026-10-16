import BrowserCore
import BrowserTesting
import Foundation
import SwiftUI
import Testing
@testable import FeatureSpaces

@MainActor
@Suite(.serialized)
struct SpacesTests {
    func harness(authenticates: Bool = true) throws -> (TestHarness, () -> Int) {
        var asked = 0
        SpacesFeature.authenticate = { _, done in asked += 1; done(authenticates) }
        return (try TestHarness(features: [SpacesFeature.self], manifestDirectory: #filePath), { asked })
    }

    /// Most of the time there is one space: no switcher.
    @Test func oneSpaceShowsNoSwitcher() throws {
        let (h, _) = try harness()
        #expect(h.runtime.tabs.spaces.map(\.kind) == [.normal])
        #expect(!h.runtime.commands.canRun("spaces.unlock"))
    }

    /// Coming back to the private space asks for Touch ID; its pages show only once unlocked.
    @Test func enteringThePrivateSpaceAsksToUnlock() throws {
        let (h, asked) = try harness()
        h.openTab("https://a.example")
        let secret = h.runtime.openPrivateTab(URL(string: "https://secret.example")!, in: h.window)
        #expect(asked() == 0)  // just opened: no question
        try h.run("spaces.previous")
        #expect(!h.window.isPrivate)
        try h.run("spaces.next")
        #expect(asked() == 1)
        #expect(!h.window.isLocked)
        #expect(h.viewport.presentedTab === h.fakeTab(secret))
    }

    /// A refused check keeps the space locked; Unlock asks again.
    @Test func refusedUnlockStaysLocked() throws {
        let (h, asked) = try harness(authenticates: false)
        h.runtime.openPrivateTab(URL(string: "https://secret.example")!, in: h.window)
        try h.run("spaces.lock")
        #expect(!h.window.isPrivate)
        try h.run("spaces.next")
        #expect(h.window.isLocked && h.viewport.presentedTab == nil)
        try h.run("spaces.unlock")
        #expect(asked() == 2)
        #expect(h.window.isLocked)
    }

    @Test func arrowsStopAtTheEnds() throws {
        let (h, _) = try harness()
        h.runtime.openPrivateTab(nil, in: h.window)
        try h.run("spaces.next")
        #expect(h.window.isPrivate)
        try h.run("spaces.previous")
        try h.run("spaces.previous")
        #expect(h.window.spaceID == h.runtime.tabs.normalSpace.id)
    }
}
