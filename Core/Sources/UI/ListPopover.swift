import AppKit
import SwiftUI

/// A row of a `SearchPanel`: a site's icon, a title over a subtitle, a trailing detail (a time).
public struct PanelItem: Identifiable {
    public let id: String
    public var icon: NSImage?
    public var title: String
    public var subtitle: String?
    public var detail: String?
    /// Offered as Copy Link.
    public var url: URL?
    public var open: () -> Void
    /// Shown as a × under the pointer, and in the row's menu.
    public var remove: (title: String, action: () -> Void)?

    public init(id: String, icon: NSImage?, title: String, subtitle: String? = nil, detail: String? = nil, url: URL? = nil,
                open: @escaping () -> Void, remove: (title: String, action: () -> Void)? = nil) {
        self.id = id
        self.icon = icon
        self.title = title
        self.subtitle = subtitle
        self.detail = detail
        self.url = url
        self.open = open
        self.remove = remove
    }
}

/// Rows under a header.
public struct PanelSection: Identifiable {
    public let title: String
    public var items: [PanelItem]
    public var id: String { title }

    public init(title: String, items: [PanelItem]) {
        self.title = title
        self.items = items
    }

    /// Newest first, under Today, Yesterday, then the day's date.
    public static func byDay<T>(_ values: [T], date: (T) -> Date, now: Date = Date(), item: (T) -> PanelItem) -> [PanelSection] {
        let calendar = Calendar.current
        var sections: [PanelSection] = []
        for value in values.sorted(by: { date($0) > date($1) }) {
            let title = dayTitle(date(value), now: now, calendar: calendar)
            if sections.last?.title == title {
                sections[sections.count - 1].items.append(item(value))
            } else {
                sections.append(PanelSection(title: title, items: [item(value)]))
            }
        }
        return sections
    }

    static func dayTitle(_ date: Date, now: Date, calendar: Calendar) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return "Today" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) { return "Yesterday" }
        let day = Date.FormatStyle.dateTime.weekday(.wide).day().month(.wide)
        return date.formatted(calendar.isDate(date, equalTo: now, toGranularity: .year) ? day : day.year())
    }
}

/// What a `SearchPanel` shows with nothing to list.
public struct PanelEmptyState {
    let symbol: String
    let title: String
    let detail: String?

    public init(symbol: String, title: String, detail: String? = nil) {
        self.symbol = symbol
        self.title = title
        self.detail = detail
    }
}

/// A list that pops up from the sidebar's footer (History, the archive), as the extensions panel does from the address
/// field: a compact glass panel above the button that opened it, its title, a search field and the rows by section.
/// The arrows move through the rows (as does the pointer), Return opens one, ⌘⌫ removes it, Esc clears the search and
/// then closes.
public struct ListPopover<Menu: View>: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let id: String
    let window: BrowserWindowState
    let isShown: Bool
    let title: String
    @Binding var query: String
    let sections: [PanelSection]
    let empty: PanelEmptyState
    let close: () -> Void
    let menu: Menu

    public init(_ id: String, in window: BrowserWindowState, isShown: Bool, title: String, query: Binding<String>,
                sections: [PanelSection], empty: PanelEmptyState, close: @escaping () -> Void,
                /// The title's ⋯ menu (clearing everything): buttons.
                @ViewBuilder menu: () -> Menu = { EmptyView() }) {
        self.id = id
        self.window = window
        self.isShown = isShown
        self.title = title
        _query = query
        self.sections = sections
        self.empty = empty
        self.close = close
        self.menu = menu()
    }

    public var body: some View {
        GeometryReader { proxy in
            // Above the footer's buttons, on the sidebar's leading edge.
            let bottom = Design.windowInset + Design.Size.control + Design.Space.block
            ZStack(alignment: .bottomLeading) {
                if isShown {
                    Color.black.opacity(0.001).contentShape(Rectangle()).onTapGesture(perform: close)
                    ListPopoverBody(title: title, query: $query, sections: sections, empty: empty,
                                    maxHeight: min(PopoverMetrics.maxHeight, proxy.size.height - bottom - Design.Size.header),
                                    close: close, menu: menu)
                        .overlayKeyboardFocus(id, in: window)
                        .padding(.bottom, bottom)
                        .padding(.leading, Design.Grid.edge)
                        .transition(.scale(scale: reduceMotion ? 1 : 0.96, anchor: .bottomLeading).combined(with: .opacity))
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .bottomLeading)
        }
        .ignoresSafeArea()
        .holdsSidebarPeek(id, in: window, isEnabled: isShown)
        .animation(reduceMotion ? Design.Motion.reduced : .spring(duration: 0.25), value: isShown)
    }
}

