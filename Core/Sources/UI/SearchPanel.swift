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

/// A searchable list over the page (History, the archive), as macOS 26's Spotlight: the field is a glass capsule with the
/// panel's actions as glass circles beside it, and the rows float in their own glass panel under it. The arrows move through the rows (as does the pointer),
/// Return opens one, Esc clears the field and then closes.
public struct SearchPanel<Actions: View>: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let window: BrowserWindowState
    let id: String
    let isShown: Bool
    let symbol: String
    let prompt: String
    @Binding var query: String
    let sections: [PanelSection]
    let empty: PanelEmptyState
    let close: () -> Void
    let actions: Actions

    public static var width: CGFloat { 640 }

    public init(_ id: String, in window: BrowserWindowState, isShown: Bool, symbol: String, prompt: String, query: Binding<String>,
                sections: [PanelSection], empty: PanelEmptyState, close: @escaping () -> Void,
                /// Glass circles beside the field: `PanelButton`, `PanelMenu`.
                @ViewBuilder actions: () -> Actions = { EmptyView() }) {
        self.id = id
        self.window = window
        self.isShown = isShown
        self.symbol = symbol
        self.prompt = prompt
        _query = query
        self.sections = sections
        self.empty = empty
        self.close = close
        self.actions = actions()
    }

    public var body: some View {
        let content = window.contentFrame
        let top = max(32, content.height * 0.12)
        ZStack(alignment: .topLeading) {
            if isShown {
                // Spotlight's: the page isn't dimmed, a click beside the panel closes it.
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture(perform: close)
                    .transition(.opacity)
                SearchPanelBody(window: window, symbol: symbol, prompt: prompt, query: $query, sections: sections,
                                empty: query.isEmpty ? empty : PanelEmptyState(symbol: "magnifyingglass", title: "No Results",
                                                                              detail: "Nothing matches “\(query)”."),
                                maxHeight: max(240, min(560, content.height - top - 32)), close: close, actions: actions)
                    .overlayKeyboardFocus(id, in: window)
                    .holdsSidebarPeek(id, in: window)
                    .frame(width: min(Self.width, max(320, content.width - 48)))
                    .frame(width: content.width)
                    .offset(x: content.minX, y: content.minY + top)
                    // Spotlight's: settles from 96% (top edge held) as it fades in, shrinks to 98% as it leaves.
                    .transition(.asymmetric(
                        insertion: .scale(scale: reduceMotion ? 1 : Design.Motion.panelEnterScale, anchor: .top).combined(with: .opacity),
                        removal: .scale(scale: reduceMotion ? 1 : Design.Motion.panelExitScale, anchor: .top).combined(with: .opacity)))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .ignoresSafeArea()
        .animation(reduceMotion ? Design.Motion.reduced : isShown ? Design.Motion.panelSettle : Design.Motion.panelExit, value: isShown)
    }
}

/// The panel's grid: the field's symbol and the rows' icons share one column, text starts at `textX`.
enum PanelMetrics {
    /// The field's height; it and the action buttons are capsules and circles of it.
    static let fieldHeight: CGFloat = 52
    /// Between the field, its buttons and the list (glass apart, blending as one).
    static let gap = Design.Space.block
    static let listRadius: CGFloat = 26
    /// Rows sit this far inside the list, so their corners are concentric with its.
    static let inset: CGFloat = 8
    static let rowRadius = Design.concentric(listRadius, inset: inset)
    static let iconX: CGFloat = fieldHeight / 2
    static let iconWidth: CGFloat = 20
    static let textX: CGFloat = iconX + iconWidth / 2 + 16
    static let emptyHeight: CGFloat = 200
    static func rowHeight(_ item: PanelItem) -> CGFloat { item.subtitle == nil ? 40 : 48 }
    static func headerHeight(first: Bool) -> CGFloat { (first ? 8 : 16) + 16 + 4 }

    /// The list's height with nothing scrolled away, so a short list gets a short panel.
    static func listHeight(_ sections: [PanelSection]) -> CGFloat {
        let rows = sections.flatMap(\.items)
        let elements = sections.count + rows.count
        return inset * 2 + rows.map(rowHeight).reduce(0, +)
            + sections.indices.map { headerHeight(first: $0 == 0) }.reduce(0, +)
            + Design.Space.row * CGFloat(max(0, elements - 1))
    }
}

struct SearchPanelBody<Actions: View>: View {
    let window: BrowserWindowState
    let symbol: String
    let prompt: String
    @Binding var query: String
    let sections: [PanelSection]
    let empty: PanelEmptyState
    let maxHeight: CGFloat
    let close: () -> Void
    let actions: Actions
    @State private var selection: String?
    /// Where the arrows went: the list follows them, not the pointer (its row is on screen already).
    @State private var scrollTarget: String?
    @FocusState private var focused: Bool

    var body: some View {
        let isEmpty = sections.allSatisfy(\.items.isEmpty)
        let listShape = RoundedRectangle(cornerRadius: PanelMetrics.listRadius, style: .continuous)
        GlassGroup(spacing: PanelMetrics.gap) {
            VStack(spacing: PanelMetrics.gap) {
                HStack(spacing: PanelMetrics.gap) {
                    field
                    actions
                }
                Group { if isEmpty { emptyState } else { list } }
                    .frame(height: min(isEmpty ? PanelMetrics.emptyHeight : PanelMetrics.listHeight(sections),
                                       maxHeight - PanelMetrics.fieldHeight - PanelMetrics.gap))
                    .clipShape(listShape)
                    .glassSurface(in: listShape)
            }
        }
        .shadow(color: .black.opacity(0.12), radius: 20, y: 8)
        .onKeyPress(.escape) {
            if query.isEmpty { close() } else { query = "" }
            return .handled
        }
        // The overlay window becomes key on the same turn.
        .onAppear { DispatchQueue.main.async { focused = true } }
        .onChange(of: query) { selection = query.isEmpty ? nil : sections.first?.items.first?.id }
    }

    private var field: some View {
        HStack(spacing: 0) {
            Image(systemName: symbol).font(.system(size: 17, weight: .medium)).foregroundStyle(.secondary)
                .frame(width: PanelMetrics.iconWidth)
                .padding(.leading, PanelMetrics.iconX - PanelMetrics.iconWidth / 2)
            TextField(prompt, text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 17))
                .focused($focused)
                .onSubmit(openSelection)
                .onKeyPress(.downArrow) { move(1); return .handled }
                .onKeyPress(.upArrow) { move(-1); return .handled }
                .padding(.leading, PanelMetrics.textX - PanelMetrics.iconX - PanelMetrics.iconWidth / 2)
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 15)).foregroundStyle(.tertiary)
                        .frame(width: 28, height: 28).contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help("Clear Search")
                .padding(.trailing, PanelMetrics.fieldHeight / 2 - 14)
            }
        }
        .padding(.trailing, query.isEmpty ? Design.Space.capsuleTrailing : 0)
        .frame(height: PanelMetrics.fieldHeight)
        .glassSurface(in: Capsule())
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Design.Space.row) {
                    ForEach(Array(sections.enumerated()), id: \.element.id) { i, section in
                        Text(section.title)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(height: 16)
                            .padding(.leading, PanelMetrics.iconX - PanelMetrics.iconWidth / 2 - PanelMetrics.inset)
                            .padding(.top, i == 0 ? 8 : 16)
                            .padding(.bottom, 4)
                        ForEach(section.items) { item in
                            PanelRow(item: item, selected: item.id == selection) { open(item) }
                                .id(item.id)
                                .onHover { if $0 { selection = item.id } }
                        }
                    }
                }
                .padding(PanelMetrics.inset)
            }
            .scrollIndicators(.automatic)
            .onChange(of: scrollTarget) { if let scrollTarget { proxy.scrollTo(scrollTarget) } }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: empty.symbol).font(.system(size: 30, weight: .light)).foregroundStyle(.tertiary).padding(.bottom, 4)
            Text(empty.title).font(.system(size: 15, weight: .semibold)).foregroundStyle(.secondary)
            if let detail = empty.detail {
                Text(detail).font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 320)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    private var items: [PanelItem] { sections.flatMap(\.items) }

    private func move(_ delta: Int) {
        let ids = items.map(\.id)
        guard !ids.isEmpty else { return }
        let index = selection.flatMap { ids.firstIndex(of: $0) }.map { $0 + delta } ?? (delta > 0 ? 0 : ids.count - 1)
        selection = ids[min(max(index, 0), ids.count - 1)]
        scrollTarget = selection
    }

    private func openSelection() {
        if let item = items.first(where: { $0.id == selection }) { open(item) }
    }

    private func open(_ item: PanelItem) {
        item.open()
        close()
    }
}

