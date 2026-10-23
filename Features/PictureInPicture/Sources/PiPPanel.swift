import AppKit
import BrowserCore
import SwiftUI

@Observable
final class PiPControlsModel {
    enum Action { case close, expand, togglePlay, toggleMute, seek(Double), seekTo(Double) }

    let isCall: Bool
    var hovering = false { didSet { if hovering != oldValue { onHoverChanged?(hovering) } } }
    var paused = false
    var muted = false
    var time: Double = 0
    var duration: Double = 0
    var stashed = false
    @ObservationIgnored var perform: (Action) -> Void = { _ in }
    @ObservationIgnored var onHoverChanged: ((Bool) -> Void)?

    init(isCall: Bool) { self.isCall = isCall }
}

/// The floating window: above every app and Space, never steals focus, moved with springs.
final class PiPPanel: NSPanel {
    private let model: PiPControlsModel
    private let content: FloatingContent
    private var aspect: CGFloat = 16 / 9
    /// Size the panel settles to (the live frame may be mid-animation).
    private var targetSize: CGSize
    private(set) var resting: PiPPhysics.Resting = .placed(.zero)

    init(content: FloatingContent, size: CGSize, model: PiPControlsModel) {
        self.model = model
        self.content = content
        targetSize = size
        super.init(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
                   backing: .buffered, defer: false)
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        hidesOnDeactivate = false
        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = true
        isMovableByWindowBackground = false
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        isReleasedWhenClosed = false
        animationBehavior = .none

        let root = PiPRootView(frame: CGRect(origin: .zero, size: size), panel: self)
        root.wantsLayer = true
        root.layer?.cornerRadius = Design.windowRadius
        root.layer?.cornerCurve = .continuous
        root.layer?.masksToBounds = true
        if case .window = content {
            // The page window sits below; a near-clear fill keeps drags on the panel instead of the page.
            root.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.01).cgColor
        } else {
            root.layer?.backgroundColor = NSColor.black.cgColor
        }
        if case .view(let v) = content {
            v.frame = root.bounds
            v.autoresizingMask = [.width, .height]
            root.addSubview(v)
        }
        let controls = NSHostingView(rootView: PiPControls(model: model))
        controls.appearance = NSAppearance(named: .darkAqua)  // over video, whatever the system's appearance
        controls.frame = root.bounds
        controls.autoresizingMask = [.width, .height]
        root.addSubview(controls)
        contentView = root
        if case .window(let w) = content {
            // Engine-owned page window (CEF): it follows the panel and sits under the controls. It stays where it is
            // (the browser's content) until the panel flies.
            w.level = .floating
            w.collectionBehavior = collectionBehavior
            addChildWindow(w, ordered: .below)
            w.orderFront(nil)
        }
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// The engine's page window while the panel holds it. Once the page is back in the browser window (reattached,
    /// presented again), nothing here touches it: not the fade's end, nor a late spring or aspect change.
    private var pageWindow: NSWindow? {
        if case .window(let w) = content, w.parent === self { return w }
        return nil
    }

    var screenFrame: CGRect { (screen ?? NSScreen.main)?.visibleFrame ?? .zero }

    func setAspect(_ ratio: CGFloat) {
        guard ratio.isFinite, ratio > 0.3, ratio < 4 else { return }
        aspect = ratio
        targetSize = CGSize(width: targetSize.width, height: (targetSize.width / ratio).rounded())
        if isVisible { settle(PiPPhysics.frame(for: resting, size: targetSize, in: screenFrame)) }  // else `present` uses it
    }

    private var dismissed = false

    /// Flies from `start` (the video where it was on the page) into the bottom-right corner; without one, rises there.
    func present(from start: CGRect?) {
        guard !dismissed else { return }  // closed before it flew (back to the tab at once)
        resting = .placed(PiPPhysics.cornerOrigin(size: targetSize, in: screenFrame))
        let target = PiPPhysics.frame(for: resting, size: targetSize, in: screenFrame)
        if let start {
            setFrame(start, display: false)
            alphaValue = 1
        } else {
            setFrame(target.offsetBy(dx: 0, dy: -40), display: false)
            alphaValue = 0
        }
        orderFrontRegardless()
        watchPinches()
        if let w = pageWindow {
            w.contentView?.layer?.cornerRadius = Design.windowRadius  // the browser sets its card's back when shown there
            w.setFrame(frame, display: false)
            w.orderFront(nil)
        }
        settle(target)
        NSAnimationContext.animate(.easeOut(duration: 0.3)) { animator().alphaValue = 1 }
    }

