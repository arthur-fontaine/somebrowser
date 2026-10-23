import AppKit
import BrowserCore
import BrowserTesting
import Foundation
import Testing
@testable import FeaturePip

struct PiPPhysicsTests {
    let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
    let size = CGSize(width: 400, height: 225)

    /// Fingers that stopped leave the panel where it is; a throw glides on, and stops at the screen's edges.
    @Test func throwsGlideAndStopOnScreen() {
        let frame = CGRect(origin: CGPoint(x: 600, y: 300), size: size)
        #expect(PiPPhysics.rest(frame: frame, velocity: .zero, in: screen) == .placed(frame.origin))
        guard case .placed(let glided) = PiPPhysics.rest(frame: frame, velocity: CGVector(dx: 0, dy: 400), in: screen) else {
            Issue.record("expected a placement")
            return
        }
        #expect(glided.x == 600 && glided.y > 400)
        let up = PiPPhysics.rest(frame: frame, velocity: CGVector(dx: 0, dy: 4000), in: screen)
        #expect(PiPPhysics.frame(for: up, size: size, in: screen).maxY == screen.maxY)
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

    @Test func aNewPanelAppearsInTheBottomRightCorner() {
        let o = PiPPhysics.cornerOrigin(size: size, in: screen)
        #expect(o.x + size.width == screen.maxX - PiPPhysics.margin)
        #expect(o.y == screen.minY + PiPPhysics.margin)
    }

    @Test func pinchKeepsAspectWithinLimits() {
        let s = PiPPhysics.resized(size, by: 0.5, aspect: 16 / 9)
        #expect(s.width == 600)
        #expect(s.height == 338)
        #expect(PiPPhysics.resized(size, by: -0.9, aspect: 16 / 9).width == 240)
    }

    /// A pinch scales around the pointer, which keeps its place over the panel.
    @Test func scalingKeepsTheAnchorInPlace() {
        let frame = CGRect(x: 100, y: 100, width: 400, height: 225)
        let anchor = CGPoint(x: 400, y: 150)
        let smaller = PiPPhysics.scaled(frame, to: CGSize(width: 240, height: 135), around: anchor)
        #expect(smaller.contains(anchor))
        #expect(abs((anchor.x - smaller.minX) / smaller.width - 0.75) < 0.01)
        #expect(abs((anchor.y - smaller.minY) / smaller.height - 50.0 / 225) < 0.01)
    }

    /// Sides grab in a thin band, corners near their ends; the middle (and the controls) grab nothing.
    @Test func edgesGrabbedAtAPoint() {
        let bounds = CGRect(origin: .zero, size: size)
        #expect(PiPPhysics.edges(at: CGPoint(x: 2, y: 100), in: bounds) == .left)
        #expect(PiPPhysics.edges(at: CGPoint(x: 200, y: 223), in: bounds) == .top)
        #expect(PiPPhysics.edges(at: CGPoint(x: 398, y: 12), in: bounds) == [.right, .bottom])
        #expect(PiPPhysics.edges(at: CGPoint(x: 12, y: 222), in: bounds) == [.left, .top])
        #expect(PiPPhysics.edges(at: CGPoint(x: 20, y: 200), in: bounds).isEmpty)  // the close button
        #expect(PiPPhysics.edges(at: CGPoint(x: 200, y: 112), in: bounds).isEmpty)
    }

    /// The video's shape is kept, the opposite corner (or side) holds still, within the width limits.
    @Test func draggingAnEdgeResizesAroundTheOppositeOne() {
        let start = CGRect(x: 600, y: 300, width: 400, height: 225)
        let corner = PiPPhysics.resized(start, edges: [.left, .top], by: CGVector(dx: -80, dy: 10), aspect: 16 / 9)
        #expect(corner.width == 480 && corner.height == 270)
        #expect(corner.maxX == start.maxX && corner.minY == start.minY)

        let bottom = PiPPhysics.resized(start, edges: .bottom, by: CGVector(dx: 0, dy: -45), aspect: 16 / 9)
        #expect(bottom.height == 270 && bottom.maxY == start.maxY && bottom.midX == start.midX)

        let shrunk = PiPPhysics.resized(start, edges: .right, by: CGVector(dx: -1000, dy: 0), aspect: 16 / 9)
        #expect(shrunk.width == PiPPhysics.widths.lowerBound && shrunk.minX == start.minX)
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

    /// A page's still: pixels, as the engine's (a drawing closure would run off the main thread when decoded).
    func stillImage() -> NSImage {
        let context = CGContext(data: nil, width: 32, height: 18, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(NSColor.red.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 32, height: 18))
        return NSImage(cgImage: context.makeImage()!, size: CGSize(width: 32, height: 18))
    }

    func magnify(_ m: Double, phase: Int64) -> NSEvent {
        let cg = CGEvent(source: nil)!
        cg.setIntegerValueField(CGEventField(rawValue: 55)!, value: 29)  // a gesture
        cg.setIntegerValueField(CGEventField(rawValue: 110)!, value: 8)  // a pinch
        cg.setDoubleValueField(CGEventField(rawValue: 113)!, value: m)
        cg.setIntegerValueField(CGEventField(rawValue: 132)!, value: phase)  // 1 began, 2 changed, 4 ended
        return NSEvent(cgEvent: cg)!
    }

    /// A pinch begun over the panel stays its own when the pointer drifts off; the page, hidden meanwhile behind a
    /// still of it, takes the new size once the fingers lift.
    @Test func aPinchResizesBehindAStillToTheEnd() throws {
        _ = NSApplication.shared
        let page = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 320, height: 180), styleMask: [.borderless], backing: .buffered, defer: false)
        let panel = PiPPanel(content: .window(page), size: CGSize(width: 320, height: 180), model: PiPControlsModel(isCall: false))
        panel.takeStill = { done in done(stillImage()) }
        panel.present(from: nil)
        let screen = panel.screenFrame
        panel.moveBy(screen.midX - panel.frame.midX, screen.midY - panel.frame.midY)
        panel.release(velocity: .zero)
        var pointer = CGPoint(x: panel.frame.midX, y: panel.frame.midY)
        panel.pointerLocation = { pointer }
        let start = panel.frame

        panel.pinch(magnify(0, phase: 1))
        #expect(panel.isSizing && panel.still != nil && page.alphaValue == 0)
        panel.pinch(magnify(0.5, phase: 2))
        #expect(panel.frame.width == 480 && panel.frame.contains(pointer))
        #expect(page.frame.size == start.size)  // the page waits

        pointer = CGPoint(x: screen.minX + 1, y: screen.minY + 1)  // drifted off
        let mid = panel.frame.width
        panel.pinch(magnify(-0.25, phase: 2))
        #expect(panel.frame.width < mid)
        panel.pinch(magnify(0, phase: 4))
        #expect(!panel.isSizing && page.frame.size == panel.frame.size)
        panel.dismiss()
        #expect(page.alphaValue == 1 && panel.still == nil)
    }

