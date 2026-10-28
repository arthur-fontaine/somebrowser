import AppKit
import SwiftUI

/// The inner grid of a page's field, cards and rows: an icon column 20 wide centered 24 pt in, text 48 pt in.
public enum PageGrid {
    public static let iconWidth: CGFloat = 20
    public static let leading: CGFloat = 24 - iconWidth / 2
    public static let iconToText: CGFloat = 48 - leading - iconWidth
}

/// A section of a page the browser draws itself (the start page): a header over its content, left-aligned on the
/// page's column. Features contribute sections to `start-page.extras` with it, so they all read alike.
public struct PageSection<Content: View, Accessory: View>: View {
    @Environment(\.pageSectionMover) private var mover
    let title: String
    let content: Content
    let accessory: Accessory

    /// `accessory` sits at the header's end: a "Show All" link (`PageSectionLink`).
    public init(_ title: String, @ViewBuilder content: () -> Content, @ViewBuilder accessory: () -> Accessory) {
        self.title = title
        self.content = content()
        self.accessory = accessory()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Design.Space.block) {
            HStack(spacing: Design.Space.block) {
                Text(title).font(.system(size: 15, weight: .semibold))
                    .modifier(MovableHeader(mover: mover))
                Spacer(minLength: 0)
                accessory
            }
            .frame(height: 20)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// How the page moves a section, given to its contributions through the environment: the header's menu moves it
/// past its neighbour, and the header drags (the page drops it where the pointer is).
public struct PageSectionMover {
    public let id: String
    public let moveUp: (() -> Void)?
    public let moveDown: (() -> Void)?
    public let dragBegan: () -> Void

    public init(id: String, moveUp: (() -> Void)?, moveDown: (() -> Void)?, dragBegan: @escaping () -> Void) {
        self.id = id
        self.moveUp = moveUp
        self.moveDown = moveDown
        self.dragBegan = dragBegan
    }
}

public extension EnvironmentValues {
    /// Set by a page whose sections can be rearranged (the start page).
    @Entry var pageSectionMover: PageSectionMover? = nil
}

private struct MovableHeader: ViewModifier {
    let mover: PageSectionMover?

    func body(content: Content) -> some View {
        if let mover {
            content
                .contentShape(Rectangle())
                .onDrag {
                    mover.dragBegan()
                    return NSItemProvider(object: mover.id as NSString)
                }
                .contextMenu {
                    Button("Move Up") { mover.moveUp?() }.disabled(mover.moveUp == nil)
                    Button("Move Down") { mover.moveDown?() }.disabled(mover.moveDown == nil)
                }
                .help("Drag to move this section")
        } else {
            content
        }
    }
}

public extension PageSection where Accessory == EmptyView {
    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.init(title, content: content, accessory: { EmptyView() })
    }
}

/// A section header's link ("Show All"): quiet text that darkens under the pointer.
public struct PageSectionLink: View {
    let title: String
    let action: () -> Void
    @State private var hovering = false

    public init(_ title: String, action: @escaping () -> Void) {
        self.title = title
        self.action = action
    }

    public var body: some View {
        Button(action: action) { Text(title).font(.system(size: 13)) }
            .buttonStyle(.plain)
            .foregroundStyle(hovering ? .primary : .secondary)
            .onHover { h in withAnimation(Design.Motion.hover) { hovering = h } }
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
    static let labelWidth = size + Design.Space.tileGutter

    /// A site's name on a tile: its domain without subdomains (apple.com for developer.apple.com, bbc.co.uk). For
    /// display only: a country's second level (co, com, org…) is kept, without the full public suffix list.
    public static func name(for url: URL?) -> String? {
        guard let host = url?.host()?.lowercased(), !host.isEmpty else { return nil }
        let labels = host.split(separator: ".")
        guard labels.count > 2, !labels.allSatisfy({ $0.allSatisfy(\.isNumber) }) else { return host }
        let secondLevel: Set<Substring> = ["co", "com", "org", "net", "gov", "ac", "edu", "ne", "or", "go"]
        let keep = labels.last!.count == 2 && secondLevel.contains(labels[labels.count - 2]) ? 3 : 2
        return labels.suffix(keep).joined(separator: ".")
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
            HStack(spacing: PageGrid.iconToText) {
                SiteIcon(icon).frame(width: Design.Size.favicon, height: Design.Size.favicon).frame(width: PageGrid.iconWidth)
                Text(title).font(.system(size: 13)).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 12)
                if let detail { Text(detail).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1) }
            }
            .padding(.leading, PageGrid.leading)
            .padding(.trailing, Design.Space.capsuleTrailing)
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
        let card = HStack(spacing: PageGrid.iconToText) {
            Image(systemName: symbol).font(.system(size: 17)).foregroundStyle(.secondary).frame(width: PageGrid.iconWidth)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .semibold))
                if let detail { Text(detail).font(.system(size: 12)).foregroundStyle(.secondary) }
            }
            Spacer()
            if action != nil { Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(.tertiary) }
        }
        .padding(.leading, PageGrid.leading)
        .padding(.trailing, Design.Space.capsuleTrailing)
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