    func dismiss() {
        dismissed = true
        stopWatchingPinches()
        pinchAnchor = nil
        isSizing = false
        keepStillReady(false)
        removeStill()
        stopSpring()
        releaseSwipes()
        NSAnimationContext.animate(.easeIn(duration: 0.18)) {
            animator().alphaValue = 0
        } completion: { [weak self] in
            self?.fadedOut()
        }
    }

    /// The page leaves with the panel, unless it's back in the browser window already.
    func fadedOut() {
        if let w = pageWindow { removeChildWindow(w); w.orderOut(nil) }
        orderOut(nil)
    }

    // Our own spring, not AppKit's animations: it starts at the throw's velocity, and fingers can catch the panel
    // mid-flight.
    private var spring: PiPPhysics.FrameSpring?
    private var springLink: CADisplayLink?
    private var lastStep: CFTimeInterval = 0

    /// Springs to `target`, at `velocity` from a release; already on its way, it's re-aimed keeping its speed.
    func settle(_ target: CGRect, velocity: CGVector? = nil) {
        if let velocity {
            spring = PiPPhysics.FrameSpring(from: frame, velocity: velocity, to: target)
        } else {
            spring = spring?.aimed(at: target) ?? PiPPhysics.FrameSpring(from: frame, velocity: .zero, to: target)
        }
        lastStep = CACurrentMediaTime()
        guard springLink == nil else { return }
        let link = displayLink(target: self, selector: #selector(stepSpring(_:)))
        link.add(to: .main, forMode: .common)
        springLink = link
    }

    @objc private func stepSpring(_ link: CADisplayLink) {
        guard var spring else { return stopSpring() }
        let now = CACurrentMediaTime()
        spring.advance(by: now - lastStep)
        lastStep = now
        if spring.isSettled {
            place(spring.target)
            stopSpring()
            placeCatcher()  // where it glided to may be under the pointer, or away from it
        } else {
            self.spring = spring
            place(spring.frame)
        }
    }

    private func stopSpring() {
        springLink?.invalidate()
        springLink = nil
        spring = nil
    }

    private func place(_ f: CGRect) {
        let f = PiPPhysics.neverLost(f, in: screenFrame)
        setFrame(f, display: true)
        if let still, let root = contentView {
            still.frame = root.bounds  // the page, hidden, takes the new size at the end
        } else {
            pageWindow?.setFrame(f, display: true)
        }
    }

    /// Moves with the pointer or the fingers. Past a side edge it goes as far as tucked in, no further.
    func moveBy(_ dx: CGFloat, _ dy: CGFloat) {
        stopSpring()
        let moved = PiPPhysics.neverLost(frame.offsetBy(dx: dx, dy: dy), in: screenFrame)
        setFrameOrigin(moved.origin)
        pageWindow?.setFrameOrigin(frame.origin)
        if model.stashed { model.stashed = false }
    }

    /// Released with a velocity (points/second): it glides on to where the throw ends, or tucks into the edge it's
    /// thrown past. Still fingers leave it where it is.
    func release(velocity: CGVector) {
        resting = PiPPhysics.rest(frame: CGRect(origin: frame.origin, size: targetSize), velocity: velocity, in: screenFrame)
        if case .stashed = resting { model.stashed = true } else { model.stashed = false }
        settle(PiPPhysics.frame(for: resting, size: targetSize, in: screenFrame), velocity: velocity)
    }

    /// Back out of the edge it's tucked into.
    func unstash() {
        guard case .stashed(let left, let y) = resting else { return }
        let x = left ? screenFrame.minX + PiPPhysics.margin : screenFrame.maxX - targetSize.width - PiPPhysics.margin
        resting = .placed(CGPoint(x: x, y: y))
        model.stashed = false
        settle(PiPPhysics.frame(for: resting, size: targetSize, in: screenFrame))
    }

    // MARK: Two-finger moves

    private var swipeMoves: [(t: TimeInterval, d: CGVector)] = []
    private(set) var catcher: SwipeCatcher?
    private var swipeMonitor: Any?
    /// Where the pointer stood when swipes on the panel began: swipes move the panel, wherever it is, until the pointer
    /// leaves that spot.
    private(set) var heldPointer: CGPoint?
    /// Where the pointer is (tests set it).
    var pointerLocation: () -> CGPoint = { NSEvent.mouseLocation }

    /// Two fingers on the trackpad move the panel (Radian: "controllable with trackpad"), the pointer staying where it
    /// is, swipe after swipe, while the panel slides away from under it.
    func scroll(_ event: NSEvent) {
        guard event.hasPreciseScrollingDeltas, event.momentumPhase.isEmpty else { return }  // our spring replaces momentum
        switch event.phase {
        case .began, .changed:
            if heldPointer == nil { holdSwipes() }
            if event.phase == .began { swipeMoves = [] }
            let d = PiPPhysics.fingerMove(scrollX: event.scrollingDeltaX, scrollY: event.scrollingDeltaY,
                                          natural: event.isDirectionInvertedFromDevice)
            swipeMoves.append((event.timestamp, d))
            if swipeMoves.count > 16 { swipeMoves.removeFirst() }
            moveBy(d.dx, d.dy)
        case .ended, .cancelled:
            release(velocity: PiPPhysics.velocity(of: swipeMoves, at: event.timestamp))
            placeCatcher()
        default:
            break
        }
    }

    private func holdSwipes() {
        heldPointer = pointerLocation()
        guard swipeMonitor == nil else { return }
        // Swipes over the browser's own windows (a page that scrolls) come here first, and scroll nothing else.
        swipeMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self, self.heldPointer != nil else { return event }
            guard self.pointerStays() else {
                self.releaseSwipes()
                return event
            }
            self.scroll(event)
            return nil
        }
    }

