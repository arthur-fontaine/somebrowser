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
        root.layer?.cornerRadius = 12
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
        if let w = pageWindow { w.setFrame(frame, display: false); w.orderFront(nil) }
        settle(target)
        NSAnimationContext.animate(.easeOut(duration: 0.3)) { animator().alphaValue = 1 }
    }

    func dismiss() {
        dismissed = true
        stopWatchingPinches()
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
        pageWindow?.setFrame(f, display: true)
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

    /// A pinch over the panel. AppKit sends pinches to the key window, and the panel never becomes key (it never takes
    /// focus): monitors catch them over it, in this app (active) and in others (it floats over them).
    private var pinchMonitors: [Any] = []

    func watchPinches() {
        guard pinchMonitors.isEmpty else { return }
        if let local = NSEvent.addLocalMonitorForEvents(matching: .magnify, handler: { [weak self] event in
            guard let self, self.isVisible, self.isUnder(self.pointerLocation()) else { return event }
            self.pinch(event)
            return nil
        }) { pinchMonitors.append(local) }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: .magnify, handler: { [weak self] event in
            guard let self, self.isVisible, self.isUnder(self.pointerLocation()) else { return }
            self.pinch(event)
        }) { pinchMonitors.append(global) }
    }

    func stopWatchingPinches() {
        pinchMonitors.forEach(NSEvent.removeMonitor)
        pinchMonitors.removeAll()
    }

    func pinch(_ event: NSEvent) {
        magnify(by: event.magnification)
        // Once the fingers lift, it settles where it is at the new size (on screen, or tucked in still).
        guard event.phase == .ended || event.phase == .cancelled else { return }
        if case .placed = resting { resting = .placed(frame.origin) }
        settle(PiPPhysics.frame(for: resting, size: targetSize, in: screenFrame))
    }

    func magnify(by amount: CGFloat) {
        stopSpring()
        let size = PiPPhysics.resized(frame.size, by: amount, aspect: aspect)
        targetSize = size
        let center = CGPoint(x: frame.midX, y: frame.midY)
        place(CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2, width: size.width, height: size.height))
    }
}

/// Mouse drag, two-finger trackpad moves, pinch and hover for the panel.
final class PiPRootView: NSView {
    private weak var panel: PiPPanel?
    private var samples: [(t: TimeInterval, d: CGVector)] = []
    private var dragStart: CGPoint?
    private var tracking: NSTrackingArea?

    init(frame: CGRect, panel: PiPPanel) {
        self.panel = panel
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        tracking = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(tracking!)
    }

    override func mouseEntered(with event: NSEvent) { setHover(true) }
    override func mouseExited(with event: NSEvent) { setHover(false) }

    private func setHover(_ h: Bool) {
        guard let root = subviews.compactMap({ $0 as? NSHostingView<PiPControls> }).first else { return }
        root.rootView.model.hovering = h
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // Mouse drag (click anywhere that isn't a control).
    override func mouseDown(with event: NSEvent) {
        dragStart = NSEvent.mouseLocation
        samples = []
        if event.clickCount == 2 { panel?.unstash() }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStart else { return }
        let now = NSEvent.mouseLocation
        let d = CGVector(dx: now.x - start.x, dy: now.y - start.y)
        dragStart = now
        record(d, at: event.timestamp)
        panel?.moveBy(d.dx, d.dy)
    }

    override func mouseUp(with event: NSEvent) {
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
                LinearGradient(colors: [.black.opacity(0.55), .clear, .clear, .black.opacity(0.55)], startPoint: .top, endPoint: .bottom)
                    .allowsHitTesting(false)
                VStack {
                    HStack {
                        CircleButton(symbol: "xmark") { model.perform(.close) }
                        Spacer()
                        CircleButton(symbol: model.muted ? "speaker.slash.fill" : "speaker.wave.2.fill") { model.perform(.toggleMute) }
                        CircleButton(symbol: "arrow.up.left.and.arrow.down.right") { model.perform(.expand) }
                    }
                    Spacer()
                    if !model.isCall {
                        HStack(spacing: 22) {
                            CircleButton(symbol: "gobackward.10", size: 30) { model.perform(.seek(-10)) }
                            CircleButton(symbol: model.paused ? "play.fill" : "pause.fill", size: 40) { model.perform(.togglePlay) }
                            CircleButton(symbol: "goforward.10", size: 30) { model.perform(.seek(10)) }
                        }
                        Spacer()
                        if model.duration > 0 {
                            HStack(spacing: 8) {
                                Text(Self.format(model.time)).monospacedDigit()
                                GeometryReader { g in
                                    ZStack(alignment: .leading) {
                                        Capsule().fill(.white.opacity(0.3))
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
                                Text("-" + Self.format(max(0, model.duration - model.time))).monospacedDigit()
                            }
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.white.opacity(0.9))
                        }
                    }
                }
                .padding(8)
                .transition(.opacity)
            }
            if model.stashed {
                HStack {
                    Image(systemName: "chevron.compact.left").font(.system(size: 18, weight: .bold)).foregroundStyle(.white.opacity(0.8))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.black.opacity(0.35))
                .allowsHitTesting(false)
            }
        }
        .animation(.easeOut(duration: 0.18), value: model.hovering)
        .animation(.spring(duration: 0.3), value: model.stashed)
    }

    static func format(_ t: Double) -> String {
        let s = Int(t.rounded(.down))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s % 3600 / 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }
}

struct CircleButton: View {
    let symbol: String
    var size: CGFloat = 24
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size * 0.45, weight: .bold))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: size, height: size)
                .background(.ultraThinMaterial, in: Circle())
                .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
    }
}
