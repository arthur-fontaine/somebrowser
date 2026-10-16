import AppKit
import SwiftUI

public extension SpaceKind {
    var title: String {
        switch self {
        case .normal: "Your Tabs"
        case .private: "Private"
        case .claude: "Claude"
        }
    }
}

/// A space's symbol, drawn in the current foreground style like an SF Symbol: a person for the user's own tabs, an
/// incognito hat and glasses for the private space, Claude's spark for the tabs Claude controls.
public struct SpaceSymbol: View {
    let kind: SpaceKind

    public init(_ kind: SpaceKind) { self.kind = kind }

    public var body: some View {
        switch kind {
        case .normal: Image(systemName: "person.fill").resizable().scaledToFit()
        // Template images, not shape fills: on Liquid Glass a shape's fill isn't rendered as vibrant as a symbol, so a
        // `.primary` incognito glyph came out grey beside a `.secondary` person.
        case .private: Image(nsImage: Self.incognito).resizable().scaledToFit()
        case .claude: Image(nsImage: Self.spark).resizable().scaledToFit()
        }
    }

    private static let incognito = template(IncognitoShape(), evenOdd: true)
    private static let spark = template(ClaudeSpark(), evenOdd: false)

    private static func template(_ shape: some Shape, evenOdd: Bool) -> NSImage {
        let side: CGFloat = 128  // sharp up to the 44 pt lock screen glyph at 2x
        let image = NSImage(size: NSSize(width: side, height: side), flipped: true) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.addPath(shape.path(in: rect).cgPath)
            context.setFillColor(NSColor.black.cgColor)
            context.fillPath(using: evenOdd ? .evenOdd : .winding)
            return true
        }
        image.isTemplate = true
        return image
    }
}

/// A brimmed hat over round dark glasses.
nonisolated struct IncognitoShape: Shape {
    func path(in r: CGRect) -> Path {
        let s = min(r.width, r.height)
        let o = CGPoint(x: r.midX - s / 2, y: r.midY - s / 2)
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: o.x + x * s, y: o.y + y * s) }
        var path = Path()
        // Crown, then brim.
        path.move(to: p(0.27, 0.42))
        path.addLine(to: p(0.34, 0.14))
        path.addQuadCurve(to: p(0.5, 0.17), control: p(0.42, 0.10))
        path.addQuadCurve(to: p(0.66, 0.14), control: p(0.58, 0.10))
        path.addLine(to: p(0.73, 0.42))
        path.closeSubpath()
        path.addRoundedRect(in: CGRect(origin: p(0.06, 0.42), size: CGSize(width: 0.88 * s, height: 0.09 * s)),
                            cornerSize: CGSize(width: 0.045 * s, height: 0.045 * s))
        // Glasses: two dark lenses (solid, so the glyph weighs what the person beside it does) and the bridge.
        for x in [0.30, 0.70] {
            path.addEllipse(in: CGRect(x: o.x + (x - 0.17) * s, y: o.y + 0.60 * s, width: 0.34 * s, height: 0.34 * s))
        }
        path.addRect(CGRect(origin: p(0.47, 0.72), size: CGSize(width: 0.06 * s, height: 0.06 * s)))
        return path
    }
}

/// Claude's spark: rays of uneven length around a small center.
nonisolated struct ClaudeSpark: Shape {
    func path(in r: CGRect) -> Path {
        let s = min(r.width, r.height)
        let c = CGPoint(x: r.midX, y: r.midY)
        let lengths: [CGFloat] = [0.50, 0.40, 0.47, 0.36, 0.50, 0.42, 0.46, 0.37, 0.49, 0.40, 0.45, 0.38]
        var path = Path()
        for (i, length) in lengths.enumerated() {
            let angle = CGFloat(i) / CGFloat(lengths.count) * 2 * .pi - .pi / 2
            let width = 0.085 * s
            let ray = Path(roundedRect: CGRect(x: -width / 2, y: 0.06 * s, width: width, height: (length - 0.06) * s),
                           cornerRadius: width / 2)
            path.addPath(ray, transform: CGAffineTransform(translationX: c.x, y: c.y).rotated(by: angle - .pi / 2))
        }
        path.addEllipse(in: CGRect(x: c.x - 0.11 * s, y: c.y - 0.11 * s, width: 0.22 * s, height: 0.22 * s))
        return path
    }
}
