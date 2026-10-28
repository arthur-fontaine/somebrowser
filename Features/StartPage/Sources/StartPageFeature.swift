import AppKit
import BrowserCore
import SwiftUI

public final class StartPageFeature: BrowserFeature {
    let context: FeatureContext
    lazy var layout = StartPageLayout(file: context.dataDirectory.appendingPathComponent("layout.json"))

    public init(context: FeatureContext) { self.context = context }

    public func activate() {
        let runtime = context.runtime
        let layout = self.layout
        context.ui.contribute(.emptyContent, id: "start-page") { window in
            StartPage(window: window, runtime: runtime, layout: layout)
        }
        context.commands.handle("start-page.make-default", isEnabled: { _ in !Self.isDefaultBrowser }) { _ in Self.makeDefaultBrowser() }
    }

    /// Whether web links open here (asked of Launch Services; nothing leaves the Mac).
    static var isDefaultBrowser: Bool {
        NSWorkspace.shared.urlForApplication(toOpen: URL(string: "https://example.com")!)?.standardizedFileURL == Bundle.main.bundleURL.standardizedFileURL
    }

    /// macOS asks the user to confirm.
    static func makeDefaultBrowser() {
        for scheme in ["http", "https"] {
            NSWorkspace.shared.setDefaultApplication(at: Bundle.main.bundleURL, toOpenURLsWithScheme: scheme) { _ in }
        }
    }

    /// Typed text → URL via the search capability, loaded into the blank tab (or a new one).
    static func submit(_ text: String, window: BrowserWindowState, runtime: BrowserRuntime) {
        let input = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty, let url = runtime.capabilities.search?.url(for: input) ?? URL(string: input), url.scheme != nil else { return }
        runtime.open(url, fillingBlankTabIn: window)
        runtime.shell?.focusContent(in: window)
    }
}

/// The order of the start page's sections (its favorites and what features contribute), as the user arranged them.
@Observable
final class StartPageLayout {
    static let favoritesID = "start-page.favorites"
    private(set) var order: [String]
    /// Sections showing something: moving one up or down skips those that are empty.
    var visible: Set<String> = []
    /// The section being dragged by its header.
    var dragging: String?
    @ObservationIgnored private let file: URL?

    init(file: URL?) {
        self.file = file
        order = file.flatMap { try? Data(contentsOf: $0) }.flatMap { try? JSONDecoder().decode([String].self, from: $0) } ?? []
    }

    /// `available` in the saved order. A section never arranged goes after the one before it by default, so a feature
    /// enabled later lands where it would have been.
    static func arrange(_ saved: [String], _ available: [String]) -> [String] {
        var result = saved.filter(available.contains)
        for (i, id) in available.enumerated() where !result.contains(id) {
            let before = available[..<i].last(where: result.contains)
            result.insert(id, at: before.map { result.firstIndex(of: $0)! + 1 } ?? 0)
        }
        return result
    }

    /// Puts `id` where `target` is, pushing `target` the way `id` came from.
    func move(_ id: String, to target: String, in available: [String]) {
        var arranged = Self.arrange(order, available)
        guard id != target, let from = arranged.firstIndex(of: id), let to = arranged.firstIndex(of: target) else { return }
        arranged.remove(at: from)
        arranged.insert(id, at: to)
        order = arranged
    }

    /// The nearest section showing something before (`offset` -1) or after (1) `id`.
    func neighbour(of id: String, _ offset: Int, in available: [String]) -> String? {
        let arranged = Self.arrange(order, available).filter { visible.contains($0) || $0 == id }
        return arranged.firstIndex(of: id).flatMap { i in arranged.indices.contains(i + offset) ? arranged[i + offset] : nil }
    }

    func save() {
        guard let file, let data = try? JSONEncoder().encode(order) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }
}

