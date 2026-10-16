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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let window: BrowserWindowState
    let model: CommandBarModel

    var body: some View {
        let content = window.contentFrame
        ZStack(alignment: .topLeading) {
            if window.flags.contains(CommandBarModel.flag), model.session(window) != nil {
                Color.black.opacity(0.1)
                    .contentShape(Rectangle())
                    .onTapGesture { model.close(window) }
                    .transition(.opacity.animation(reduceMotion ? Design.Motion.reduced : Design.Motion.panelFade))
                // Over the page, not the window: centered on the card, a sixth of the way down.
                CommandBarPanel(window: window, model: model)
                    .overlayKeyboardFocus("command-bar", in: window)
                    .frame(width: min(CommandBarPanel.width, max(320, content.width - 48)))
                    .frame(width: content.width)
                    .offset(x: content.minX, y: content.minY + max(48, content.height * 0.16))
                    .transition(reduceMotion ? .opacity.animation(Design.Motion.reduced) : Self.spotlight)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .ignoresSafeArea()
    }

    /// Spotlight's: fades in over 0.14 s while settling from 96% (top edge held); leaves in 0.12 s, shrinking to 98%.
    static let spotlight = AnyTransition.asymmetric(
        insertion: .opacity.animation(Design.Motion.panelFade)
            .combined(with: .scale(scale: Design.Motion.panelEnterScale, anchor: .top).animation(Design.Motion.panelSettle)),
        removal: .opacity.combined(with: .scale(scale: Design.Motion.panelExitScale, anchor: .top)).animation(Design.Motion.panelExit))
}

struct CommandBarPanel: View {
    let window: BrowserWindowState
    let model: CommandBarModel
    @FocusState private var focused: Bool

    static let width: CGFloat = 640
    /// The field's row: with no results the panel is a capsule (its radius is half this).
    static let fieldHeight: CGFloat = 56
    static let radius = fieldHeight / 2
    /// Rows sit this far inside the panel, so their corners near the panel's are concentric with it.
    static let inset: CGFloat = 8
    /// The field's symbol and the rows' icons share one column; text starts at `textX`.
    static let iconX: CGFloat = 20
    static let iconWidth: CGFloat = 20
    static let textX: CGFloat = 50

    var body: some View {
        let session = model.session(window)
        let items = model.items(for: window)
        let query = Binding(get: { model.session(window)?.query ?? "" }, set: { model.setQuery($0, in: window) })
        let shape = RoundedRectangle(cornerRadius: Self.radius, style: .continuous)
        VStack(spacing: 0) {
            HStack(spacing: Self.textX - Self.iconX - Self.iconWidth) {
                Image(systemName: session?.mode == .editURL ? "link" : "magnifyingglass")
                    .font(.system(size: 17, weight: .medium)).foregroundStyle(.secondary)
                    .frame(width: Self.iconWidth)
                TextField(session?.mode == .editURL ? "Enter address" : "Search or enter address", text: query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 22))
                    .focused($focused)
                    .onSubmit { model.execute(window) }
                    .onKeyPress(.downArrow) { model.moveSelection(1, in: window); return .handled }
                    .onKeyPress(.upArrow) { model.moveSelection(-1, in: window); return .handled }
                    .onKeyPress(.escape) { model.close(window); return .handled }
                    .onKeyPress(.tab) { completeKeyword(query); return .handled }
            }
            .padding(.leading, Self.iconX)
            .padding(.trailing, 20)
            .frame(height: Self.fieldHeight)
            if !items.isEmpty {
                Rectangle().fill(Design.Fill.hairline).frame(height: 1).padding(.horizontal, 16)
                VStack(spacing: 2) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { i, item in
                        OmniboxRow(item: item, selected: i == session?.selection, isLast: i == items.count - 1)
                            .contentShape(Rectangle())
                            .onTapGesture { model.execute(window, index: i) }
                    }
                }
                .padding(Self.inset)
            }
        }
        .background(Design.Fill.glassScrim, in: shape)
        .glassSurface(in: shape)
        .shadow(color: .black.opacity(0.22), radius: 24, y: 10)
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
    @Environment(BrowserEnvironment.self) private var env
    let item: OmniboxItem
    let selected: Bool
    let isLast: Bool

    var body: some View {
        // The last row's bottom corners are concentric with the panel's.
        let bottom = isLast ? Design.concentric(CommandBarPanel.radius, inset: CommandBarPanel.inset) : Design.Radius.item
        let shape = UnevenRoundedRectangle(topLeadingRadius: Design.Radius.item, bottomLeadingRadius: bottom,
                                           bottomTrailingRadius: bottom, topTrailingRadius: Design.Radius.item, style: .continuous)
        HStack(spacing: CommandBarPanel.textX - CommandBarPanel.iconX - CommandBarPanel.iconWidth) {
            icon.frame(width: 18, height: 18).frame(width: CommandBarPanel.iconWidth)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title).font(.system(size: 14, weight: .medium)).lineLimit(1)
                if let s = item.subtitle { Text(s).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1) }
            }
            Spacer(minLength: 8)
            if let a = item.accessory { Text(a).font(.system(size: 11, design: .rounded)).foregroundStyle(.secondary) }
            Text(item.kind).font(.system(size: 11)).foregroundStyle(.tertiary)
        }
        .padding(.leading, CommandBarPanel.iconX - CommandBarPanel.inset)
        .padding(.trailing, 12)
        .frame(height: item.subtitle == nil ? 36 : 44)
        .background(shape.fill(selected ? Design.Fill.selection : .clear))
    }

    @ViewBuilder private var icon: some View {
        switch item.icon {
        case .system(let name):
            Image(systemName: name).foregroundStyle(.secondary)
        case .image(let image):
            Image(nsImage: image).resizable().scaledToFit()
        case .favicon(let url):
            // Only an icon a page already showed: typing contacts no site.
            SiteIcon(env.runtime.favicons.image(for: url))
        }
    }
}
