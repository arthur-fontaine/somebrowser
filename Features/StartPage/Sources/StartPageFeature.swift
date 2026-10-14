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
        if let tab = runtime.selectedTab(in: window), tab.url == nil, !tab.isLoaded {
            runtime.navigate(tab, to: url)
        } else {
            runtime.openTab(url, in: window)
        }
        runtime.shell?.focusContent(in: window)
    }
}

struct StartPage: View {
    let window: BrowserWindowState
    let runtime: BrowserRuntime
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 28) {
            Spacer()
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search or type a URL", text: $text)
                    .textFieldStyle(.plain)
                    .font(.system(size: 17))
                    .focused($focused)
                    .onSubmit { StartPageFeature.submit(text, window: window, runtime: runtime); text = "" }
            }
            .padding(.horizontal, 16)
            .frame(width: 520, height: 46)
            .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            if runtime.settings.bool("start-page.showFavorites") {
                favorites
            }
            SlotHost("start-page.extras", window: window)
            Spacer()
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { focused = true }
        .onChange(of: window.selectedTabID) { focused = true }
    }

    private var favorites: some View {
        let tabs = runtime.tabs.favorites.compactMap { runtime.tabs.tab($0) }
        return HStack(spacing: 18) {
            ForEach(tabs.prefix(8)) { tab in
                Button { runtime.select(tab.id, in: window) } label: {
                    VStack(spacing: 6) {
                        StartFavicon(url: tab.pinnedURL ?? tab.url)
                            .frame(width: 26, height: 26)
                            .frame(width: 56, height: 56)
                            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        Text(tab.displayTitle).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).frame(width: 70)
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }
}

struct StartFavicon: View {
    let url: URL?
    var body: some View {
        if let host = url?.host(), let icon = URL(string: "https://\(host)/favicon.ico") {
            AsyncImage(url: icon) { p in
                if let i = p.image { i.resizable().scaledToFit() } else { Image(systemName: "globe").foregroundStyle(.secondary) }
            }
        } else {
            Image(systemName: "globe").foregroundStyle(.secondary)
        }
    }
}