/// The popover's grid: concentric corners, one icon column for the search symbol and the rows' icons.
enum PopoverMetrics {
    static let width: CGFloat = 340
    static let maxHeight: CGFloat = 520
    static let radius: CGFloat = 18
    static let inset: CGFloat = 6
    static let innerRadius = Design.concentric(radius, inset: inset)
    /// From the inner edge: the icons' column, then the text's.
    static let iconLeading: CGFloat = 8
    static let iconWidth: CGFloat = 16
    static let iconToText: CGFloat = 8
    static let titleHeight: CGFloat = 36
    static let fieldHeight: CGFloat = 30
    static let rowHeight: CGFloat = 32
    static let emptyHeight: CGFloat = 140
    static func headerHeight(first: Bool) -> CGFloat { (first ? 8 : 14) + 14 + 2 }

    /// The list's height with nothing scrolled away, so a short list gets a short popover.
    static func listHeight(_ sections: [PanelSection]) -> CGFloat {
        let rows = sections.reduce(0) { $0 + $1.items.count }
        return CGFloat(rows) * rowHeight + sections.indices.map { headerHeight(first: $0 == 0) }.reduce(0, +)
            + Design.Space.row * CGFloat(max(0, sections.count + rows - 1))
    }
}

struct ListPopoverBody<Menu: View>: View {
    let title: String
    @Binding var query: String
    let sections: [PanelSection]
    let empty: PanelEmptyState
    let maxHeight: CGFloat
    let close: () -> Void
    let menu: Menu
    @State private var selection: String?
    /// Where the arrows went: the list follows them, not the pointer (its row is on screen already).
    @State private var scrollTarget: String?
    @FocusState private var focused: Bool

    var body: some View {
        let isEmpty = sections.allSatisfy(\.items.isEmpty)
        let chrome = PopoverMetrics.titleHeight + PopoverMetrics.fieldHeight + Design.Space.block + PopoverMetrics.inset * 2
        VStack(alignment: .leading, spacing: 0) {
            titleRow
            field.padding(.bottom, Design.Space.block)
            Group { if isEmpty { emptyState } else { list } }
                .frame(height: min(isEmpty ? PopoverMetrics.emptyHeight : PopoverMetrics.listHeight(sections), maxHeight - chrome))
        }
        .padding(PopoverMetrics.inset)
        .frame(width: PopoverMetrics.width)
        .glassSurface(in: RoundedRectangle(cornerRadius: PopoverMetrics.radius, style: .continuous))
        .onExitCommand {
            if query.isEmpty { close() } else { query = "" }
        }
        // The overlay window becomes key on the same turn.
        .onAppear { DispatchQueue.main.async { focused = true } }
        .onChange(of: query) { selection = query.isEmpty ? nil : sections.first?.items.first?.id }
    }