    /// Hovered, the panel keeps a decoded still ready: a pinch shows it at once, asking the page for nothing.
    @Test func aStillIsReadyBeforeThePinch() async throws {
        _ = NSApplication.shared
        let panel = PiPPanel(content: .view(NSView()), size: CGSize(width: 320, height: 180), model: PiPControlsModel(isCall: false))
        panel.takeStill = { done in done(stillImage()) }
        panel.present(from: nil)
        panel.keepStillReady(true)
        for _ in 0..<100 where panel.readyStill == nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(panel.readyStill != nil)

        var asked = 0
        panel.takeStill = { done in asked += 1; done(nil) }
        let center = CGPoint(x: panel.frame.midX, y: panel.frame.midY)
        panel.pointerLocation = { center }
        panel.pinch(magnify(0, phase: 1))
        #expect(panel.still != nil && asked == 0)
        panel.dismiss()
    }

    /// An edge takes the mouse before the controls, resizes around the opposite corner, and the panel rests at its new
    /// size; tucked into a side, its edges resize nothing.
    @Test func draggingAnEdgeResizesThePanel() throws {
        _ = NSApplication.shared
        let panel = PiPPanel(content: .view(NSView()), size: CGSize(width: 320, height: 180), model: PiPControlsModel(isCall: false))
        panel.present(from: nil)
        let screen = panel.screenFrame
        panel.moveBy(screen.midX - panel.frame.midX, screen.midY - panel.frame.midY)
        panel.release(velocity: .zero)
        let root = try #require(panel.contentView)
        #expect(root.hitTest(CGPoint(x: 2, y: 2)) === root)
        #expect(root.hitTest(CGPoint(x: 160, y: 90)) !== root)  // the controls

        let start = panel.frame
        let edges = panel.resizableEdges(at: CGPoint(x: 318, y: 178))
        #expect(edges == [.right, .top])
        panel.resize(from: start, edges: edges, by: CGVector(dx: 80, dy: 0))
        panel.endResize()
        #expect(panel.frame.size == CGSize(width: 400, height: 225))
        #expect(panel.frame.origin == start.origin)

        panel.release(velocity: CGVector(dx: 6000, dy: 0))
        #expect(panel.resizableEdges(at: CGPoint(x: 2, y: 100)).isEmpty)
        panel.dismiss()
    }
}

