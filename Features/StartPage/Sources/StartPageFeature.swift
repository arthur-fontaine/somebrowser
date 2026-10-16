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
                VStack(alignment: .leading, spacing: 28) {
                    field
                    if runtime.settings.bool("start-page.showFavorites") { favorites }
                    getStarted
                    SlotHost("start-page.extras", window: window)
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
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").font(.system(size: 15, weight: .medium)).foregroundStyle(.secondary)
            TextField("Search or type a URL", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 17))
                .focused($focused)
                .onSubmit { StartPageFeature.submit(text, window: window, runtime: runtime); text = "" }
        }
        .padding(.horizontal, 16)
        .frame(height: 44)
        .background(Design.Fill.hover, in: Capsule())
    }

    /// Before there's any history: the first things to do.
    @ViewBuilder
    private var getStarted: some View {
        let fresh = !window.isPrivate && runtime.capabilities.history?.recent(limit: 1).isEmpty != false
        let canImport = runtime.commands.isHandled("import.open")
        let canBeDefault = runtime.commands.canRun("start-page.make-default")
        if fresh, canImport || canBeDefault {
            PageSection("Get Started") {
                VStack(spacing: 8) {
                    if canImport {
                        PageCard(symbol: "square.and.arrow.down", title: "Import from Safari or Chrome…") {
                            try? runtime.commands.run("import.open", window: window)
                        }
                    }
                    if canBeDefault {
                        PageCard(symbol: "globe", title: "Make \(Brand.name) your default browser") {
                            try? runtime.commands.run("start-page.make-default", window: window)
                        }
                    }
                }
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
