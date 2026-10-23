import CoreGraphics
import Foundation

/// Throw, glide and tuck math for the floating panel (pure, unit-tested).
/// Coordinates are AppKit screen coordinates (origin bottom-left).
enum PiPPhysics {
    /// Deceleration rate per millisecond (UIScrollView "normal").
    static let deceleration: CGFloat = 0.998
    static let margin: CGFloat = 16
    /// Width left visible when the panel is tucked into a screen edge.
    static let stashVisible: CGFloat = 28

    /// Where the panel rests: placed anywhere on screen, or tucked into a side edge, a strip still showing.
    enum Resting: Equatable {
        case placed(CGPoint)  // origin
        case stashed(left: Bool, y: CGFloat)
    }

    /// Where a throw would end: p + v·d/(1−d) (WWDC 2018 "Designing Fluid Interfaces"), v in points/second.
    static func projection(of position: CGPoint, velocity: CGVector) -> CGPoint {
        let factor = deceleration / (1 - deceleration) / 1000
        return CGPoint(x: position.x + velocity.dx * factor, y: position.y + velocity.dy * factor)
    }

    /// Where a new panel appears: the screen's bottom-right corner.
    static func cornerOrigin(size: CGSize, in screen: CGRect) -> CGPoint {
        CGPoint(x: screen.maxX - size.width - margin, y: screen.minY + margin)
    }

    /// Where a panel released at `frame` with `velocity` comes to rest. Its center past a side edge once the throw
    /// ends: tucked into it. Otherwise where the throw ends, on screen; fingers that had stopped leave it where it is.
    static func rest(frame: CGRect, velocity: CGVector, in screen: CGRect) -> Resting {
        let projected = projection(of: CGPoint(x: frame.midX, y: frame.midY), velocity: velocity)
        if projected.x < screen.minX || projected.x > screen.maxX {
            let y = min(max(projected.y - frame.height / 2, screen.minY + margin), screen.maxY - frame.height - margin)
            return .stashed(left: projected.x < screen.minX, y: y)
        }
        return .placed(CGPoint(x: projected.x - frame.width / 2, y: projected.y - frame.height / 2))
    }

    static func frame(for resting: Resting, size: CGSize, in screen: CGRect) -> CGRect {
        switch resting {
        case .placed(let origin):
            let x = min(max(origin.x, screen.minX), screen.maxX - size.width)
            let y = min(max(origin.y, screen.minY), screen.maxY - size.height)
            return CGRect(x: x, y: y, width: size.width, height: size.height)
        case .stashed(let left, let y):
            let x = left ? screen.minX - size.width + stashVisible : screen.maxX - stashVisible
            return CGRect(x: x, y: y, width: size.width, height: size.height)
        }
    }

    /// The panel is never further off screen than tucked in: a strip stays on screen sideways, all of it vertically.
    /// Moves stop there, and so does a spring's overshoot.
    static func neverLost(_ frame: CGRect, in screen: CGRect) -> CGRect {
        var f = frame
        f.origin.x = min(max(f.minX, screen.minX - f.width + stashVisible), screen.maxX - stashVisible)
        f.origin.y = min(max(f.minY, screen.minY), screen.maxY - f.height)
        return f
    }

    /// Scroll points to screen points: two fingers carry the panel a little further than they travel (1 felt slow, 2
    /// too fast).
    static let trackpadGain: CGFloat = 1.5

    /// How far the fingers moved on the trackpad (screen points, y up), from a scroll event: the panel follows them
    /// whatever the scroll direction setting ("natural" scrolling inverts the deltas).
    static func fingerMove(scrollX: CGFloat, scrollY: CGFloat, natural: Bool) -> CGVector {
        let sign: CGFloat = (natural ? 1 : -1) * trackpadGain
        return CGVector(dx: sign * scrollX, dy: -sign * scrollY)
    }

    /// Points per second over the moves of the last 100 ms before `time` (older ones: the fingers had stopped).
    static func velocity(of moves: [(t: TimeInterval, d: CGVector)], at time: TimeInterval) -> CGVector {
        let recent = moves.filter { $0.t >= time - 0.1 }
        guard let first = recent.first, let last = recent.last, last.t > first.t else { return .zero }
        let sum = recent.dropFirst().reduce(CGVector.zero) { CGVector(dx: $0.dx + $1.d.dx, dy: $0.dy + $1.d.dy) }
        let dt = last.t - first.t
        return CGVector(dx: sum.dx / dt, dy: sum.dy / dt)
    }

    /// The panel going to `target` on a spring that starts at the release's velocity (points/second): a throw carries
    /// on into its corner instead of stopping and starting again.
    struct FrameSpring {
        static let response: CGFloat = 0.45  // seconds per oscillation
        static let dampingRatio: CGFloat = 0.8  // a little overshoot

        private(set) var frame: CGRect
        private(set) var velocity: CGVector
        private var sizeVelocity = CGVector.zero
        let target: CGRect

