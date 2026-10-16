import AppKit
import SwiftUI

/// A section of a page the browser draws itself (the start page): a header over its content, left-aligned on the
/// page's column. Features contribute sections to `start-page.extras` with it, so they all read alike.
public struct PageSection<Content: View>: View {
    let title: String
    let content: Content

    public init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.system(size: 15, weight: .semibold))
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A site on a page's grid: its icon on a tile, its name under it (`name(for:)` names it the same way everywhere).
public struct SiteTile: View {
    let icon: NSImage?
    let title: String
    let help: String?
    let action: () -> Void
    @State private var hovering = false

    public static let size: CGFloat = 64
    /// Columns at the tile's width, so the first tile starts on the column's edge; names overhang their tile.
    public static let columns = [GridItem(.adaptive(minimum: size, maximum: size), spacing: 24, alignment: .top)]
    static let labelWidth: CGFloat = 80

    /// A site's name on a tile: the host without `www.`.
    public static func name(for url: URL?) -> String? {
        guard var host = url?.host() else { return nil }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        return host
    }

    public init(icon: NSImage?, title: String, help: String? = nil, action: @escaping () -> Void) {
        self.icon = icon
        self.title = title
        self.help = help
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Group {
                    if let icon {
                        SiteIcon(icon)
                    } else {
                        Text(String(title.prefix(1)).uppercased()).font(.system(size: 22, weight: .semibold)).foregroundStyle(.secondary)
                    }
                }
                .frame(width: 30, height: 30)
                .frame(width: Self.size, height: Self.size)
                .background(hovering ? Design.Fill.selection : Design.Fill.hover,
                            in: RoundedRectangle(cornerRadius: Design.Radius.tile, style: .continuous))
                Text(title).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                    .frame(width: Self.labelWidth)
                    .frame(width: Self.size)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(Design.Motion.hover) { hovering = h } }
        .help(help ?? title)
    }
}

/// A row of a page's list: an icon, a title, a trailing detail; a wash under the pointer.
public struct PageRow: View {
    let icon: NSImage?
    let title: String
    let detail: String?
    let action: () -> Void
    @State private var hovering = false

    public init(icon: NSImage?, title: String, detail: String? = nil, action: @escaping () -> Void) {
        self.icon = icon
        self.title = title
        self.detail = detail
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                SiteIcon(icon).frame(width: Design.Size.favicon, height: Design.Size.favicon)
                Text(title).font(.system(size: 13)).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 12)
                if let detail { Text(detail).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1) }
            }
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(hovering ? Design.Fill.hover : .clear, in: Design.itemShape)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(Design.Motion.hover) { hovering = h } }
    }
}

/// A card on a page: a symbol, a line (and an optional second), on the page's wash; a button when it has an action.
public struct PageCard: View {
    let symbol: String
    let title: String
    let detail: String?
    let action: (() -> Void)?
    @State private var hovering = false

    public init(symbol: String, title: String, detail: String? = nil, action: (() -> Void)? = nil) {
        self.symbol = symbol
        self.title = title
        self.detail = detail
        self.action = action
    }

    public var body: some View {
        let card = HStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: detail == nil ? 17 : 22)).foregroundStyle(.secondary).frame(width: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .semibold))
                if let detail { Text(detail).font(.system(size: 12)).foregroundStyle(.secondary) }
            }
            Spacer()
            if action != nil { Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(.tertiary) }
        }
        .padding(.horizontal, 14)
        .frame(height: detail == nil ? 44 : 60)
        .background(hovering ? Design.Fill.selection : Design.Fill.hover,
                    in: RoundedRectangle(cornerRadius: Design.Radius.tile, style: .continuous))
        .contentShape(Rectangle())
        if let action {
            Button(action: action) { card }
                .buttonStyle(.plain)
                .onHover { h in withAnimation(Design.Motion.hover) { hovering = h } }
        } else {
            card
        }
    }
}
