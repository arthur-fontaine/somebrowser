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

    @ViewBuilder
    private var favorites: some View {
        let tabs = runtime.tabs.favorites.compactMap { runtime.tabs.tab($0) }
        if !tabs.isEmpty {
            PageSection("Favorites") {
                LazyVGrid(columns: SiteTile.columns, alignment: .leading, spacing: 14) {
                    ForEach(tabs.prefix(16)) { tab in
                        let url = tab.pinnedURL ?? tab.url
                        SiteTile(icon: tab.live?.favicon ?? runtime.favicons.image(for: url), title: tab.displayTitle, help: url?.absoluteString) {
                            runtime.select(tab.id, in: window)
                        }
                    }
                }
            }
        }
    }
}