        init(from frame: CGRect, velocity: CGVector, to target: CGRect) {
            self.frame = frame
            self.velocity = velocity
            self.target = target
        }

        /// The same motion aimed elsewhere: where it is, as fast as it goes (no stop and start).
        func aimed(at target: CGRect) -> FrameSpring {
            var spring = FrameSpring(from: frame, velocity: velocity, to: target)
            spring.sizeVelocity = sizeVelocity
            return spring
        }

        mutating func advance(by dt: TimeInterval) {
            let k = pow(2 * .pi / Self.response, 2), c = 4 * .pi * Self.dampingRatio / Self.response
            var remaining = CGFloat(min(dt, 1.0 / 15))  // a stalled frame doesn't jump
            while remaining > 0 {
                let h = min(remaining, 1.0 / 480)
                func step(_ x: inout CGFloat, _ v: inout CGFloat, _ to: CGFloat) {
                    v += (-k * (x - to) - c * v) * h
                    x += v * h
                }
                step(&frame.origin.x, &velocity.dx, target.origin.x)
                step(&frame.origin.y, &velocity.dy, target.origin.y)
                step(&frame.size.width, &sizeVelocity.dx, target.width)
                step(&frame.size.height, &sizeVelocity.dy, target.height)
                remaining -= h
            }
        }

        var isSettled: Bool {
            abs(frame.minX - target.minX) < 0.5 && abs(frame.minY - target.minY) < 0.5 && abs(frame.width - target.width) < 0.5
                && abs(frame.height - target.height) < 0.5 && hypot(velocity.dx, velocity.dy) < 10
                && hypot(sizeVelocity.dx, sizeVelocity.dy) < 10
        }
    }

    static let widths: ClosedRange<CGFloat> = 240...960

    /// Keeps a size within limits and the video's aspect ratio (pinch to resize).
    static func resized(_ size: CGSize, by magnification: CGFloat, aspect: CGFloat, limits: ClosedRange<CGFloat> = widths) -> CGSize {
        let width = min(max(size.width * (1 + magnification), limits.lowerBound), limits.upperBound)
        return CGSize(width: width.rounded(), height: (width / max(aspect, 0.2)).rounded())
    }

    /// `frame` at `size`, the screen point `anchor` keeping its place in it.
    static func scaled(_ frame: CGRect, to size: CGSize, around anchor: CGPoint) -> CGRect {
        guard frame.width > 0, frame.height > 0 else { return CGRect(origin: frame.origin, size: size) }
        let fx = min(max((anchor.x - frame.minX) / frame.width, 0), 1)
        let fy = min(max((anchor.y - frame.minY) / frame.height, 0), 1)
        return CGRect(x: (anchor.x - fx * size.width).rounded(), y: (anchor.y - fy * size.height).rounded(), width: size.width, height: size.height)
    }

    struct Edges: OptionSet, Hashable {
        let rawValue: Int
        static let left = Edges(rawValue: 1), right = Edges(rawValue: 2), top = Edges(rawValue: 4), bottom = Edges(rawValue: 8)
    }

    /// The edges a point of the panel (its bounds, y up) grabs: a thin band along each side, a corner near its ends.
    static func edges(at p: CGPoint, in bounds: CGRect, band: CGFloat = 6, corner: CGFloat = 20) -> Edges {
        var e: Edges = []
        let left = p.x - bounds.minX, right = bounds.maxX - p.x, bottom = p.y - bounds.minY, top = bounds.maxY - p.y
        if left < band || (left < corner && min(top, bottom) < band) { e.insert(.left) }
        if right < band || (right < corner && min(top, bottom) < band) { e.insert(.right) }
        if bottom < band || (bottom < corner && min(left, right) < band) { e.insert(.bottom) }
        if top < band || (top < corner && min(left, right) < band) { e.insert(.top) }
        return e
    }

    /// Dragging `edges` of `start` by `offset`: the video's shape kept, the opposite side (or corner) held, a lone side's
    /// middle staying put across it.
    static func resized(_ start: CGRect, edges: Edges, by offset: CGVector, aspect: CGFloat, limits: ClosedRange<CGFloat> = widths) -> CGRect {
        let aspect = max(aspect, 0.2)
        var proposals: [CGFloat] = []
        if edges.contains(.right) { proposals.append(start.width + offset.dx) }
        if edges.contains(.left) { proposals.append(start.width - offset.dx) }
        if edges.contains(.top) { proposals.append((start.height + offset.dy) * aspect) }
        if edges.contains(.bottom) { proposals.append((start.height - offset.dy) * aspect) }
        guard let proposed = proposals.max() else { return start }
        let width = min(max(proposed, limits.lowerBound), limits.upperBound).rounded()
        let height = (width / aspect).rounded()
        let x = edges.contains(.left) ? start.maxX - width : edges.contains(.right) ? start.minX : start.midX - width / 2
        let y = edges.contains(.bottom) ? start.maxY - height : edges.contains(.top) ? start.minY : start.midY - height / 2
        return CGRect(x: x.rounded(), y: y.rounded(), width: width, height: height)
    }
}
