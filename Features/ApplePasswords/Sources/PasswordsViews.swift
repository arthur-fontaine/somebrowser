import BrowserCore
import SwiftUI

/// The AutoFill dropdown under the focused field, styled after Safari's.
struct PasswordsMenu: View {
    let model: PasswordsModel
    let window: BrowserWindowState
    let choose: (PasswordsModel.Row) -> Void

    var body: some View {
        if let field = model.field, model.isMenuVisible {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(model.rows.enumerated()), id: \.element) { index, row in
                    PasswordsRow(row: row, selected: index == model.selection)
                        .contentShape(Rectangle())
                        .onTapGesture { choose(row) }
                        .onHover { if $0 { model.selection = index } }
                }
            }
            .padding(5)
            .frame(width: max(260, min(field.rect.width, 360)), alignment: .leading)
            .glassSurface(in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.separator.opacity(0.5)))
            .shadow(color: .black.opacity(0.18), radius: 12, y: 6)
            .offset(x: field.rect.minX, y: field.rect.maxY + 4)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .top)))
            .animation(.spring(duration: 0.22, bounce: 0.15), value: model.rows)
        }
    }
}

struct PasswordsRow: View {
    let row: PasswordsModel.Row
    let selected: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(selected ? .white : .secondary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                if let subtitle { Text(subtitle).font(.system(size: 11)).foregroundStyle(selected ? .white.opacity(0.8) : .secondary).lineLimit(1) }
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(selected ? .white : .primary)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(selected ? Color.accentColor : .clear))
    }

    var icon: String {
        switch row {
        case .login: "key.fill"
        case .strongPassword: "key.horizontal.fill"
        case .connect: "lock.shield"
        case .openApp: "ellipsis.circle"
        }
    }

    var title: String {
        switch row {
        case .login(let login): login.username.isEmpty ? "Password" : login.username
        case .strongPassword: "Use Strong Password"
        case .connect: "Connect to Passwords…"
        case .openApp: "Passwords…"
        }
    }

    var subtitle: String? {
        switch row {
        case .login(let login): login.sites.first
        case .strongPassword(let password): password
        case .connect: "Enter the code Passwords shows"
        case .openApp: nil
        }
    }
}

/// Pairing: the helper shows a 6-digit code (once per launch); the user types it here.
struct PairingCard: View {
    let model: PasswordsModel
    let window: BrowserWindowState
    let submit: (String) async -> Bool
    let cancel: () -> Void
    @State private var code = ""
    @State private var wrong = false
    @FocusState private var focused: Bool

    var body: some View {
        if model.showPairing && window.isKeyWindow {
            ZStack {
                Color.black.opacity(0.15).ignoresSafeArea().onTapGesture(perform: cancel)
                VStack(spacing: 14) {
                    Image(systemName: "key.icloud.fill").font(.system(size: 34)).foregroundStyle(.tint)
                    Text("Connect to Passwords").font(.headline)
                    content
                }
                .padding(24)
                .frame(width: 320)
                .glassSurface(in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .shadow(color: .black.opacity(0.25), radius: 30, y: 12)
                .modifier(Shake(trigger: wrong))
            }
            .overlayKeyboardFocus("passwords.pairing", in: window)
            .onAppear { focused = true }
        }
    }

    @ViewBuilder var content: some View {
        switch model.state {
        case .unavailable(let reason):
            Text(reason).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button("OK", action: cancel).keyboardShortcut(.defaultAction)
        case .needsCode:
            Text("Enter the verification code shown by Passwords.").font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            TextField("000000", text: $code)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 22, weight: .medium, design: .monospaced))
                .multilineTextAlignment(.center)
                .frame(width: 150)
                .focused($focused)
                .onSubmit { Task { await send() } }
                .onChange(of: code) { if code.count == 6 { Task { await send() } } }
            HStack {
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
                Button("Connect") { Task { await send() } }.keyboardShortcut(.defaultAction).disabled(code.count < 6)
            }
        default:
            ProgressView().controlSize(.small)
        }
    }

    func send() async {
        let ok = await submit(code.filter(\.isNumber))
        code = ""
        if !ok { wrong.toggle() }
    }
}

private struct Shake: ViewModifier, Animatable {
    var trigger: Bool
    @State private var offset: CGFloat = 0
    func body(content: Content) -> some View {
        content.offset(x: offset).onChange(of: trigger) {
            withAnimation(.spring(duration: 0.08)) { offset = 10 }
            withAnimation(.spring(duration: 0.4, bounce: 0.7).delay(0.08)) { offset = 0 }
        }
    }
}
