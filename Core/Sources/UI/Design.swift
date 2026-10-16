import AppKit
import SwiftUI

/// The chrome's shared geometry, fills and motion. Features never import each other, so this is how their pieces line up:
/// one radius per kind of shape, one leading grid, one set of springs.
///
/// - Controls (header buttons, the address field, footer buttons, toasts) are capsules `Size.control` tall.
/// - Everything list-like (rows, tiles, the selection lens, hover and drop targets) is `Radius.item`.
/// - A container's inner shapes are concentric with it: `concentric(outer, inset:)`.
public enum Design {
    /// The page card (and the floating sidebar) sit this far inside the window's edges.
    public static let windowInset: CGFloat = 6
    /// A window's corner on macOS 26 and 27, measured (a titled window without a toolbar).
    public static let windowRadius: CGFloat = 16
    /// The page card: concentric with the window it sits in.
    public static let cardRadius = concentric(windowRadius, inset: windowInset)

    /// The radius of a shape `inset` inside one of radius `outer`, so the two curves stay parallel.
    public static func concentric(_ outer: CGFloat, inset: CGFloat, minimum: CGFloat = Radius.item) -> CGFloat {
        max(minimum, outer - inset)
    }

    /// Every list item's shape: rows, tiles, the selection lens, hover and drop targets.
    public static let itemShape = RoundedRectangle(cornerRadius: Radius.item, style: .continuous)

    public enum Radius {
        /// Rows, tiles, the selection lens, hover and drop targets.
        public static let item: CGFloat = 10
        /// A site's tile on a page (the start page's grids), roomier than a row.
        public static let tile: CGFloat = 12
        /// Floating panels (downloads, site controls, permissions, dialogs).
        public static let panel: CGFloat = 20
        public static let favicon: CGFloat = 4
    }

    public enum Size {
        /// A chrome control's height: header buttons, the address field, footer buttons, toasts.
        public static let control: CGFloat = 36
        /// The sidebar's top row, where the traffic lights sit (the system's toolbar height).
        public static let header: CGFloat = 52
        public static let tile: CGFloat = 40
        public static let favicon: CGFloat = 16
    }

    /// The sidebar's leading grid: shapes start at `edge`; icons are centered on the red traffic light's x (26, where the
    /// system puts it in a window with a toolbar), so lights, favicons and the address field's symbol make one column;
    /// text starts at `textColumn`.
    public enum Grid {
        public static let edge: CGFloat = 8
        /// Inside a shape that starts at `edge`: where its icon starts.
        public static let iconInset: CGFloat = 10
        public static let iconToText: CGFloat = 8
        public static let iconCenter: CGFloat = edge + iconInset + Size.favicon / 2
        public static let textColumn: CGFloat = edge + iconInset + Size.favicon + iconToText
    }

    /// Neutral washes, never the accent color (Spotlight's selection is the same).
    public enum Fill {
        public static let hover = adaptive(light: .black.withAlphaComponent(0.05), dark: .white.withAlphaComponent(0.06))
        public static let selection = adaptive(light: .black.withAlphaComponent(0.09), dark: .white.withAlphaComponent(0.10))
        /// A favorite tile at rest.
        public static let tile = adaptive(light: .white.withAlphaComponent(0.35), dark: .white.withAlphaComponent(0.08))
        /// A control drawn on glass (where it can't be glass itself).
        public static let onGlass = adaptive(light: .black.withAlphaComponent(0.06), dark: .white.withAlphaComponent(0.08))
        public static let hairline = Color.primary.opacity(0.1)
        /// Under the text of a large glass panel, so it reads over any page (Spotlight's).
        public static let glassScrim = adaptive(light: .white.withAlphaComponent(0.10), dark: .black.withAlphaComponent(0.12))

        static func adaptive(light: NSColor, dark: NSColor) -> Color {
            Color(nsColor: NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light })
        }
    }

    public enum Motion {
        /// Layout changes: the sidebar arriving or leaving, sections opening.
        public static let layout = Animation.smooth(duration: 0.30)
        /// The selection lens, chips, segmented controls.
        public static let selection = Animation.snappy(duration: 0.28)
        /// Paging between spaces.
        public static let space = Animation.smooth(duration: 0.32)
        public static let hover = Animation.easeOut(duration: 0.12)
        public static let toast = Animation.spring(duration: 0.35, bounce: 0.12)
        /// A panel arriving (Spotlight): it fades in over 0.14 s while settling from 96% on a critically damped spring.
        public static let panelFade = Animation.linear(duration: 0.14)
        public static let panelSettle = Animation.spring(response: 0.30, dampingFraction: 1)
        public static let panelEnterScale: CGFloat = 0.96
        /// …and leaves with a 0.12 s fade, shrinking slightly.
        public static let panelExit = Animation.easeOut(duration: 0.12)
        public static let panelExitScale: CGFloat = 0.98
        /// Under Reduce Motion, everything is a short fade.
        public static let reduced = Animation.easeOut(duration: 0.15)
    }
}

public extension EnvironmentValues {
    /// Inside a glass surface (the floating sidebar): controls there are fills, never glass on glass.
    @Entry var isOnGlass = false
}
