import BrowserCore
import SwiftUI

/// Pages' dialogs (alert, confirm, prompt, leaving the page, a site's sign-in) and the engine's own (Chrome's extension
/// prompts) in the browser's own UI, over their tab (Chrome's and WebKit's own dialogs never show). A dialog waits for
/// its tab to be shown; one at a time per tab. The engine's go over the page in front when they come.
public final class DialogsFeature: BrowserFeature {
    let context: FeatureContext
    let model = DialogsModel()

    public init(context: FeatureContext) { self.context = context }

    public func activate() {
        context.hooks.pageDialog = { [weak self] dialog, answer in
            guard let self else { return }
            let page = dialog.tab ?? context.runtime.keyWindow.flatMap { context.runtime.selectedTab(in: $0)?.engineTab }
            self.model.enqueue(dialog, over: page, answer)
        }
        context.commands.handle("dialogs.accept", isEnabled: { [weak self] in self?.shown(in: $0.window) != nil }) { [weak self] inv in
            guard let self, let pending = self.shown(in: inv.window) else { return }
            let a = inv.arguments
            self.model.answer(pending, PageDialog.Answer(accepted: true, text: a["text"] ?? a["username"] ?? pending.defaultText,
                                                         password: a["password"], button: a["button"].flatMap { Int($0) }))
        }
        context.commands.handle("dialogs.cancel", isEnabled: { [weak self] in self?.shown(in: $0.window) != nil }) { [weak self] inv in
            guard let self, let pending = self.shown(in: inv.window) else { return }
            self.model.answer(pending, PageDialog.Answer(accepted: false))
        }
        // A page gone (tab closed, page replaced) answers its dialogs: no.
        context.events.subscribe(TabLiveChanged.self) { [weak self] _ in self?.dropOrphans() }
        context.events.subscribe(TabsClosed.self) { [weak self] _ in self?.dropOrphans() }

        let model = self.model, runtime = context.runtime
        context.ui.contribute(.contentOverlay, id: "dialogs.page", order: 20) { window in
            PageDialogView(model: model, window: window, runtime: runtime)
        }
    }

    /// The dialog over the window's selected page, if it has one.
    func shown(in window: BrowserWindowState?) -> PendingDialog? {
        guard let window else { return nil }
        return model.first(for: context.runtime.selectedTab(in: window)?.engineTab)
    }

    private func dropOrphans() {
        let live = Set(context.tabs.allTabs.compactMap { $0.engineTab.map(ObjectIdentifier.init) })
        for pending in model.pending {
            guard let page = pending.page, !live.contains(ObjectIdentifier(page)) else { continue }
            model.answer(pending, PageDialog.Answer(accepted: false))
        }
    }
}

final class PendingDialog: Identifiable {
    let id = UUID()
    let dialog: PageDialog
    /// The page it's over; nil when no page was open (it shows in a window without one).
    weak var page: EngineTab?
    let reply: (PageDialog.Answer) -> Void

    init(_ dialog: PageDialog, over page: EngineTab?, _ reply: @escaping (PageDialog.Answer) -> Void) {
        self.dialog = dialog
        self.page = page
        self.reply = reply
    }

    var defaultText: String? {
        if case .prompt(let text) = dialog.kind { return text }
        return nil
    }
}

@Observable
final class DialogsModel {
    private(set) var pending: [PendingDialog] = []

    func enqueue(_ dialog: PageDialog, over page: EngineTab?, _ reply: @escaping (PageDialog.Answer) -> Void) {
        guard dialog.withdrawal?.isWithdrawn != true else { return }
        let new = PendingDialog(dialog, over: page, reply)
        dialog.withdrawal?.onWithdraw = { [weak self, weak new] in
            guard let self, let new else { return }
            self.pending.removeAll { $0 === new }
        }
        pending.append(new)
    }

    /// The first dialog over `page`; with no page, the first one over none.
    func first(for page: EngineTab?) -> PendingDialog? {
        pending.first { $0.page === page }
    }

