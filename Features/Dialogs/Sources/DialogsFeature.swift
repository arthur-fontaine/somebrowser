import BrowserCore
import SwiftUI

/// Pages' dialogs (alert, confirm, prompt, leaving the page, a site's sign-in) in the browser's own UI, over their tab
/// (Chrome's and WebKit's own dialogs never show). A dialog waits for its tab to be shown; one at a time per tab.
public final class DialogsFeature: BrowserFeature {
    let context: FeatureContext
    let model = DialogsModel()

    public init(context: FeatureContext) { self.context = context }

    public func activate() {
        context.hooks.pageDialog = { [weak self] dialog, answer in self?.model.enqueue(dialog, answer) }
        context.commands.handle("dialogs.accept", isEnabled: { [weak self] in self?.shown(in: $0.window) != nil }) { [weak self] inv in
            guard let self, let pending = self.shown(in: inv.window) else { return }
            let a = inv.arguments
            self.model.answer(pending, PageDialog.Answer(accepted: true, text: a["text"] ?? a["username"] ?? pending.defaultText,
                                                         password: a["password"]))
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
        guard let window, let page = context.runtime.selectedTab(in: window)?.engineTab else { return nil }
        return model.first(for: page)
    }

    private func dropOrphans() {
        let live = Set(context.tabs.allTabs.compactMap { $0.engineTab.map(ObjectIdentifier.init) })
        for pending in model.pending where pending.dialog.tab.map({ !live.contains(ObjectIdentifier($0)) }) ?? true {
            model.answer(pending, PageDialog.Answer(accepted: false))
        }
    }
}

final class PendingDialog: Identifiable {
    let id = UUID()
    let dialog: PageDialog
    let reply: (PageDialog.Answer) -> Void

    init(_ dialog: PageDialog, _ reply: @escaping (PageDialog.Answer) -> Void) {
        self.dialog = dialog
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

    func enqueue(_ dialog: PageDialog, _ reply: @escaping (PageDialog.Answer) -> Void) {
        pending.append(PendingDialog(dialog, reply))
    }

    func first(for page: EngineTab) -> PendingDialog? {
        pending.first { $0.dialog.tab === page }
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
        if let page = runtime.selectedTab(in: window)?.engineTab, let pending = model.first(for: page) {
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
                if dialog.kind != .alert {
                    Button(cancelTitle) { answer(PageDialog.Answer(accepted: false)) }
                        .keyboardShortcut(.cancelAction)
                }
                Button(acceptTitle) { answer(PageDialog.Answer(accepted: true, text: text, password: password)) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.glassProminent)
            }
        }
        .padding(18)
        .frame(width: 400)
        .glassSurface(in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .onAppear {
            text = pending.defaultText ?? ""
            focused = true
        }
        .onExitCommand { if dialog.kind != .alert { answer(PageDialog.Answer(accepted: false)) } else { answer(PageDialog.Answer(accepted: true)) } }
    }

    private var title: String {
        switch dialog.kind {
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