@MainActor
struct PiPSwipeTests {
    func swipe(_ phase: Int64, dx: Int32 = 0) -> NSEvent {
        let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: 0, wheel2: dx, wheel3: 0)!
        cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)  // 1 began, 2 changed, 4 ended
        cg.setIntegerValueField(.scrollWheelEventPointDeltaAxis2, value: Int64(dx))
        return NSEvent(cgEvent: cg)!
    }

    /// The pointer stays where it is, swipe after swipe: the panel slides from under it and back, and keeps moving,
    /// until the pointer moves. A swipe's events all go where it began, so the catcher changes only between swipes.
    @Test func swipesKeepMovingThePanelWhileThePointerStays() throws {
        _ = NSApplication.shared
        let panel = PiPPanel(content: .view(NSView()), size: CGSize(width: 320, height: 180), model: PiPControlsModel(isCall: false))
        panel.present(from: nil)
        let screen = panel.screenFrame
        panel.moveBy(screen.midX - panel.frame.midX, screen.midY - panel.frame.midY)  // in the middle
        var pointer = CGPoint(x: panel.frame.midX, y: panel.frame.midY)
        panel.pointerLocation = { pointer }

        // A swipe on the panel takes it away from under the pointer; the catcher waits for the swipe's end.
        panel.scroll(swipe(1))
        let before = panel.frame.minX
        panel.scroll(swipe(2, dx: -200))  // fingers right
        #expect(panel.frame.minX > before + 200)
        #expect(panel.heldPointer == pointer && panel.catcher?.isVisible != true)
        panel.scroll(swipe(4))
        let catcher = try #require(panel.catcher)
        #expect(catcher.isVisible && catcher.frame.contains(pointer))

        // The next swipe, over the catcher, brings the panel back under the pointer and past it: it keeps moving.
        let away = panel.frame.minX
        catcher.scroll(swipe(1))
        catcher.scroll(swipe(2, dx: 200))  // fingers left: back under the pointer
        #expect(panel.frame.minX < away && panel.frame.contains(pointer))
        #expect(catcher.isVisible)  // not mid-swipe
        catcher.scroll(swipe(2, dx: 40))
        #expect(panel.frame.minX < away - 300)
        catcher.scroll(swipe(4))

        // The pointer moves: swipes are its own again.
        pointer.x += 10
        catcher.pointerMoved()
        #expect(panel.heldPointer == nil && !catcher.isVisible)
        panel.orderOut(nil)
    }

    /// The video's place on the page, in CSS pixels, on screen: what of it shows in the page's area.
    @Test func theFlightStartsWhereTheVideoWas() {
        let page = CGRect(x: 300, y: 100, width: 1000, height: 600)  // the page's area on screen (y up)
        let viewport = CGSize(width: 1000, height: 600)
        #expect(PiPGeometry.screenRect(ofPageRect: CGRect(x: 100, y: 50, width: 640, height: 360), viewport: viewport, shownIn: page)
                == CGRect(x: 400, y: 290, width: 640, height: 360))
        // Zoomed out pages report more CSS pixels than points; scrolled half out, half shows; scrolled out, nothing.
        #expect(PiPGeometry.screenRect(ofPageRect: CGRect(x: 0, y: 0, width: 1000, height: 600), viewport: CGSize(width: 2000, height: 1200),
                                       shownIn: page) == CGRect(x: 300, y: 400, width: 500, height: 300))
        #expect(PiPGeometry.screenRect(ofPageRect: CGRect(x: 0, y: -180, width: 640, height: 360), viewport: viewport, shownIn: page)?.height == 180)
        #expect(PiPGeometry.screenRect(ofPageRect: CGRect(x: 0, y: -400, width: 640, height: 360), viewport: viewport, shownIn: page) == nil)
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

    /// A muted video (a landing page's backdrop) stays in its tab, as does one in a muted tab.
    @Test func onlyVideosWithSoundPopOut() throws {
        let h = try TestHarness(features: [PictureInPictureFeature.self], manifestDirectory: #filePath)
        let feature = try #require(h.runtime.feature(PictureInPictureFeature.self))
        let backdrop = h.openTab("https://landing.example")
        h.fakeTab(backdrop).simulateMedia(audio: false, video: true)
        #expect(!feature.shouldPopOut(backdrop))
        h.fakeTab(backdrop).simulateMedia(audio: true, video: true)
        h.fakeTab(backdrop).isMuted = true
        #expect(!feature.shouldPopOut(backdrop))
    }

    /// Leaving another playing tab leaves the floating video where it is.
    @Test func aFloatingVideoIsNeverReplacedAutomatically() throws {
        let h = try TestHarness(features: [PictureInPictureFeature.self], manifestDirectory: #filePath)
        let feature = try #require(h.runtime.feature(PictureInPictureFeature.self))
        let stream = h.openTab("https://stream.example/live")
        h.fakeTab(stream).simulateMedia(audio: true, video: true)
        let other = h.openTab("https://video.example/watch")
        #expect(feature.session?.tabID == stream.id)
        h.fakeTab(other).simulateMedia(audio: true, video: true)
        _ = h.openTab("https://news.example")
        #expect(feature.session?.tabID == stream.id)
        feature.close(expand: false)
    }

    /// The window stops showing: its playing video floats, the tab still selected there; showing again, the window
    /// takes it back. A video that floated from a tab switch stays out.
    @Test func aHiddenWindowsVideoFloatsUntilItShowsAgain() throws {
        let h = try TestHarness(features: [PictureInPictureFeature.self], manifestDirectory: #filePath)
        let feature = try #require(h.runtime.feature(PictureInPictureFeature.self))
        let silent = h.openTab("https://landing.example")
        h.fakeTab(silent).simulateMedia(audio: false, video: true)
        feature.windowHidden(h.window)
        #expect(feature.session == nil)

        let video = h.openTab("https://video.example/watch")
        h.fakeTab(video).simulateMedia(audio: true, video: true)
        feature.windowHidden(h.window)
        #expect(feature.session?.tabID == video.id && h.window.selectedTabID == video.id)
        feature.windowShown(h.window)
        #expect(feature.session == nil && h.window.selectedTabID == video.id)

        _ = h.openTab("https://news.example")  // leaving the video: it floats
        #expect(feature.session?.tabID == video.id)
        feature.windowShown(h.window)
        #expect(feature.session?.tabID == video.id)
        feature.close(expand: false)
    }

    /// The page's "Picture in Picture" (its context menu) floats that tab here, muted or not, and the window leaves it.
    @Test func thePagesOwnRequestFloatsHere() throws {
        let h = try TestHarness(features: [PictureInPictureFeature.self], manifestDirectory: #filePath)
        let feature = try #require(h.runtime.feature(PictureInPictureFeature.self))
        let first = h.openTab("https://news.example")
        let video = h.openTab("https://video.example/watch")
        h.fakeTab(video).simulateMedia(audio: false, video: true)
        let handled = h.engine.hooks.pictureInPicture?(h.fakeTab(video), URL(string: "blob:https://video.example/1"))
        #expect(handled == true)
        #expect(feature.session?.tabID == video.id)
        #expect(h.window.selectedTabID == first.id)
        #expect(PiPScripts.enter(video: URL(string: "blob:https://video.example/1")).contains(#"const wanted = "blob:https:\/\/video.example\/1""#))
        feature.close(expand: false)
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

    /// Two fingers moving right and up move the panel right and up, with "natural" scrolling on or off, a little
    /// further than they travel.
    @Test func trackpadMovesFollowTheFingers() {
        let g = PiPPhysics.trackpadGain
        // Fingers right and up: natural scrolling reports +x, -y; the other setting -x, +y.
        #expect(PiPPhysics.fingerMove(scrollX: 10, scrollY: -6, natural: true) == CGVector(dx: 10 * g, dy: 6 * g))
        #expect(PiPPhysics.fingerMove(scrollX: -10, scrollY: 6, natural: false) == CGVector(dx: 10 * g, dy: 6 * g))
        #expect(g > 1)
    }

    /// Never fully off screen: sideways a strip always shows (as tucked in), vertically all of it; anything inside is
    /// left as it is.
    @Test func neverFullyOffScreen() {
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900), size = CGSize(width: 400, height: 225)
        let visible = PiPPhysics.stashVisible
        let right = PiPPhysics.neverLost(CGRect(origin: CGPoint(x: 5000, y: 300), size: size), in: screen)
        #expect(right.minX == screen.maxX - visible && right.minY == 300)
        let left = PiPPhysics.neverLost(CGRect(origin: CGPoint(x: -5000, y: 2000), size: size), in: screen)
        #expect(left.maxX == screen.minX + visible && left.maxY == screen.maxY)
        let inside = CGRect(origin: CGPoint(x: 600, y: 300), size: size)
        #expect(PiPPhysics.neverLost(inside, in: screen) == inside)
        // Partly past an edge is fine (it tucks in once released there).
        let partly = CGRect(origin: CGPoint(x: 1300, y: 300), size: size)
        #expect(PiPPhysics.neverLost(partly, in: screen) == partly)
    }

    /// A release throws at the speed of the last moves; fingers that stopped before lifting throw nothing.
    @Test func releaseVelocityIsTheLastMoves() {
        let moving: [(t: TimeInterval, d: CGVector)] = (0...6).map { (t: 10 + Double($0) * 0.01, d: CGVector(dx: 20, dy: 0)) }
        let v = PiPPhysics.velocity(of: moving, at: 10.07)
        #expect(abs(v.dx - 2000) < 1 && v.dy == 0)
        #expect(PiPPhysics.velocity(of: moving, at: 10.5) == .zero)
    }

    /// Re-aimed on its way (the video's shape known), the panel keeps its speed: no stop and start.
    @Test func reAimingKeepsTheSpeed() {
        var spring = PiPPhysics.FrameSpring(from: CGRect(x: 0, y: 0, width: 800, height: 450), velocity: .zero,
                                            to: CGRect(x: 1000, y: 16, width: 320, height: 180))
        for _ in 0..<6 { spring.advance(by: 1.0 / 60) }
        let aimed = spring.aimed(at: CGRect(x: 1000, y: 16, width: 320, height: 240))
        #expect(aimed.velocity == spring.velocity && aimed.frame == spring.frame && hypot(aimed.velocity.dx, aimed.velocity.dy) > 100)
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
}