    private func pointerStays() -> Bool {
        guard let held = heldPointer else { return false }
        let now = pointerLocation()
        return hypot(now.x - held.x, now.y - held.y) <= 3
    }

    /// Between swipes only: all of a swipe's events go to the window it began over, whatever comes under the pointer
    /// meanwhile. Where the panel isn't under the pointer, the catcher takes the next ones (over other apps too); over
    /// the panel they reach it anyway, and so do clicks.
    private func placeCatcher() {
        guard let pointer = heldPointer else { return }
        guard pointerStays() else { return releaseSwipes() }
        if frame.contains(pointer) {
            catcher?.orderOut(nil)
            return
        }
        let catcher = catcher ?? SwipeCatcher(panel: self)
        self.catcher = catcher
        catcher.hold(at: pointer)
    }

    /// The pointer moved: swipes are the pointer's again.
    func releaseSwipes() {
        heldPointer = nil
        catcher?.orderOut(nil)
        if let swipeMonitor { NSEvent.removeMonitor(swipeMonitor) }
        swipeMonitor = nil
    }

    /// Pinches over the panel, or where its swipes are held.
    private func isUnder(_ pointer: CGPoint) -> Bool {
        frame.contains(pointer) || (heldPointer != nil && pointerStays())
    }

    /// Pinches go to the frontmost app only, whatever is under the pointer, and the panel never takes focus. With this
    /// app in front, a local monitor catches them over the panel. Over other apps no monitor, view or touch sees them;
    /// only a listen-only event tap does, once the user allows Input Monitoring (asked on the first pinch seen here).
    private var pinchMonitor: Any?
    private var pinchTap: CFMachPort?
    private static var askedForPinchesEverywhere = false

    func watchPinches() {
        tapPinches()
        guard pinchMonitor == nil else { return }
        pinchMonitor = NSEvent.addLocalMonitorForEvents(matching: .magnify) { [weak self] event in
            guard let self, self.takesPinch() else { return event }
            if self.pinchTap == nil {
                self.pinch(event)
                self.askForPinchesEverywhere()
            }
            return nil  // the tap has it already
        }
    }

    func stopWatchingPinches() {
        if let pinchMonitor { NSEvent.removeMonitor(pinchMonitor) }
        pinchMonitor = nil
        if let pinchTap {
            CGEvent.tapEnable(tap: pinchTap, enable: false)
            CFMachPortInvalidate(pinchTap)
        }
        pinchTap = nil
    }