    private var titleRow: some View {
        HStack(spacing: 0) {
            Text(title).font(.headline)
            Spacer(minLength: 8)
            if Menu.self != EmptyView.self {
                SwiftUI.Menu { menu } label: {
                    Image(systemName: "ellipsis").font(.system(size: 13, weight: .semibold))
                        .frame(width: 28, height: 28)
                        .contentShape(Circle())
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("More")
            }
        }
        .padding(.leading, PopoverMetrics.iconLeading + 2)
        .padding(.trailing, 2)
        .frame(height: PopoverMetrics.titleHeight)
    }

    private var field: some View {
        HStack(spacing: PopoverMetrics.iconToText) {
            Image(systemName: "magnifyingglass").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                .frame(width: PopoverMetrics.iconWidth)
            TextField("Search", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($focused)
                .onSubmit(openSelection)
                .onKeyPress(.downArrow) { move(1); return .handled }
                .onKeyPress(.upArrow) { move(-1); return .handled }
                .onKeyPress(.delete, phases: .down) { press in
                    guard press.modifiers.contains(.command), let item = selected, item.remove != nil else { return .ignored }
                    remove(item)
                    return .handled
                }
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 12)).foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("Clear Search")
            }
        }
        .padding(.leading, PopoverMetrics.iconLeading)
        .padding(.trailing, 8)
        .frame(height: PopoverMetrics.fieldHeight)
        .background(Design.Fill.hover, in: RoundedRectangle(cornerRadius: PopoverMetrics.innerRadius, style: .continuous))
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Design.Space.row) {
                    ForEach(Array(sections.enumerated()), id: \.element.id) { i, section in
                        Text(section.title)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(height: 14)
                            .padding(.leading, PopoverMetrics.iconLeading)
                            .padding(.top, i == 0 ? 8 : 14)
                            .padding(.bottom, 2)
                        ForEach(section.items) { item in
                            PopoverRow(item: item, selected: item.id == selection, open: { open(item) }, remove: { remove(item) })
                                .id(item.id)
                                .onHover { if $0 { selection = item.id } }
                        }
                    }
                }
            }
            .scrollIndicators(.automatic)
            .onChange(of: scrollTarget) { if let scrollTarget { proxy.scrollTo(scrollTarget) } }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 4) {
            Image(systemName: empty.symbol).font(.system(size: 22, weight: .light)).foregroundStyle(.tertiary).padding(.bottom, 4)
            Text(empty.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
            if let detail = empty.detail {
                Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var items: [PanelItem] { sections.flatMap(\.items) }
    private var selected: PanelItem? { items.first { $0.id == selection } }

    private func move(_ delta: Int) {
        let ids = items.map(\.id)
        guard !ids.isEmpty else { return }
        let index = selection.flatMap { ids.firstIndex(of: $0) }.map { $0 + delta } ?? (delta > 0 ? 0 : ids.count - 1)
        selection = ids[min(max(index, 0), ids.count - 1)]
        scrollTarget = selection
    }

    private func openSelection() {
        if let selected { open(selected) }
    }

    private func open(_ item: PanelItem) {
        item.open()
        close()
    }

    /// The selection moves on to the next row, as in Mail.
    private func remove(_ item: PanelItem) {
        let ids = items.map(\.id)
        if item.id == selection, let i = ids.firstIndex(of: item.id) {
            selection = i + 1 < ids.count ? ids[i + 1] : i > 0 ? ids[i - 1] : nil
        }
        item.remove?.action()
    }
}

/// A row of a popover's list: the site's icon, the title, a time; washed while selected (by the arrows or the pointer),
/// its × replacing the time under the pointer. The address shows as its tooltip.
struct PopoverRow: View {
    let item: PanelItem
    let selected: Bool
    let open: () -> Void
    let remove: () -> Void
    @State private var hovering = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: PopoverMetrics.innerRadius, style: .continuous)
        HStack(spacing: PopoverMetrics.iconToText) {
            SiteIcon(item.icon).frame(width: PopoverMetrics.iconWidth, height: PopoverMetrics.iconWidth)
            Text(item.title).font(.system(size: 13)).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 8)
            ZStack(alignment: .trailing) {
                if let detail = item.detail {
                    Text(detail).font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary)
                        .opacity(hovering && item.remove != nil ? 0 : 1)
                }
                if let action = item.remove, hovering {
                    RemoveButton(help: action.title, action: remove)
                }
            }
        }
        .padding(.leading, PopoverMetrics.iconLeading)
        .padding(.trailing, 4)
        .frame(height: PopoverMetrics.rowHeight)
        .background(shape.fill(selected ? Design.Fill.selection : .clear))
        .contentShape(shape)
        .onTapGesture(perform: open)
        .onHover { h in withAnimation(Design.Motion.hover) { hovering = h } }
        .help(item.subtitle ?? item.title)
        .contextMenu {
            Button("Open", action: open)
            if let url = item.url {
                Button("Copy Link") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(url.absoluteString, forType: .string)
                }
            }
            if let action = item.remove {
                Divider()
                Button(action.title, action: remove)
            }
        }
    }
}

/// A row's ×: a circle that lights up under the pointer, as a tab's close button does.
struct RemoveButton: View {
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).frame(width: 20, height: 20)
                .background(Circle().fill(hovering ? Design.Fill.selection : .clear))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(hovering ? .primary : .secondary)
        .onHover { h in withAnimation(Design.Motion.hover) { hovering = h } }
        .help(help)
        .accessibilityLabel(help)
    }
}
