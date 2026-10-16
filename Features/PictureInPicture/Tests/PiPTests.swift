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
struct PiPPanelTests {
    /// Back to the tab, the page is back in the browser window before the panel's fade ends: the fade's end leaves it
    /// there, on screen (it hid it: a white page until the tab was clicked again).
    @Test func thePageBackInTheBrowserStaysOnScreen() throws {
        _ = NSApplication.shared
        let browser = NSWindow(contentRect: CGRect(x: 100, y: 100, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        let page = NSWindow(contentRect: CGRect(x: 100, y: 100, width: 800, height: 600), styleMask: [.borderless], backing: .buffered, defer: false)
        browser.orderFront(nil)
        let panel = PiPPanel(content: .window(page), size: CGSize(width: 320, height: 180), model: PiPControlsModel(isCall: false))
        panel.present(from: nil)
        #expect(page.parent === panel)
        panel.dismiss()
        // What closing does next (the engine's reattach, then the viewport presenting the page again).
        panel.removeChildWindow(page)
        browser.addChildWindow(page, ordered: .above)
        page.orderFront(nil)
        panel.fadedOut()  // the fade's end (AppKit runs it after 0.18 s, not in a test process)
        #expect(page.parent === browser && page.isVisible)
        #expect(!panel.isVisible)
        browser.orderOut(nil)
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

    /// Two fingers moving right and up move the panel right and up, with "natural" scrolling on or off, as far as a
    /// drag would.
    @Test func trackpadMovesFollowTheFingers() {
        let g = PiPPhysics.trackpadGain
        // Fingers right and up: natural scrolling reports +x, -y; the other setting -x, +y.
        #expect(PiPPhysics.fingerMove(scrollX: 10, scrollY: -6, natural: true) == CGVector(dx: 10 * g, dy: 6 * g))
        #expect(PiPPhysics.fingerMove(scrollX: -10, scrollY: 6, natural: false) == CGVector(dx: 10 * g, dy: 6 * g))
        #expect(g > 1)
    }

    /// A release throws at the speed of the last moves; fingers that stopped before lifting throw nothing.
    @Test func releaseVelocityIsTheLastMoves() {
        let moving: [(t: TimeInterval, d: CGVector)] = (0...6).map { (t: 10 + Double($0) * 0.01, d: CGVector(dx: 20, dy: 0)) }
        let v = PiPPhysics.velocity(of: moving, at: 10.07)
        #expect(abs(v.dx - 2000) < 1 && v.dy == 0)
        #expect(PiPPhysics.velocity(of: moving, at: 10.5) == .zero)
    }

    /// Thrown toward its corner, the panel keeps going at the throw's speed, then settles exactly there.
    @Test func settlingCarriesTheThrow() {
        let start = CGRect(x: 100, y: 100, width: 320, height: 180)
        let target = CGRect(x: 900, y: 100, width: 320, height: 180)
        var thrown = PiPPhysics.FrameSpring(from: start, velocity: CGVector(dx: 3000, dy: 0), to: target)
        var still = PiPPhysics.FrameSpring(from: start, velocity: .zero, to: target)
        thrown.advance(by: 1.0 / 60)
        still.advance(by: 1.0 / 60)
        #expect(thrown.frame.minX - start.minX > 40 && thrown.frame.minX > still.frame.minX)
        for _ in 0..<120 { thrown.advance(by: 1.0 / 60) }
        #expect(thrown.isSettled && abs(thrown.frame.minX - target.minX) < 0.5)
    }

    /// The pointer carried with the panel: AppKit's y-up screen points become the display's y-down ones.
    @Test func pointerPointsAreFlipped() {
        #expect(PiPPhysics.displayPoint(CGPoint(x: 10, y: 900), primaryHeight: 1000) == CGPoint(x: 10, y: 100))
    }
}
