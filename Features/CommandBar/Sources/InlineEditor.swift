import AppKit
import BrowserCore
import SwiftUI

/// The `inline` style: the sidebar's address field grows into one glass panel, as Spotlight's bar grows into its results
/// (the field's rounded ends become the panel's corners), its top-left held and wide enough over the page for addresses.
/// The results sit under a hairline on the sidebar's grid. It is drawn in the overlay, above the page, at the frame the
/// field publishes; the field hides under it while it's open.
struct InlineEditor: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let window: BrowserWindowState
    let model: CommandBarModel
    @State private var visible = false
    @State private var expanded = false
    @State private var rowsShown = false
    /// The expanded editor's denser tint, arriving with its growth.
    @State private var tinted = false
    /// The last results and text, still drawn while the panel folds away (the session is gone by then).
    @State private var shownItems: [OmniboxItem] = []
    @State private var shownQuery = ""
    @FocusState private var focused: Bool
    @State private var editorFit = FieldEditorFit()

    static let width: CGFloat = 480
    static let radius = Design.Size.control / 2
    /// Rows sit this far inside the panel, so their corners are concentric with it.
    static let rowInset: CGFloat = 4
    static let maxRows = 8

    static func curve(_ duration: Double) -> Animation { .timingCurve(0.2, 0.8, 0.2, 1, duration: duration) }

    private var editing: Bool {
        window.flags.contains(CommandBarModel.flag) && model.session(window)?.style == .inline && window.addressFieldFrame != .zero
    }

    var body: some View {
        let editing = self.editing
        let items = editing ? Array(model.items(for: window).prefix(Self.maxRows)) : shownItems
        GeometryReader { geo in
            let field = window.addressFieldFrame
            let width = expanded ? min(max(field.width, Self.width), geo.size.width - Design.windowInset - field.minX) : field.width
            let shape = RoundedRectangle(cornerRadius: Self.radius, style: .continuous)
            // One rectangle, width and height together; the results are laid out at full size and revealed by the clip.
            let height = Design.Size.control + (expanded ? Self.resultsHeight(items) : 0)
            VStack(spacing: 0) {
                fieldRow
                if !items.isEmpty { results(items) }
            }
            .frame(width: max(width, 0), height: height, alignment: .top)
            .clipShape(shape)
            // Expanded, a menu's denser material, so it reads as one surface over the sidebar and the page alike.
            .background(Color(nsColor: .windowBackgroundColor).opacity(tinted ? 0.65 : 0), in: shape)
            .background(Design.Fill.glassScrim.opacity(tinted ? 1 : 0), in: shape)
            // Collapsed, exactly the field's surface (its interactive glass, no tint), so the hand-overs don't show.
            .glassControl(in: shape, hover: false)
            .background { if editing { ClickOutside { model.close(window) } } }
            .shadow(color: .black.opacity(expanded ? 0.22 : 0), radius: 24, y: 10)
            .offset(x: field.minX, y: field.minY)
            // Whole from its first frame (on the field, which hides a frame later): no hole, no see-through.
            .opacity(visible ? 1 : 0)
            .allowsHitTesting(editing)
        }
        .ignoresSafeArea()
        .overlayKeyboardFocus("command-bar.inline", in: window, isEnabled: editing)
        .holdsSidebarPeek("command-bar.inline", in: window, isEnabled: editing)
        .onChange(of: editing) { present(editing) }
        .onChange(of: model.session(window)?.query) { if let q = model.session(window)?.query { shownQuery = q } }
        .onChange(of: items.map(\.id)) {
            guard editing else { return }
            // The height follows the results on the same curve.
            withAnimation(Self.curve(0.2)) { shownItems = items }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            if editing { model.close(window) }
        }
        // For what was typed: a result's text filled in by the arrows keeps the list.
        .task(id: model.session(window)?.typed) {
            guard editing, let q = model.session(window)?.typed, let search = model.search else { return }
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            let list = await search.suggestions(for: q)
            model.setSuggestions(list, for: q, in: window)
        }
    }

    /// Identical to the address field's, so the text doesn't move: icon on the sidebar's icon column, text on its title
    /// column.
    private var fieldRow: some View {
        let query = Binding(get: { model.session(window)?.query ?? shownQuery }, set: { model.setQuery($0, in: window) })
        return HStack(spacing: Design.Grid.iconToText) {
            Image(systemName: "magnifyingglass").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                .frame(width: Design.Size.favicon)
            TextField("Search or enter address", text: query)
                .textFieldStyle(.plain)
                .font(.system(size: 13, weight: .medium))
                .disabled(!editing)  // hidden, it never takes the keyboard
                .focused($focused)
                .onSubmit { model.execute(window, inNewTab: NSEvent.modifierFlags.contains(.option)) }
                .onKeyPress(.downArrow) { model.moveSelection(1, in: window); return .handled }
                .onKeyPress(.upArrow) { model.moveSelection(-1, in: window); return .handled }
                .onKeyPress(.escape) { model.escape(window); return .handled }
                .onKeyPress(.tab) { completeKeyword(query); return .handled }
        }
        .padding(.leading, Design.Grid.iconInset)
        .padding(.trailing, Design.Capsule.trailing)
        .frame(height: Design.Size.control)
    }

    private func results(_ items: [OmniboxItem]) -> some View {
        let selection = model.session(window)?.selection
        return VStack(spacing: 0) {
            Rectangle().fill(Design.Fill.hairline).frame(height: 1).padding(.horizontal, 16)
            VStack(spacing: Design.Space.row) {
                ForEach(Array(items.enumerated()), id: \.element.id) { i, item in
                    InlineRow(item: item, selected: i == selection)
                        .contentShape(Rectangle())
                        .onTapGesture { model.execute(window, index: i) }
                }
            }
            .padding(.horizontal, Self.rowInset)
            .padding(.vertical, Design.Space.block)
        }
        .opacity(rowsShown ? 1 : 0)
        .offset(y: rowsShown ? 0 : -4)
    }

    static func resultsHeight(_ items: [OmniboxItem]) -> CGFloat {
        guard !items.isEmpty else { return 0 }
        let rows: CGFloat = items.reduce(0) { total, item in total + (item.subtitle == nil ? 36 : 44) }
        let gaps: CGFloat = CGFloat(items.count - 1) * Design.Space.row
        let padding: CGFloat = 1 + 2 * Design.Space.block
        return padding + rows + gaps
    }

    /// Opens grown from the field: the frame on Spotlight's curve (0.28 s), the results fading in a beat later; folds
    /// back in 0.22 s, the results gone first, then hands back to the field. Under Reduce Motion, a cross-fade.
    private func present(_ on: Bool) {
        if on {
            // From the floating sidebar, a beat into its slide.
            let delay = model.peeked.contains(window.id) ? 0.12 : 0
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                guard editing else { return }
                var still = Transaction()
                still.disablesAnimations = true
                withTransaction(still) { visible = true }
                // The field stays under the editor (the same shape) until it has grown: hidden any earlier, it could be
                // gone before the overlay's first frame is on screen.
                let hideField = { if editing { window.isEditingAddress = true } }
                withAnimation(.easeOut(duration: 0.2)) { tinted = true }
                if reduceMotion {
                    expanded = true
                    withAnimation(.easeOut(duration: 0.15)) { rowsShown = true } completion: { hideField() }
                } else {
                    withAnimation(Self.curve(0.28)) { expanded = true } completion: { hideField() }
                    withAnimation(.easeOut(duration: 0.14).delay(0.06)) { rowsShown = true }
                }
                DispatchQueue.main.async {
                    focused = true
                    DispatchQueue.main.async { editorFit.start() }  // once the field has its editor
                }
            }
        } else {
            editorFit.stop()
            focused = false
            withAnimation(.easeOut(duration: 0.08)) { rowsShown = false }
            withAnimation(.easeOut(duration: 0.2)) { tinted = false }
            withAnimation(reduceMotion ? .easeOut(duration: 0.1) : Self.curve(0.22)) { expanded = false } completion: {
                guard !editing else { return }
                // The field back under it first, then the editor goes.
                window.isEditingAddress = false
                DispatchQueue.main.async {
                    guard !editing else { return }
                    // A short fade over the field, now back under it in its resting look.
                    withAnimation(.easeOut(duration: 0.12)) { visible = false }
                }
            }
        }
    }

    /// Arc: "yt" + Tab turns into a site search prompt.
    private func completeKeyword(_ query: Binding<String>) {
        let q = query.wrappedValue.trimmingCharacters(in: .whitespaces)
        if !q.isEmpty, !q.contains(" ") { query.wrappedValue = q + " " }
    }
}

