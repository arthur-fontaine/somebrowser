import AppKit
import BrowserCore
import SwiftUI

public final class CommandBarFeature: BrowserFeature {
    let context: FeatureContext
    let model: CommandBarModel

    public init(context: FeatureContext) {
        self.context = context
        model = CommandBarModel(runtime: context.runtime)
    }

    public func activate() {
        let model = self.model
        context.ui.contribute(.overlay, id: "command-bar", order: 100) { window in
            CommandBarOverlay(window: window, model: model)
        }
        context.commands.handle("command-bar.open") { [weak self] inv in
            guard let self, let w = inv.window else { return }
            if model.session(w)?.mode == .newTab {
                model.close(w)
            } else if let page = self.context.capabilities.newTabPage?.newTabPage(in: w) {
                self.context.runtime.openTab(page, in: w)
                self.context.shell?.focusContent(in: w)
            } else {
                model.open(w, mode: .newTab)
            }
        }
        context.commands.handle("command-bar.edit-url") { inv in
            guard let w = inv.window else { return }
            if model.session(w)?.mode == .editURL { model.close(w) } else { model.open(w, mode: .editURL) }
        }
        context.commands.handle("command-bar.paste-and-go") { [weak self] inv in
            guard let self, let w = inv.window,
                  let s = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty,
                  let url = self.context.capabilities.search?.url(for: s) ?? URL(string: s) else { return }
            model.open(url, in: w, mode: .newTab)
        }
    }
}

struct CommandBarOverlay: View {
    let window: BrowserWindowState
    let model: CommandBarModel

    var body: some View {
        if window.flags.contains(CommandBarModel.flag), model.session(window) != nil {
            ZStack(alignment: .top) {
                Color.black.opacity(0.12)
                    .contentShape(Rectangle())
                    .onTapGesture { model.close(window) }
                CommandBarPanel(window: window, model: model)
                    .overlayKeyboardFocus("command-bar", in: window)
                    .padding(.top, 90)
                    .transition(.asymmetric(insertion: .scale(scale: 0.97, anchor: .top).combined(with: .opacity),
                                            removal: .opacity))
            }
            .ignoresSafeArea()
        }
    }
}

struct CommandBarPanel: View {
    let window: BrowserWindowState
    let model: CommandBarModel
    @FocusState private var focused: Bool

    var body: some View {
        let session = model.session(window)
        let items = model.items(for: window)
        let query = Binding(get: { model.session(window)?.query ?? "" }, set: { model.setQuery($0, in: window) })
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: session?.mode == .editURL ? "link" : "magnifyingglass")
                    .font(.system(size: 17, weight: .medium)).foregroundStyle(.secondary)
                TextField(session?.mode == .editURL ? "Enter address" : "Search or enter address", text: query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 19))
                    .focused($focused)
                    .onSubmit { model.execute(window) }
                    .onKeyPress(.downArrow) { model.moveSelection(1, in: window); return .handled }
                    .onKeyPress(.upArrow) { model.moveSelection(-1, in: window); return .handled }
                    .onKeyPress(.escape) { model.close(window); return .handled }
                    .onKeyPress(.tab) { completeKeyword(query); return .handled }
            }
            .padding(.horizontal, 18)
            .frame(height: 54)
            if !items.isEmpty {
                Divider().opacity(0.5)
                VStack(spacing: 2) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { i, item in
                        OmniboxRow(item: item, selected: i == session?.selection)
                            .contentShape(Rectangle())
                            .onTapGesture { model.execute(window, index: i) }
                    }
                }
                .padding(6)
            }
        }
        .frame(width: 640)
        .glassSurface(in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .shadow(color: .black.opacity(0.28), radius: 30, y: 12)
        .onAppear { focused = true }
        .task(id: session?.query) {
            guard let q = session?.query, let search = model.search else { return }
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            let list = await search.suggestions(for: q)
            model.setSuggestions(list, for: q, in: window)
        }
    }

    /// Arc: "yt" + Tab turns into a site search prompt.
    private func completeKeyword(_ query: Binding<String>) {
        let q = query.wrappedValue.trimmingCharacters(in: .whitespaces)
        if !q.isEmpty, !q.contains(" ") { query.wrappedValue = q + " " }
    }
}

struct OmniboxRow: View {
    let item: OmniboxItem
    let selected: Bool

    var body: some View {
        HStack(spacing: 10) {
            icon.frame(width: 18, height: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title).font(.system(size: 14, weight: .medium)).lineLimit(1)
                if let s = item.subtitle { Text(s).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1) }
            }
            Spacer(minLength: 8)
            if let a = item.accessory { Text(a).font(.system(size: 11, design: .rounded)).foregroundStyle(.secondary) }
            Text(item.kind).font(.system(size: 11)).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12)
        .frame(height: item.subtitle == nil ? 36 : 44)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(selected ? Color.accentColor.opacity(0.18) : .clear))
    }

    @ViewBuilder private var icon: some View {
        switch item.icon {
        case .system(let name):
            Image(systemName: name).foregroundStyle(.secondary)
        case .image(let image):
            Image(nsImage: image).resizable().scaledToFit()
        case .favicon(let url):
            if let host = url?.host(), let u = URL(string: "https://\(host)/favicon.ico") {
                AsyncImage(url: u) { p in
                    if let i = p.image { i.resizable().scaledToFit() } else { Image(systemName: "globe").foregroundStyle(.secondary) }
                }
            } else {
                Image(systemName: "globe").foregroundStyle(.secondary)
            }
        }
    }
}