    func answer(_ dialog: PendingDialog, _ answer: PageDialog.Answer) {
        guard let i = pending.firstIndex(where: { $0 === dialog }) else { return }
        pending.remove(at: i)
        dialog.reply(answer)
    }
}

// MARK: View

/// A card over the page, below the top of the content (like Safari's), the page dimmed behind it.
struct PageDialogView: View {
    let model: DialogsModel
    let window: BrowserWindowState
    let runtime: BrowserRuntime

    var body: some View {
        if let pending = model.first(for: runtime.selectedTab(in: window)?.engineTab) {
            ZStack(alignment: .top) {
                Color.black.opacity(0.12).contentShape(Rectangle())
                DialogCard(pending: pending) { model.answer(pending, $0) }
                    .id(pending.id)
                    .padding(.top, 48)
                    .overlayKeyboardFocus("dialogs.page", in: window)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            .animation(.spring(duration: 0.28, bounce: 0.1), value: pending.id)
        }
    }
}

struct DialogCard: View {
    let pending: PendingDialog
    let answer: (PageDialog.Answer) -> Void
    @State private var text = ""
    @State private var password = ""
    @FocusState private var focused: Bool

    private var dialog: PageDialog { pending.dialog }
    private var site: String { dialog.origin?.host() ?? dialog.origin?.absoluteString ?? "This page" }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            if !body_.isEmpty {
                Text(body_).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            switch dialog.kind {
            case .prompt:
                TextField("", text: $text).textFieldStyle(.roundedBorder).focused($focused)
            case .signIn:
                TextField("Username", text: $text).textFieldStyle(.roundedBorder).focused($focused)
                SecureField("Password", text: $password).textFieldStyle(.roundedBorder)
            default:
                EmptyView()
            }
            HStack {
                Spacer()
                if case .engine(_, let buttons) = dialog.kind {
                    // In the engine's order: the last one accepts, the first cancels.
                    ForEach(Array(buttons.enumerated()), id: \.offset) { i, title in
                        let button = Button(title) { answer(PageDialog.Answer(accepted: i == buttons.count - 1, button: i)) }
                        if i == buttons.count - 1 {
                            button.keyboardShortcut(.defaultAction).buttonStyle(.glassProminent)
                        } else {
                            button.keyboardShortcut(i == 0 ? .cancelAction : nil)
                        }
                    }
                } else {
                    if dialog.kind != .alert {
                        Button(cancelTitle) { answer(PageDialog.Answer(accepted: false)) }
                            .keyboardShortcut(.cancelAction)
                    }
                    Button(acceptTitle) { answer(PageDialog.Answer(accepted: true, text: text, password: password)) }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.glassProminent)
                }
            }
        }
        .padding(18)
        .frame(width: 400)
        .glassSurface(in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .onAppear {
            text = pending.defaultText ?? ""
            focused = true
        }
        .onExitCommand { answer(PageDialog.Answer(accepted: dialog.kind == .alert || isSingleButton)) }
    }

    private var isSingleButton: Bool {
        if case .engine(_, let buttons) = dialog.kind { return buttons.count < 2 }
        return false
    }

    private var title: String {
        switch dialog.kind {
        case .engine(let title, _): title
        case .leavePage(let isReload): isReload ? "Reload this page?" : "Leave this page?"
        case .signIn(let host, _, let isProxy): isProxy ? "Sign in to the proxy \\(host)" : "Sign in to \\(host)"
        default: "\\(site) says"
        }
    }

    private var body_: String {
        switch dialog.kind {
        case .leavePage: "Changes you made may not be saved."
        case .signIn(_, let realm, _): realm.isEmpty ? "" : "“\\(realm)”"
        default: dialog.message
        }
    }

    private var acceptTitle: String {
        switch dialog.kind {
        case .leavePage(let isReload): isReload ? "Reload" : "Leave"
        case .signIn: "Sign In"
        default: "OK"
        }
    }

    private var cancelTitle: String {
        if case .leavePage = dialog.kind { return "Stay" }
        return "Cancel"
    }
}