/// A row of a panel's list: washed while selected (by the arrows or the pointer); its × replaces the detail under the
/// pointer.
struct PanelRow: View {
    let item: PanelItem
    let selected: Bool
    let open: () -> Void
    @State private var hovering = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: PanelMetrics.rowRadius, style: .continuous)
        HStack(spacing: 0) {
            SiteIcon(item.icon).frame(width: 18, height: 18).frame(width: PanelMetrics.iconWidth)
                .padding(.leading, PanelMetrics.iconX - PanelMetrics.iconWidth / 2 - PanelMetrics.inset)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title).font(.system(size: 13, weight: .medium)).lineLimit(1).truncationMode(.tail)
                if let subtitle = item.subtitle {
                    Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
            }
            .padding(.leading, PanelMetrics.textX - PanelMetrics.iconX - PanelMetrics.iconWidth / 2)
            Spacer(minLength: 12)
            ZStack(alignment: .trailing) {
                if let detail = item.detail {
                    Text(detail).font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary)
                        .opacity(hovering && item.remove != nil ? 0 : 1)
                }
                if let remove = item.remove, hovering {
                    RemoveButton(help: remove.title, action: remove.action)
                }
            }
        }
        .padding(.trailing, 12)
        .frame(height: PanelMetrics.rowHeight(item))
        .background(shape.fill(selected ? Design.Fill.selection : .clear))
        .contentShape(shape)
        .onTapGesture(perform: open)
        .onHover { h in withAnimation(Design.Motion.hover) { hovering = h } }
        .contextMenu {
            Button("Open", action: open)
            if let url = item.url {
                Button("Copy Link") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(url.absoluteString, forType: .string)
                }
            }
            if let remove = item.remove {
                Divider()
                Button(remove.title, action: remove.action)
            }
        }
    }
}

