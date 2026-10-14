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
    private(set) var resting: PiPPhysics.Resting = .corner(.bottomRight)

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
            // Engine-owned page window (CEF): it follows the panel and sits under the controls.
            w.level = .floating
            w.collectionBehavior = collectionBehavior
            w.setFrame(frame, display: true)
            addChildWindow(w, ordered: .below)
            w.orderFront(nil)
        }
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    var screenFrame: CGRect { (screen ?? NSScreen.main)?.visibleFrame ?? .zero }

    func setAspect(_ ratio: CGFloat) {
        guard ratio.isFinite, ratio > 0.3, ratio < 4 else { return }
        aspect = ratio
        targetSize = CGSize(width: targetSize.width, height: (targetSize.width / ratio).rounded())
        settle(PiPPhysics.frame(for: resting, size: targetSize, in: screenFrame))
    }

    /// Grows out of the browser window into the bottom-right corner (Radian).
    func present(from start: CGRect?) {
        let target = PiPPhysics.frame(for: .corner(.bottomRight), size: targetSize, in: screenFrame)
        if let start {
            setFrame(start.insetBy(dx: start.width * 0.08, dy: start.height * 0.08), display: false)
            alphaValue = 0.85
        } else {
            setFrame(target.offsetBy(dx: 0, dy: -40), display: false)
            alphaValue = 0
        }
        orderFrontRegardless()
        if case .window(let w) = content { w.setFrame(frame, display: false); w.orderFront(nil) }
        NSAnimationContext.animate(.spring(duration: 0.55, bounce: 0.18)) {
            animator().setFrame(target, display: true)
            animator().alphaValue = 1
            if case .window(let w) = content { w.animator().setFrame(target, display: true) }
        }
    }

    func dismiss() {
        NSAnimationContext.animate(.easeIn(duration: 0.18)) {
            animator().alphaValue = 0
        } completion: { [weak self] in
            guard let self else { return }
            if case .window(let w) = self.content { self.removeChildWindow(w); w.orderOut(nil) }
            self.orderOut(nil)
        }
    }

    func settle(_ target: CGRect) {
        NSAnimationContext.animate(.spring(duration: 0.45, bounce: 0.22)) {
            animator().setFrame(target, display: true)
            if case .window(let w) = content { w.animator().setFrame(target, display: true) }
        }
    }

    func moveBy(_ dx: CGFloat, _ dy: CGFloat) {
        let o = frame.origin
        setFrameOrigin(CGPoint(x: o.x + dx, y: o.y + dy))
        if case .window(let w) = content { w.setFrameOrigin(frame.origin) }
        if model.stashed { model.stashed = false }
    }

    /// Release with a velocity (points/second): fling to a corner or tuck into an edge.
    func release(velocity: CGVector) {
        resting = PiPPhysics.rest(frame: frame, velocity: velocity, in: screenFrame)
        if case .stashed = resting { model.stashed = true } else { model.stashed = false }
        settle(PiPPhysics.frame(for: resting, size: targetSize, in: screenFrame))
    }

    func unstash() {
        guard case .stashed(let left, let y) = resting else { return }
        let top = y + frame.height / 2 > screenFrame.midY
        resting = .corner(left ? (top ? .topLeft : .bottomLeft) : (top ? .topRight : .bottomRight))
        model.stashed = false
        settle(PiPPhysics.frame(for: resting, size: targetSize, in: screenFrame))
    }

    func magnify(by amount: CGFloat) {
        let size = PiPPhysics.resized(frame.size, by: amount, aspect: aspect)
        targetSize = size
        let center = CGPoint(x: frame.midX, y: frame.midY)
        let f = CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2, width: size.width, height: size.height)
        setFrame(f, display: true)
        if case .window(let w) = content { w.setFrame(f, display: true) }
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
        panel?.release(velocity: velocity())
    }

    // Two-finger trackpad moves without clicking (Radian: "controllable with trackpad").
    override func scrollWheel(with event: NSEvent) {
        guard event.hasPreciseScrollingDeltas else { return }
        if !event.momentumPhase.isEmpty { return }  // our spring replaces system momentum
        if event.phase == .began { samples = [] }
        let d = CGVector(dx: event.scrollingDeltaX, dy: -event.scrollingDeltaY)
        if event.phase == .changed || event.phase == .began {
            record(d, at: event.timestamp)
            panel?.moveBy(d.dx, d.dy)
        } else if event.phase == .ended || event.phase == .cancelled {
            panel?.release(velocity: velocity())
        }
    }

    override func magnify(with event: NSEvent) { panel?.magnify(by: event.magnification) }

    private func record(_ d: CGVector, at t: TimeInterval) {
        samples.append((t, d))
        if samples.count > 8 { samples.removeFirst() }
    }

    private func velocity() -> CGVector {
        guard let first = samples.first, let last = samples.last, last.t > first.t else { return .zero }
        let dt = last.t - first.t
        let sum = samples.dropFirst().reduce(CGVector.zero) { CGVector(dx: $0.dx + $1.d.dx, dy: $0.dy + $1.d.dy) }
        return CGVector(dx: sum.dx / dt, dy: sum.dy / dt)
    }
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