/// Keeps the field editor with the keyboard as wide as its text. AppKit narrows it to the field whenever the field is
/// resized (as the editor grows open), and widens it again only as the text changes: in between, a long address
/// couldn't scroll, the caret moving out of sight past its end.
final class FieldEditorFit {
    private weak var editor: NSTextView?
    private var observer: Any?
    private var fitting = false

    func start() {
        stop()
        guard let editor = NSApp.keyWindow?.firstResponder as? NSTextView, editor.isFieldEditor else { return }
        self.editor = editor
        observer = NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: editor, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.fit() }
        }
        fit()
    }

    func stop() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        editor = nil
    }

    private func fit() {
        guard !fitting, let editor else { return }
        fitting = true
        editor.sizeToFit()
        editor.scrollRangeToVisible(NSRange(location: editor.selectedRange().location, length: 0))
        fitting = false
    }
}

/// A result on the sidebar's grid: its icon under the field's, its title under the field's text.
struct InlineRow: View {
    let item: OmniboxItem
    let selected: Bool

    var body: some View {
        HStack(spacing: Design.Grid.iconToText) {
            OmniboxIcon(item: item).frame(width: Design.Size.favicon, height: Design.Size.favicon)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                if let s = item.subtitle { Text(s).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1) }
            }
            Spacer(minLength: 8)
            if let a = item.accessory { Text(a).font(.system(size: 11, design: .rounded)).foregroundStyle(.secondary) }
            Text(item.kind).font(.system(size: 11)).foregroundStyle(.tertiary)
        }
        .padding(.leading, Design.Grid.iconInset - InlineEditor.rowInset)
        .padding(.trailing, 16 - InlineEditor.rowInset)
        .frame(height: item.subtitle == nil ? 36 : 44)
        .background(selected ? Design.Fill.selection : .clear,
                    in: RoundedRectangle(cornerRadius: InlineEditor.radius - InlineEditor.rowInset, style: .continuous))
    }
}

/// Closes the editor on a click anywhere else (the click still goes where it was meant to).
struct ClickOutside: NSViewRepresentable {
    let action: () -> Void

    func makeNSView(context: Context) -> Watcher { Watcher(action: action) }
    func updateNSView(_ view: Watcher, context: Context) { view.action = action }

    final class Watcher: NSView {
        var action: () -> Void
        private var monitor: Any?

        init(action: @escaping () -> Void) {
            self.action = action
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { fatalError() }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
                guard let self else { return event }
                let inside = event.window === self.window && self.bounds.contains(self.convert(event.locationInWindow, from: nil))
                if !inside { self.action() }
                return event
            }
        }

        override func removeFromSuperview() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            super.removeFromSuperview()
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