/// A column of sections, left-aligned, a little way down the page: the field, then Favorites and what other features
/// contribute to `start-page.extras` (frequent sites, recently archived tabs, privacy, Safari), in the order the user
/// dragged them into (`StartPageLayout`). Local data only.
struct StartPage: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let window: BrowserWindowState
    let runtime: BrowserRuntime
    let layout: StartPageLayout
    @State private var text = ""
    @FocusState private var focused: Bool

    static let columnWidth: CGFloat = 680

    var body: some View {
        let extras = runtime.ui.views(for: "start-page.extras")
        let available = [StartPageLayout.favoritesID] + extras.map(\.id)
        GeometryReader { geo in
            ScrollView(.vertical) {
                SectionColumn(spacing: Design.Space.section) {
                    if hasOwnField { field }
                    if isFirstRun { getStarted }
                    ForEach(StartPageLayout.arrange(layout.order, available), id: \.self) { id in
                        Group {
                            if id == StartPageLayout.favoritesID {
                                if runtime.settings.bool("start-page.showFavorites") { favorites }
                            } else if let extra = extras.first(where: { $0.id == id }) {
                                extra.makeView(window)
                            }
                        }
                        .environment(\.pageSectionMover, mover(id, available))
                        .onGeometryChange(for: Bool.self) { $0.size.height > 0 } action: { shown in
                            if shown { layout.visible.insert(id) } else { layout.visible.remove(id) }
                        }
                        .onDisappear { layout.visible.remove(id) }
                        .onDrop(of: [.text], delegate: SectionDrop(id: id, available: available, layout: layout, animation: animation))
                    }
                    // Suggestions (connecting Safari…) go in Get Started on a first run, last on the page after.
                    if !isFirstRun { suggestions }
                }
                .frame(width: min(Self.columnWidth, geo.size.width - 64))
                .padding(.top, min(96, geo.size.height * 0.12))
                .padding(.bottom, 48)
                .frame(maxWidth: .infinity)
            }
            .scrollIndicators(.automatic)
        }
        .onAppear { focused = true }
        .onChange(of: window.selectedTabID) { focused = true }
    }

    private var animation: Animation { reduceMotion ? Design.Motion.reduced : Design.Motion.layout }

    private func mover(_ id: String, _ available: [String]) -> PageSectionMover {
        let move = { (offset: Int) -> (() -> Void)? in
            layout.neighbour(of: id, offset, in: available).map { other in
                { withAnimation(animation) { layout.move(id, to: other, in: available) }; layout.save() }
            }
        }
        return PageSectionMover(id: id, moveUp: move(-1), moveDown: move(1), dragBegan: { layout.dragging = id })
    }

    private var field: some View {
        HStack(spacing: PageGrid.iconToText) {
            Image(systemName: "magnifyingglass").font(.system(size: 15, weight: .medium)).foregroundStyle(.secondary)
                .frame(width: PageGrid.iconWidth)
            // A placeholder of our own, in a fixed line: the field's own moved its text 3 pt with focus and key state.
            TextField("", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 17))
                .focused($focused)
                .onSubmit { StartPageFeature.submit(text, window: window, runtime: runtime); text = "" }
                .frame(height: 22)
                .background(alignment: .leading) {
                    if text.isEmpty {
                        Text("Search or type a URL").font(.system(size: 17)).foregroundStyle(.tertiary).allowsHitTesting(false)
                    }
                }
        }
        .padding(.leading, PageGrid.leading)
        .padding(.trailing, Design.Space.capsuleTrailing)
        .frame(height: 44)
        .background(Design.Fill.hover, in: Capsule())
    }

    /// Addresses are typed in the sidebar's field (the command bar's inline style, as in Safari), so the page has no
    /// field of its own then; with the palette, or no command bar, it keeps one.
    private var hasOwnField: Bool {
        !runtime.commands.isHandled("command-bar.open") || runtime.settings.string("command-bar.style") == "palette"
    }

    /// Before there's any history.
    private var isFirstRun: Bool { !window.isPrivate && runtime.capabilities.history?.recent(limit: 1).isEmpty != false }

    private var suggestions: some View {
        VStack(spacing: Design.Space.block) { SlotHost("start-page.suggestions", window: window) }
    }

    /// The first things to do: import, make it the default, then what features suggest.
    private var getStarted: some View {
        PageSection("Get Started") {
            VStack(spacing: Design.Space.block) {
                if runtime.commands.isHandled("import.open") {
                    PageCard(symbol: "square.and.arrow.down", title: "Import from Safari or Chrome…") {
                        try? runtime.commands.run("import.open", window: window)
                    }
                }
                if runtime.commands.canRun("start-page.make-default") {
                    PageCard(symbol: "globe", title: "Make \(Brand.name) your default browser") {
                        try? runtime.commands.run("start-page.make-default", window: window)
                    }
                }
                SlotHost("start-page.suggestions", window: window)
            }
        }
    }

    @ViewBuilder
    private var favorites: some View {
        let tabs = runtime.tabs.favorites.compactMap { runtime.tabs.tab($0) }
        if !tabs.isEmpty {
            PageSection("Favorites") {
                LazyVGrid(columns: SiteTile.columns, alignment: .leading, spacing: 16) {
                    ForEach(tabs.prefix(16)) { tab in
                        let url = tab.pinnedURL ?? tab.url
                        // A favorite the user renamed keeps its name; others are named by their site, as frequent sites are.
                        let name = tab.customTitle.flatMap { $0.isEmpty ? nil : $0 } ?? SiteTile.name(for: url) ?? tab.displayTitle
                        SiteTile(icon: tab.live?.favicon ?? runtime.favicons.image(for: url), title: name, help: url?.absoluteString) {
                            runtime.select(tab.id, in: window)
                        }
                    }
                }
            }
        }
    }
}

/// A section dragged by its header moves as the pointer reaches another, and stays where it's dropped.
struct SectionDrop: DropDelegate {
    let id: String
    let available: [String]
    let layout: StartPageLayout
    let animation: Animation

    func validateDrop(info: DropInfo) -> Bool { layout.dragging != nil }

    func dropEntered(info: DropInfo) {
        guard let dragged = layout.dragging, dragged != id else { return }
        withAnimation(animation) { layout.move(dragged, to: id, in: available) }
        layout.save()  // a drag let go elsewhere keeps where it got to
    }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func performDrop(info: DropInfo) -> Bool {
        layout.dragging = nil
        return true
    }
}

/// A column with `spacing` only between subviews that show something: a section with nothing to show takes no room,
/// even with the modifiers that make it movable.
struct SectionColumn: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? subviews.map { $0.sizeThatFits(.unspecified).width }.max() ?? 0
        let heights = subviews.map { $0.sizeThatFits(ProposedViewSize(width: width, height: nil)).height }.filter { $0 > 0 }
        return CGSize(width: width, height: heights.reduce(0, +) + spacing * CGFloat(max(0, heights.count - 1)))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        var placedAny = false
        for subview in subviews {
            let size = ProposedViewSize(width: bounds.width, height: nil)
            let height = subview.sizeThatFits(size).height
            if height > 0, placedAny { y += spacing }
            subview.place(at: CGPoint(x: bounds.minX, y: y), anchor: .topLeading, proposal: ProposedViewSize(width: bounds.width, height: height))
            if height > 0 {
                y += height
                placedAny = true
            }
        }
    }
}