    private func askForPinchesEverywhere() {
        guard !Self.askedForPinchesEverywhere, !CGPreflightListenEventAccess() else { return }
        Self.askedForPinchesEverywhere = true
        CGRequestListenEventAccess()
    }

    private func tapPinches() {
        guard pinchTap == nil, CGPreflightListenEventAccess() else { return }
        let callback: CGEventTapCallBack = { _, type, event, info in
            if let info {
                let panel = Unmanaged<PiPPanel>.fromOpaque(info).takeUnretainedValue()
                MainActor.assumeIsolated { panel.tapped(type, event) }
            }
            return Unmanaged.passUnretained(event)
        }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .tailAppendEventTap, options: .listenOnly,
                                          eventsOfInterest: CGEventMask(1) << 29,  // gestures, pinches among them
                                          callback: callback, userInfo: Unmanaged.passUnretained(self).toOpaque())
        else { return }
        CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        pinchTap = tap
    }

    private func tapped(_ type: CGEventType, _ cgEvent: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let pinchTap { CGEvent.tapEnable(tap: pinchTap, enable: true) }
            return
        }
        guard let event = NSEvent(cgEvent: cgEvent), event.type == .magnify, takesPinch() else { return }
        pinch(event)
    }

    /// A pinch begun over the panel is the panel's until the fingers lift, wherever the pointer drifts meanwhile.
    private var pinchAnchor: CGPoint?

    private func takesPinch() -> Bool {
        pinchAnchor != nil || (isVisible && isUnder(pointerLocation()))
    }

    isolated deinit {
        if let pinchTap { CFMachPortInvalidate(pinchTap) }  // its callback holds this panel unretained
    }

    func pinch(_ event: NSEvent) {
        if pinchAnchor == nil || event.phase == .began {
            let pointer = pointerLocation()
            pinchAnchor = frame.contains(pointer) ? pointer : CGPoint(x: frame.midX, y: frame.midY)
            beginSizing()
        }
        magnify(by: event.magnification, around: pinchAnchor ?? .zero)
        // Once the fingers lift, it settles where it is at the new size (on screen, or tucked in still).
        guard event.phase == .ended || event.phase == .cancelled else { return }
        pinchAnchor = nil
        if case .placed = resting { resting = .placed(frame.origin) }
        endSizing()
        settle(PiPPhysics.frame(for: resting, size: targetSize, in: screenFrame))
    }

    /// Scales around `anchor`, which keeps its place in the panel: the pointer stays over it, pinch after pinch.
    func magnify(by amount: CGFloat, around anchor: CGPoint) {
        stopSpring()
        targetSize = PiPPhysics.resized(frame.size, by: amount, aspect: aspect)
        place(PiPPhysics.scaled(frame, to: targetSize, around: anchor))
    }

    // MARK: Edge drags

    /// The edges a point of the panel would resize; none while tucked in (a drag brings it out instead).
    func resizableEdges(at point: CGPoint) -> PiPPhysics.Edges {
        guard case .placed = resting else { return [] }
        return PiPPhysics.edges(at: point, in: CGRect(origin: .zero, size: frame.size))
    }

    /// Resizes as macOS's own PiP does, without any permission (mouse events reach a window whatever app is in front).
    func resize(from start: CGRect, edges: PiPPhysics.Edges, by offset: CGVector) {
        stopSpring()
        beginSizing()
        let f = PiPPhysics.resized(start, edges: edges, by: offset, aspect: aspect)
        targetSize = f.size
        place(f)
    }

    func endResize() {
        resting = .placed(frame.origin)
        endSizing()
    }

    // MARK: Size changes

    /// Takes a still of the page (the session asks the engine).
    var takeStill: ((@escaping (NSImage?) -> Void) -> Void)?
    private(set) var still: CALayer?
    private(set) var isSizing = false
    private var sizingGeneration = 0

    /// While a pinch or a drag changes its size, the page doesn't follow: Chromium draws a new size frames late (black
    /// strips meanwhile), and a web view's frame is never animated. A still of it, scaled, stands in; at the end the
    /// page takes the new size and comes back once drawn.
    private func beginSizing() {
        guard !isSizing else { return }
        isSizing = true
        sizingGeneration += 1
        if still != nil { return showPage(false) }  // the last one still up
        if let readyStill { return showStill(readyStill) }
        let generation = sizingGeneration
        takeStill? { [weak self] image in
            guard let self, self.isSizing, self.sizingGeneration == generation,
                  let cg = image?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
            self.showStill(cg)
        }
    }

    /// Under the pointer, a still is kept ready, refreshed while it stays: one taken as a pinch began came frames late
    /// (the page resizing meanwhile) and its decoding stalled the first ones.
    private(set) var readyStill: CGImage?
    private var stillRefresh: Timer?

    func keepStillReady(_ on: Bool) {
        stillRefresh?.invalidate()
        stillRefresh = nil
        guard on, !dismissed else { return }
        // Not as the pointer arrives: reading the still back takes the main thread a few frames, which the controls'
        // fade-in needs.
        let timer = Timer(fire: Date(timeIntervalSinceNow: Self.stillDelay), interval: 1.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshStill() }
        }
        RunLoop.main.add(timer, forMode: .common)
        stillRefresh = timer
    }

    static let stillDelay: TimeInterval = 0.35

    private func refreshStill() {
        guard !isSizing else { return }
        takeStill? { [weak self] image in
            guard let image else { return }
            Task.detached(priority: .userInitiated) {
                let decoded = Self.decoded(image)
                await MainActor.run { if let decoded { self?.readyStill = decoded } }
            }
        }
    }

    /// Drawn once into a bitmap: a PNG-backed image otherwise decodes when first shown, on the main thread.
    nonisolated static func decoded(_ image: NSImage) -> CGImage? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let context = CGContext(data: nil, width: cg.width, height: cg.height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        context.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        return context.makeImage()
    }

    func showStill(_ cg: CGImage) {
        guard let root = contentView?.layer else { return }
        let layer = CALayer()
        layer.actions = ["bounds": NSNull(), "position": NSNull(), "contents": NSNull()]
        layer.contents = cg
        layer.contentsGravity = .resizeAspectFill
        layer.frame = root.bounds
        root.insertSublayer(layer, at: 0)  // under the controls
        still = layer
        showPage(false)
    }

    private func endSizing() {
        guard isSizing else { return }
        isSizing = false
        if case .view = content { return removeStill() }  // the view follows the panel: shown at its size already
        pageWindow?.setFrame(frame, display: true)
        guard still != nil else { return }
        let generation = sizingGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self, !self.isSizing, self.sizingGeneration == generation else { return }
            self.removeStill(fading: true)
        }
    }

    func removeStill(fading: Bool = false) {
        showPage(true)
        guard let still else { return }
        self.still = nil
        guard fading else { return still.removeFromSuperlayer() }
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.15)
        CATransaction.setCompletionBlock { still.removeFromSuperlayer() }
        still.opacity = 0
        CATransaction.commit()
    }

    private func showPage(_ shown: Bool) {
        switch content {
        case .window(let w): w.alphaValue = shown ? 1 : 0
        case .view(let v): v.isHidden = !shown
        }
    }
}

