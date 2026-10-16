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

/// A site on a page's grid: its icon on a tile, its name under it.
public struct SiteTile: View {
    let icon: NSImage?
    let title: String
    let help: String?
    let action: () -> Void
    @State private var hovering = false

    public static let size: CGFloat = 64
    /// Columns of tiles: fixed width, so names line up under their tiles.
    public static let columns = [GridItem(.adaptive(minimum: 76, maximum: 76), spacing: 12, alignment: .top)]

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
                Text(title).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).frame(width: 76)
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