/// A row's ×: a 24 pt circle that lights up under the pointer, as a tab's close button does.
struct RemoveButton: View {
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).frame(width: 24, height: 24)
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

/// An action beside a panel's field: a glass circle as tall as the field.
public struct PanelButton: View {
    let systemImage: String
    let help: String
    let action: () -> Void

    public init(systemImage: String, help: String, action: @escaping () -> Void) {
        self.systemImage = systemImage
        self.help = help
        self.action = action
    }

    public var body: some View {
        Button(action: action) { PanelButtonSymbol(systemImage: systemImage) }
            .buttonStyle(.plain)
            .glassControl(in: Circle())
            .help(help)
            .accessibilityLabel(help)
    }
}

/// `PanelButton` opening a menu.
public struct PanelMenu<Content: View>: View {
    let systemImage: String
    let help: String
    let content: Content

    public init(systemImage: String, help: String, @ViewBuilder content: () -> Content) {
        self.systemImage = systemImage
        self.help = help
        self.content = content()
    }

    public var body: some View {
        Menu { content } label: { PanelButtonSymbol(systemImage: systemImage) }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .glassControl(in: Circle())
            .help(help)
            .accessibilityLabel(help)
    }
}

struct PanelButtonSymbol: View {
    let systemImage: String

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: 16, weight: .medium))
            .foregroundStyle(.primary)
            .frame(width: PanelMetrics.fieldHeight, height: PanelMetrics.fieldHeight)
            .contentShape(Circle())
    }
}