/// Mouse drag, two-finger trackpad moves, pinch and hover for the panel.
final class PiPRootView: NSView {
    private weak var panel: PiPPanel?
    private var samples: [(t: TimeInterval, d: CGVector)] = []
    private var dragStart: CGPoint?
    private var resizing: (edges: PiPPhysics.Edges, start: CGRect, mouse: CGPoint)?
    private var tracking: NSTrackingArea?

    init(frame: CGRect, panel: PiPPanel) {
        self.panel = panel
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        tracking = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(tracking!)
    }

    override func mouseEntered(with event: NSEvent) {
        setHover(true)
        panel?.watchPinches()  // Input Monitoring allowed since: pinches over other apps from now on
    }
    override func mouseExited(with event: NSEvent) {
        setHover(false)
        if resizing == nil { NSCursor.arrow.set() }
    }

    override func mouseMoved(with event: NSEvent) {
        guard resizing == nil else { return }
        Self.cursor(for: panel?.resizableEdges(at: convert(event.locationInWindow, from: nil)) ?? []).set()
    }

    /// The edges take the mouse before the controls under them.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        if bounds.contains(local), panel?.resizableEdges(at: local).isEmpty == false { return self }
        return super.hitTest(point)
    }

    static func cursor(for edges: PiPPhysics.Edges) -> NSCursor {
        let position: NSCursor.FrameResizePosition? = switch edges {
        case [.left, .top]: .topLeft
        case [.right, .top]: .topRight
        case [.left, .bottom]: .bottomLeft
        case [.right, .bottom]: .bottomRight
        case .left: .left
        case .right: .right
        case .top: .top
        case .bottom: .bottom
        default: nil
        }
        return position.map { NSCursor.frameResize(position: $0, directions: .all) } ?? .arrow
    }

    private func setHover(_ h: Bool) {
        panel?.keepStillReady(h)
        guard let root = subviews.compactMap({ $0 as? NSHostingView<PiPControls> }).first else { return }
        root.rootView.model.hovering = h
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // Mouse drag (click anywhere that isn't a control).
    override func mouseDown(with event: NSEvent) {
        if let panel, case let edges = panel.resizableEdges(at: convert(event.locationInWindow, from: nil)), !edges.isEmpty {
            resizing = (edges, panel.frame, NSEvent.mouseLocation)
            return
        }
        dragStart = NSEvent.mouseLocation
        samples = []
        if event.clickCount == 2 { panel?.unstash() }
    }

    override func mouseDragged(with event: NSEvent) {
        if let resizing {
            let now = NSEvent.mouseLocation
            panel?.resize(from: resizing.start, edges: resizing.edges, by: CGVector(dx: now.x - resizing.mouse.x, dy: now.y - resizing.mouse.y))
            return
        }
        guard let start = dragStart else { return }
        let now = NSEvent.mouseLocation
        let d = CGVector(dx: now.x - start.x, dy: now.y - start.y)
        dragStart = now
        record(d, at: event.timestamp)
        panel?.moveBy(d.dx, d.dy)
    }

    override func mouseUp(with event: NSEvent) {
        if resizing != nil {
            resizing = nil
            panel?.endResize()
            return
        }
        guard dragStart != nil else { return }
        dragStart = nil
        panel?.release(velocity: PiPPhysics.velocity(of: samples, at: event.timestamp))
    }

    override func scrollWheel(with event: NSEvent) { panel?.scroll(event) }

    override func magnify(with event: NSEvent) { panel?.pinch(event) }

    private func record(_ d: CGVector, at t: TimeInterval) {
        samples.append((t, d))
        if samples.count > 16 { samples.removeFirst() }
    }
}

