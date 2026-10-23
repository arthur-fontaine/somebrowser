import AppKit
import BrowserCore
import SwiftUI

public final class CommandBarFeature: BrowserFeature {
    let context: FeatureContext
    let model: CommandBarModel

    var style: CommandBarModel.Style { CommandBarModel.Style(rawValue: context.settings.string("command-bar.style")) ?? .inline }

    /// Edits in the sidebar's address field; with the sidebar hidden, it floats in for the occasion. A window without a
    /// sidebar gets the palette.
    func openInline(_ w: BrowserWindowState, mode: CommandBarModel.Mode) {
        guard w.allowsSidebar else { return model.open(w, mode: mode) }
        if !w.isSidebarVisible && !w.isSidebarPeeking {
            withAnimation(.spring(duration: 0.28, bounce: 0.1)) { w.isSidebarPeeking = true }  // the peek's own slide
            model.peeked.insert(w.id)
        }
        model.open(w, mode: mode, style: .inline)
    }

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
            } else if self.style == .inline {
                // As Safari: the new tab first (its start page behind), then its address being typed; an untouched blank
                // tab is reused rather than joined by another.
                if let current = self.context.runtime.selectedTab(in: w), current.url == nil, !current.isLoaded {
                    self.openInline(w, mode: .newTab)
                } else {
                    let tab = self.context.runtime.openTab(nil, in: w)
                    self.openInline(w, mode: .newTab)
                    model.openedBlankTab[w.id] = tab.id
                }
            } else {
                model.open(w, mode: .newTab)
            }
        }
        // A window without a sidebar (a Quick Look window) shows no address to edit, nor does Claude's space.
        let editable = { [weak self] (w: BrowserWindowState) in
            w.allowsSidebar && self?.context.tabs.space(w.spaceID)?.kind.isUserDriven != false
        }
        context.commands.handle("command-bar.edit-url", isEnabled: { $0.window.map(editable) ?? true }) { [weak self] inv in
            guard let self, let w = inv.window, editable(w) else { return }
            if model.session(w)?.mode == .editURL {
                model.close(w)
            } else if self.style == .inline {
                self.openInline(w, mode: .editURL)
            } else {
                model.open(w, mode: .editURL)
            }
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
        ZStack {
            Palette(window: window, model: model)
            InlineEditor(window: window, model: model)
        }
    }
}

/// Arc's centered palette (the `palette` style).
struct Palette: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let window: BrowserWindowState
    let model: CommandBarModel
    @State private var opacity: Double = 0
    @State private var scale = Design.Motion.panelEnterScale

    var body: some View {
        let shown = window.flags.contains(CommandBarModel.flag) && model.session(window)?.style == .palette
        let content = window.contentFrame
        // Always mounted, hidden: opening only changes opacity and scale. Building the glass and the field on each
        // open stalled the first frames of the arrival.
        ZStack(alignment: .topLeading) {
            Color.black.opacity(0.1 * opacity)
                .contentShape(Rectangle())
                .allowsHitTesting(shown)
                .onTapGesture { model.close(window) }
            // Over the page, not the window: centered on the card, a sixth of the way down.
            CommandBarPanel(window: window, model: model, isShown: shown)
                .overlayKeyboardFocus("command-bar", in: window, isEnabled: shown)
                .frame(width: min(CommandBarPanel.width, max(320, content.width - 48)))
                .scaleEffect(reduceMotion ? 1 : scale, anchor: .top)
                .opacity(opacity)
                .allowsHitTesting(shown)
                .frame(width: content.width)
                .offset(x: content.minX, y: content.minY + max(48, content.height * 0.16))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .ignoresSafeArea()
        .onChange(of: shown) { present(shown) }
    }

    /// Spotlight's: fades in over 0.14 s while settling from 96% (top edge held); leaves in 0.12 s, shrinking to 98%.
    private func present(_ shown: Bool) {
        if shown {
            var still = Transaction()
            still.disablesAnimations = true
            withTransaction(still) { scale = Design.Motion.panelEnterScale }
            withAnimation(reduceMotion ? Design.Motion.reduced : Design.Motion.panelFade) { opacity = 1 }
            withAnimation(Design.Motion.panelSettle) { scale = 1 }
        } else {
            withAnimation(reduceMotion ? Design.Motion.reduced : Design.Motion.panelExit) {
                opacity = 0
                scale = Design.Motion.panelExitScale
            }
        }
    }
}

struct CommandBarPanel: View {
    let window: BrowserWindowState
    let model: CommandBarModel
    let isShown: Bool
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
        let items = isShown ? model.items(for: window) : []  // always mounted: hidden, it ranks nothing
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
                    .disabled(!isShown)  // hidden, it never takes the keyboard
                    .focused($focused)
                    .onSubmit { model.execute(window, inNewTab: NSEvent.modifierFlags.contains(.option)) }
                    .onKeyPress(.downArrow) { model.moveSelection(1, in: window); return .handled }
                    .onKeyPress(.upArrow) { model.moveSelection(-1, in: window); return .handled }
                    .onKeyPress(.escape) { model.escape(window); return .handled }
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
        // Focused once it's on screen (the overlay window becomes key on the same turn), unfocused when hidden.
        .onChange(of: isShown, initial: true) { DispatchQueue.main.async { focused = isShown } }
        .task(id: session?.typed) {
            guard let q = session?.typed, let search = model.search else { return }
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
    let isLast: Bool

    var body: some View {
        // The last row's bottom corners are concentric with the panel's.
        let bottom = isLast ? Design.concentric(CommandBarPanel.radius, inset: CommandBarPanel.inset) : Design.Radius.item
        let shape = UnevenRoundedRectangle(topLeadingRadius: Design.Radius.item, bottomLeadingRadius: bottom,
                                           bottomTrailingRadius: bottom, topTrailingRadius: Design.Radius.item, style: .continuous)
        HStack(spacing: CommandBarPanel.textX - CommandBarPanel.iconX - CommandBarPanel.iconWidth) {
            OmniboxIcon(item: item).frame(width: 18, height: 18).frame(width: CommandBarPanel.iconWidth)
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
}

/// A result's icon: a symbol, an image, or the icon a page of that site already showed (typing contacts no site).
struct OmniboxIcon: View {
    @Environment(BrowserEnvironment.self) private var env
    let item: OmniboxItem

    var body: some View {
        switch item.icon {
        case .system(let name):
            Image(systemName: name).foregroundStyle(.secondary)
        case .image(let image):
            Image(nsImage: image).resizable().scaledToFit()
        case .favicon(let url):
            SiteIcon(env.runtime.favicons.image(for: url))
        }
    }
}
