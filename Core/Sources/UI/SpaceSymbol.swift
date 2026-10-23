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
    /// Claude's spark plays its working animation until then.
    let activeUntil: Date?

    public init(_ kind: SpaceKind, activeUntil: Date? = nil) {
        self.kind = kind
        self.activeUntil = activeUntil
    }

    public var body: some View {
        switch kind {
        case .normal: Image(systemName: "person.fill").resizable().scaledToFit()
        // Template images, not shape fills: on Liquid Glass a shape's fill isn't rendered as vibrant as a symbol, so a
        // `.primary` incognito glyph came out grey beside a `.secondary` person.
        case .private: Image(nsImage: Self.incognito).resizable().scaledToFit()
        case .claude: AgentSpark(activeUntil: activeUntil)
        }
    }

    private static let incognito = template(IncognitoShape())
    static let spark: NSImage = {
        let svg = "<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 100 100'><path d='\(claudeSpark)'/></svg>"
        let image = NSImage(data: Data(svg.utf8)) ?? NSImage()
        image.isTemplate = true
        return image
    }()

    private static func template(_ shape: some Shape) -> NSImage {
        let side: CGFloat = 128  // sharp up to the 44 pt lock screen glyph at 2x
        let image = NSImage(size: NSSize(width: side, height: side), flipped: true) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.addPath(shape.path(in: rect).cgPath)
            context.setFillColor(NSColor.black.cgColor)
            context.fillPath(using: .evenOdd)
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

/// Claude's spark, as the Claude in Chrome extension draws it (a 100 × 100 view box).
private let claudeSpark = [
    "m19.6 66.5 19.7-11 .3-1-.3-.5h-1l-3.3-.2-11.2-.3L14 53l-9.5-.5-2.4-.5L0 49l.2-1.5 2-1.3 2.9.2 6.3.5 9.5.6 ",
    "6.9.4L38 49.1h1.6l.2-.7-.5-.4-.4-.4L29 41l-10.6-7-5.6-4.1-3-2-1.5-2-.6-4.2 2.7-3 3.7.3.9.2 3.7 2.9 8 6.1L37 ",
    "36l1.5 1.2.6-.4.1-.3-.7-1.1L33 25l-6-10.4-2.7-4.3-.7-2.6c-.3-1-.4-2-.4-3l3-4.2L28 0l4.2.6L33.8 2l2.6 6 4.1 ",
    "9.3L47 29.9l2 3.8 1 3.4.3 1h.7v-.5l.5-7.2 1-8.7 1-11.2.3-3.2 1.6-3.8 3-2L61 2.6l2 2.9-.3 1.8-1.1 7.7L59 ",
    "27.1l-1.5 8.2h.9l1-1.1 4.1-5.4 6.9-8.6 3-3.5L77 13l2.3-1.8h4.3l3.1 4.7-1.4 4.9-4.4 5.6-3.7 4.7-5.3 7.1-3.2 ",
    "5.7.3.4h.7l12-2.6 6.4-1.1 7.6-1.3 3.5 1.6.4 1.6-1.4 3.4-8.2 2-9.6 2-14.3 3.3-.2.1.2.3 6.4.6 2.8.2h6.8l12.6 1 ",
    "3.3 2 1.9 2.7-.3 2-5.1 2.6-6.8-1.6-16-3.8-5.4-1.3h-.8v.4l4.6 4.5 8.3 7.5L89 80.1l.5 2.4-1.3 ",
    "2-1.4-.2-9.2-7-3.6-3-8-6.8h-.5v.7l1.8 2.7 9.8 14.7.5 4.5-.7 1.4-2.6 1-2.7-.6-5.8-8-6-9-4.7-8.2-.5.4-2.9 ",
    "30.2-1.3 1.5-3 1.2-2.5-2-1.4-3 1.4-6.2 1.6-8 1.3-6.4 1.2-7.9.7-2.6v-.2H49L43 72l-9 12.3-7.2 ",
    "7.6-1.7.7-3-1.5.3-2.8L24 86l10-12.8 6-7.9 4-4.6-.1-.5h-.3L17.2 77.4l-4.7.6-2-2 .2-3 1-1 8-5.5Z",
].joined()