/// A small invisible window under a still pointer that hands the next swipes to the panel once it has slid from under
/// the pointer: swipes go to what's under the pointer, other apps' windows included. Gone once the pointer moves (or
/// clicks: that click is its, not what's below).
final class SwipeCatcher: NSPanel {
    private weak var panel: PiPPanel?
    private var pointer = CGPoint.zero
    static let size: CGFloat = 48

    init(panel: PiPPanel) {
        self.panel = panel
        super.init(contentRect: CGRect(x: 0, y: 0, width: Self.size, height: Self.size), styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)  // over the panel
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        ignoresMouseEvents = false
        acceptsMouseMovedEvents = true
        contentView = SwipeCatcherView(catcher: self)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func hold(at pointer: CGPoint) {
        self.pointer = pointer
        setFrameOrigin(CGPoint(x: pointer.x - Self.size / 2, y: pointer.y - Self.size / 2))
        if !isVisible { orderFrontRegardless() }
    }

    func scroll(_ event: NSEvent) { panel?.scroll(event) }
    func pinch(_ event: NSEvent) { panel?.pinch(event) }

    /// Mouse moves and exits here may be the window's own coming and going: only the pointer's moving ends the hold.
    func pointerMoved() {
        guard let panel else { return orderOut(nil) }
        let now = panel.pointerLocation()
        if hypot(now.x - pointer.x, now.y - pointer.y) > 3 { panel.releaseSwipes() }
    }

    func clicked() { panel?.releaseSwipes() }
}

final class SwipeCatcherView: NSView {
    private weak var catcher: SwipeCatcher?

    init(catcher: SwipeCatcher) {
        self.catcher = catcher
        super.init(frame: CGRect(x: 0, y: 0, width: SwipeCatcher.size, height: SwipeCatcher.size))
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.01).cgColor  // takes the events, shows nothing
    }

    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func scrollWheel(with event: NSEvent) { catcher?.scroll(event) }
    override func magnify(with event: NSEvent) { catcher?.pinch(event) }
    override func mouseMoved(with event: NSEvent) { catcher?.pointerMoved() }
    override func mouseExited(with event: NSEvent) { catcher?.pointerMoved() }
    override func mouseDown(with event: NSEvent) { catcher?.clicked() }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

struct PiPControls: View {
    let model: PiPControlsModel

