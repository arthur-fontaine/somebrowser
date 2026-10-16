import AppKit
import BrowserCore
import SwiftUI

public final class StartPageFeature: BrowserFeature {
    let context: FeatureContext

    public init(context: FeatureContext) { self.context = context }

    public func activate() {
        let runtime = context.runtime
        context.ui.contribute(.emptyContent, id: "start-page") { window in
            StartPage(window: window, runtime: runtime)
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

/// A column of sections, left-aligned, a little way down the page: the field, Favorites, then what other features
/// contribute to `start-page.extras` (frequent sites, recently archived tabs, privacy, Safari). Local data only.
struct StartPage: View {
    let window: BrowserWindowState
    let runtime: BrowserRuntime
    @State private var text = ""
    @FocusState private var focused: Bool

    static let columnWidth: CGFloat = 680

    var body: some View {
        GeometryReader { geo in
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: Design.Space.section) {
                    field
                    if runtime.settings.bool("start-page.showFavorites") { favorites }
                    if isFirstRun { getStarted }
                    SlotHost("start-page.extras", window: window)
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

    private var field: some View {
        HStack(spacing: PageGrid.iconToText) {
            Image(systemName: "magnifyingglass").font(.system(size: 15, weight: .medium)).foregroundStyle(.secondary)
                .frame(width: PageGrid.iconWidth)
            TextField("Search or type a URL", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 17))
                .focused($focused)
                .onSubmit { StartPageFeature.submit(text, window: window, runtime: runtime); text = "" }
        }
        .padding(.leading, PageGrid.leading)
        .padding(.trailing, Design.Space.capsuleTrailing)
        .frame(height: 44)
        .background(Design.Fill.hover, in: Capsule())
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
