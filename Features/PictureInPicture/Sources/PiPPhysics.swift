import CoreGraphics
import Foundation

/// Fling, snap and stash math for the floating panel (pure, unit-tested).
/// Coordinates are AppKit screen coordinates (origin bottom-left).
enum PiPPhysics {
    /// Deceleration rate per millisecond (UIScrollView "normal").
    static let deceleration: CGFloat = 0.998
    static let margin: CGFloat = 16
    /// Width left visible when the panel is tucked into a screen edge.
    static let stashVisible: CGFloat = 28

    enum Corner: CaseIterable { case topLeft, topRight, bottomLeft, bottomRight }

    enum Resting: Equatable {
        case corner(Corner)
        case stashed(left: Bool, y: CGFloat)
    }

    /// Where a throw would end: p + v·d/(1−d) (WWDC 2018 "Designing Fluid Interfaces"), v in points/second.
    static func projection(of position: CGPoint, velocity: CGVector) -> CGPoint {
        let factor = deceleration / (1 - deceleration) / 1000
        return CGPoint(x: position.x + velocity.dx * factor, y: position.y + velocity.dy * factor)
    }

    /// Panel origin for a corner of `screen`.
    static func origin(for corner: Corner, size: CGSize, in screen: CGRect) -> CGPoint {
        let left = screen.minX + margin, right = screen.maxX - size.width - margin
        let bottom = screen.minY + margin, top = screen.maxY - size.height - margin
        switch corner {
        case .topLeft: return CGPoint(x: left, y: top)
        case .topRight: return CGPoint(x: right, y: top)
        case .bottomLeft: return CGPoint(x: left, y: bottom)
        case .bottomRight: return CGPoint(x: right, y: bottom)
        }
    }

    /// Decides the resting place for a panel released at `frame` with `velocity`.
    /// Thrown past a side edge → stashed there; otherwise the corner nearest to the projected center.
    static func rest(frame: CGRect, velocity: CGVector, in screen: CGRect) -> Resting {
        let center = CGPoint(x: frame.midX, y: frame.midY)
        let projected = projection(of: center, velocity: velocity)
        if projected.x < screen.minX || projected.x > screen.maxX {
            let y = min(max(projected.y - frame.height / 2, screen.minY + margin), screen.maxY - frame.height - margin)
            return .stashed(left: projected.x < screen.minX, y: y)
        }
        let corner = Corner.allCases.min { a, b in
            distance(projected, centerOf(a, size: frame.size, in: screen)) < distance(projected, centerOf(b, size: frame.size, in: screen))
        }!
        return .corner(corner)
    }

    static func frame(for resting: Resting, size: CGSize, in screen: CGRect) -> CGRect {
        switch resting {
        case .corner(let c):
            return CGRect(origin: origin(for: c, size: size, in: screen), size: size)
        case .stashed(let left, let y):
            let x = left ? screen.minX - size.width + stashVisible : screen.maxX - stashVisible
            return CGRect(x: x, y: y, width: size.width, height: size.height)
        }
    }

    /// Keeps a size within limits and the video's aspect ratio (pinch to resize).
    /// How far the fingers moved on the trackpad (screen points, y up), from a scroll event: the panel follows them
    /// whatever the scroll direction setting ("natural" scrolling inverts the deltas).
    static func fingerMove(scrollX: CGFloat, scrollY: CGFloat, natural: Bool) -> CGVector {
        let sign: CGFloat = natural ? 1 : -1
        return CGVector(dx: sign * scrollX, dy: -sign * scrollY)
    }

    static func resized(_ size: CGSize, by magnification: CGFloat, aspect: CGFloat, limits: ClosedRange<CGFloat> = 240...960) -> CGSize {
        let width = min(max(size.width * (1 + magnification), limits.lowerBound), limits.upperBound)
        return CGSize(width: width.rounded(), height: (width / max(aspect, 0.2)).rounded())
    }

    private static func centerOf(_ c: Corner, size: CGSize, in screen: CGRect) -> CGPoint {
        let o = origin(for: c, size: size, in: screen)
        return CGPoint(x: o.x + size.width / 2, y: o.y + size.height / 2)
    }

    private static func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(a.x - b.x, a.y - b.y) }
}