    var body: some View {
        ZStack {
            if model.hovering && !model.stashed {
                // Only enough shade at the edges for the glass to read over a bright video.
                LinearGradient(colors: [.black.opacity(0.3), .clear, .clear, .black.opacity(0.3)], startPoint: .top, endPoint: .bottom)
                    .allowsHitTesting(false)
                VStack(spacing: 0) {
                    HStack(alignment: .top) {
                        GlassButton(symbol: "xmark", help: "Close") { model.perform(.close) }
                        Spacer()
                        GlassGroup(spacing: 6) {
                            HStack(spacing: 6) {
                                GlassButton(symbol: model.muted ? "speaker.slash.fill" : "speaker.wave.2.fill", help: model.muted ? "Unmute" : "Mute") {
                                    model.perform(.toggleMute)
                                }
                                GlassButton(symbol: "pip.exit", help: "Back to the Tab") { model.perform(.expand) }
                            }
                        }
                    }
                    Spacer(minLength: 0)
                    if !model.isCall {
                        HStack(spacing: 4) {
                            PlainSymbolButton(symbol: "gobackward.10", size: 15, help: "Back 10 Seconds") { model.perform(.seek(-10)) }
                            PlainSymbolButton(symbol: model.paused ? "play.fill" : "pause.fill", size: 22, help: model.paused ? "Play" : "Pause") {
                                model.perform(.togglePlay)
                            }
                            PlainSymbolButton(symbol: "goforward.10", size: 15, help: "Forward 10 Seconds") { model.perform(.seek(10)) }
                        }
                        .padding(.horizontal, 6)
                        .glassSurface(in: Capsule(), interactive: true)
                        Spacer(minLength: 0)
                        if model.duration > 0 {
                            Scrubber(model: model)
                        }
                    }
                }
                .padding(Design.Space.block)
                .transition(.opacity)
            }
            if model.stashed {
                Image(systemName: "chevron.compact.left").font(.system(size: 18, weight: .bold)).foregroundStyle(.white.opacity(0.9))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.black.opacity(0.35))
                    .allowsHitTesting(false)
            }
        }
        .environment(\.colorScheme, .dark)  // over video, whatever the system's appearance
        .animation(.easeOut(duration: 0.18), value: model.hovering)
        .animation(.spring(duration: 0.3), value: model.stashed)
    }

    static func format(_ t: Double) -> String {
        let s = Int(t.rounded(.down))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s % 3600 / 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// A round Liquid Glass button over the video.
struct GlassButton: View {
    let symbol: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .bold))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 28, height: 28)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .glassControl(in: Circle(), hover: false)
        .help(help)
    }
}

/// A symbol in a glass group (the playback capsule): the group is the glass.
struct PlainSymbolButton: View {
    let symbol: String
    let size: CGFloat
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 36, height: 36)
                .contentShape(Circle())
                .background(Circle().fill(hovering ? Design.Fill.hover : .clear))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .onHover { h in withAnimation(Design.Motion.hover) { hovering = h } }
        .help(help)
    }
}

/// Elapsed, the bar, remaining: one glass capsule along the bottom.
struct Scrubber: View {
    let model: PiPControlsModel

    var body: some View {
        HStack(spacing: 8) {
            Text(PiPControls.format(model.time)).monospacedDigit()
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.25))
                    Capsule().fill(.white).frame(width: g.size.width * CGFloat(model.time / max(model.duration, 1)))
                }
                .frame(height: 4)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onEnded { v in
                    model.perform(.seekTo(Double(max(0, min(1, v.location.x / g.size.width)))))
                })
            }
            .frame(height: 14)
            Text("-" + PiPControls.format(max(0, model.duration - model.time))).monospacedDigit()
        }
        .font(.system(size: 10, weight: .semibold))
        .foregroundStyle(.white.opacity(0.9))
        .padding(.horizontal, 12)
        .frame(height: 28)
        .glassSurface(in: Capsule())
    }
}
