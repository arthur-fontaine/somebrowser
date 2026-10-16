import AppKit
import BrowserCore
import BrowserTesting
import Foundation
import Testing
@testable import FeaturePip

struct PiPPhysicsTests {
    let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
    let size = CGSize(width: 400, height: 225)

    @Test func flingProjectsToTheNearestCorner() {
        let frame = CGRect(origin: CGPoint(x: 600, y: 300), size: size)
        #expect(PiPPhysics.rest(frame: frame, velocity: .zero, in: screen) == .corner(.bottomRight))
        #expect(PiPPhysics.rest(frame: frame, velocity: CGVector(dx: 900, dy: 900), in: screen) == .corner(.topRight))
        #expect(PiPPhysics.rest(frame: frame, velocity: CGVector(dx: 300, dy: -600), in: screen) == .corner(.bottomRight))
    }

    @Test func throwingPastAnEdgeStashes() {
        let frame = CGRect(origin: CGPoint(x: 1000, y: 300), size: size)
        guard case .stashed(let left, _) = PiPPhysics.rest(frame: frame, velocity: CGVector(dx: 4000, dy: 0), in: screen) else {
            Issue.record("expected stash")
            return
        }
        #expect(!left)
        let stashed = PiPPhysics.frame(for: .stashed(left: false, y: 100), size: size, in: screen)
        #expect(stashed.minX == screen.maxX - PiPPhysics.stashVisible)
    }

    @Test func cornerFramesRespectMargins() {
        let f = PiPPhysics.frame(for: .corner(.topRight), size: size, in: screen)
        #expect(f.maxX == screen.maxX - PiPPhysics.margin)
        #expect(f.maxY == screen.maxY - PiPPhysics.margin)
    }

    @Test func pinchKeepsAspectWithinLimits() {
        let s = PiPPhysics.resized(size, by: 0.5, aspect: 16 / 9)
        #expect(s.width == 600)
        #expect(s.height == 338)
        #expect(PiPPhysics.resized(size, by: -0.9, aspect: 16 / 9).width == 240)
    }

    @Test func timeFormatting() {
        #expect(PiPControls.format(75) == "1:15")
        #expect(PiPControls.format(3725) == "1:02:05")
    }
}

@MainActor
struct PiPFeatureTests {
    @Test func popsOutOnlyPlayingVideosAndRespectsSiteSetting() throws {
        let h = try TestHarness(features: [PictureInPictureFeature.self], manifestDirectory: #filePath)
        let feature = try #require(h.runtime.feature(PictureInPictureFeature.self))
        let video = h.openTab("https://video.example/watch")
        #expect(!feature.shouldPopOut(video))
        h.fakeTab(video).simulateMedia(audio: true, video: true)
        #expect(feature.shouldPopOut(video))
        h.runtime.siteSettings.set(PictureInPictureFeature.siteKey, .bool(false), for: "video.example")
        #expect(!feature.shouldPopOut(video))
        h.runtime.settings.set("pip.autoPopOut", false)
        h.runtime.siteSettings.set(PictureInPictureFeature.siteKey, nil, for: "video.example")
        #expect(!feature.shouldPopOut(video))
    }

    /// A floating video's tab never hibernates, and stops being held once it's back.
    @Test func floatingTabIsHeldAwake() throws {
        let h = try TestHarness(features: [PictureInPictureFeature.self], manifestDirectory: #filePath)
        let feature = try #require(h.runtime.feature(PictureInPictureFeature.self))
        let video = h.openTab("https://video.example/watch")
        h.fakeTab(video).simulateMedia(audio: true, video: true)
        feature.popOut(video, from: h.window)
        #expect(h.runtime.isHeldAwake(video.id))
        _ = h.openTab("https://other.example")
        h.runtime.discard(video)
        #expect(video.isLoaded)
        feature.close(expand: false)
        #expect(!h.runtime.isHeldAwake(video.id))
        #expect(h.engine.floatingTabs.isEmpty)
    }

    @Test func callsFollowTheirOwnSetting() throws {
        let h = try TestHarness(features: [PictureInPictureFeature.self], manifestDirectory: #filePath)
        let feature = try #require(h.runtime.feature(PictureInPictureFeature.self))
        let meet = h.openTab("https://meet.example/abc")
        h.fakeTab(meet).state.isCapturingCamera = true
        #expect(feature.shouldPopOut(meet))
        h.runtime.settings.set("pip.calls", false)
        #expect(!feature.shouldPopOut(meet))
    }

    /// Two fingers moving right and up move the panel right and up, with "natural" scrolling on or off.
    @Test func trackpadMovesFollowTheFingers() {
        // Fingers right and up: natural scrolling reports +x, -y; the other setting -x, +y.
        #expect(PiPPhysics.fingerMove(scrollX: 10, scrollY: -6, natural: true) == CGVector(dx: 10, dy: 6))
        #expect(PiPPhysics.fingerMove(scrollX: -10, scrollY: 6, natural: false) == CGVector(dx: 10, dy: 6))
    }
}
