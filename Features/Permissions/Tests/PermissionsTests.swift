import BrowserCore
import BrowserTesting
import Foundation
import Testing
@testable import FeaturePermissions

@MainActor
struct PermissionsTests {
    func harness() throws -> (TestHarness, PermissionsFeature) {
        let h = try TestHarness(features: [PermissionsFeature.self], manifestDirectory: #filePath)
        return (h, try #require(h.runtime.feature(PermissionsFeature.self)))
    }

    let camera = PermissionRequest(kinds: [.camera, .microphone], origin: URL(string: "https://meet.example")!, tab: nil)

    @Test func asksThenRemembers() throws {
        let (h, feature) = try harness()
        #expect(h.engine.hooks.decide(camera) == .prompt)
        var granted: Bool?
        h.engine.hooks.permissionPrompt?(camera) { granted = $0 }
        let pending = try #require(feature.prompts.pending.first)
        feature.prompts.answer(pending.id, granted: true, remember: true)
        #expect(granted == true)
        #expect(h.engine.hooks.decide(camera) == .grant)
        #expect(feature.log.first?.source == "remembered")
        #expect(feature.log.dropFirst().first?.source == "user")
    }

    @Test func anyDenialWins() throws {
        let (h, feature) = try harness()
        feature.setDecision(.grant, .camera, for: "meet.example")
        feature.setDecision(.deny, .microphone, for: "meet.example")
        #expect(h.engine.hooks.decide(camera) == .deny)
        feature.setDecision(nil, .microphone, for: "meet.example")
        #expect(h.engine.hooks.decide(camera) == .prompt)
    }

    @Test func notRememberedWhenUnchecked() throws {
        let (h, feature) = try harness()
        h.engine.hooks.permissionPrompt?(camera) { _ in }
        feature.prompts.answer(feature.prompts.pending[0].id, granted: false, remember: false)
        #expect(h.engine.hooks.decide(camera) == .prompt)
        #expect(h.runtime.capabilities.permissions != nil)
    }

    @Test func describesKinds() {
        #expect(PermissionPrompt.describe([.camera, .microphone]).contains("camera"))
        #expect(PermissionPrompt.symbol([.location]) == "location.fill")
    }
}
