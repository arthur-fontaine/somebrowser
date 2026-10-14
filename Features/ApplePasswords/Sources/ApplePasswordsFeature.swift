import AppKit
import BrowserCore
import Security
import SwiftUI

/// Apple Passwords as the browser's password manager (Radian, 08-18 / 08-27): an AutoFill dropdown on login
/// fields, macOS's own Touch ID prompt before filling, "Use Strong Password" from Apple's generator, and the
/// native "Save Password?" sheet. Everything goes through Apple's helper (see `PasswordsClient`).
public final class ApplePasswordsFeature: BrowserFeature {
    let context: FeatureContext
    let model = PasswordsModel()
    let client: PasswordsClient
    /// Strong passwords we filled, per host, saved when their form is submitted.
    var generated: [String: String] = [:]

    public convenience init(context: FeatureContext) {
        self.init(context: context, client: PasswordsClient())
    }

    init(context: FeatureContext, client: PasswordsClient) {
        self.context = context
        self.client = client
    }

    public func activate() {
        guard context.settings.bool("passwords.enabled") else { return }
        model.state = client.state
        client.onStateChange = { [weak self] in self?.model.state = $0 }
        context.hooks.addUserScript(UserScript(source: PasswordsScripts.observer, injectionTime: .documentEnd, mainFrameOnly: true, world: .isolated))
        // Any page script can post these: only the top document counts, and the site always comes from the
        // tab's committed URL, never from the message (or evil.example could ask for bank.example's logins).
        context.hooks.handleFrameMessages(named: "passwords.focus") { [weak self] tab, m in
            if m.isMainFrame { self?.focus(tab, m.body as? [String: Any] ?? [:]) }
        }
        context.hooks.handleFrameMessages(named: "passwords.blur") { [weak self] tab, m in if m.isMainFrame { self?.blur(tab) } }
        context.hooks.handleFrameMessages(named: "passwords.key") { [weak self] tab, m in
            if m.isMainFrame { self?.key(tab, (m.body as? [String: Any])?["key"] as? String) }
        }
        context.hooks.handleFrameMessages(named: "passwords.submit") { [weak self] tab, m in
            if m.isMainFrame { self?.submit(tab, m.body as? [String: Any] ?? [:]) }
        }

        context.commands.handle("passwords.open-app") { _ in Self.openPasswordsApp() }
        context.commands.handle("passwords.connect") { [weak self] _ in self?.model.showPairing = true; Task { await self?.client.connect() } }

        let model = self.model
        context.ui.contribute(.contentOverlay, id: "passwords.menu", order: 40) { [weak self] window in
            PasswordsMenu(model: model, window: window, choose: { self?.choose($0) })
        }
        context.ui.contribute(.overlay, id: "passwords.pairing", order: 95) { [weak self] window in
            PairingCard(model: model, window: window, submit: { code in await self?.pair(code) ?? false }, cancel: { model.showPairing = false })
        }
    }

    // MARK: Page events

    /// The site a tab's page belongs to, from the engine's committed URL.
    static func site(of tab: EngineTab) -> (host: String, origin: String)? {
        guard let url = tab.state.url, url.scheme == "https" || url.scheme == "http", let host = url.host(), !host.isEmpty else { return nil }
        return (host, "\(url.scheme!)://\(host)\(url.port.map { ":\($0)" } ?? "")")
    }

    func focus(_ tab: EngineTab, _ body: [String: Any]) {
        guard let (host, origin) = Self.site(of: tab), let r = body["rect"] as? [String: Any] else { return }
        let n = { (key: String) in (r[key] as? NSNumber)?.doubleValue ?? 0 }
        let rect = CGRect(x: n("x"), y: n("y"), width: n("width"), height: n("height"))
        let kind: PasswordsModel.Field.Kind = body["kind"] as? String == "new" ? .newPassword : .login
        let field = PasswordsModel.Field(tab: ObjectIdentifier(tab), kind: kind, rect: rect.applying(.init(scaleX: tab.zoomFactor, y: tab.zoomFactor)),
                                         host: host, origin: origin)
        model.field = field
        model.logins = []
        model.selection = 0
        model.strongPassword = kind == .newPassword && context.settings.bool("passwords.suggestStrong") ? Self.strongPassword() : nil
        Task { await loadLogins(for: field, tab: tab) }
    }

    func loadLogins(for field: PasswordsModel.Field, tab: EngineTab) async {
        if client.state == .idle { await client.connect() }
        guard client.state == .ready else { syncMenu(tab); return }
        let logins = (try? await client.loginNames(for: field.host)) ?? []
        guard model.field == field else { return }
        model.logins = logins
        syncMenu(tab)
    }

    func blur(_ tab: EngineTab) {
        // Clicking a row blurs the field first: let the click land before closing.
        let field = model.field
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self, self.model.field == field, !self.model.isChoosing else { return }
            self.model.field = nil
            self.syncMenu(tab)
        }
    }

    func key(_ tab: EngineTab, _ key: String?) {
        let rows = model.rows
        switch key {
        case "ArrowDown": model.selection = min(model.selection + 1, max(rows.count - 1, 0))
        case "ArrowUp": model.selection = max(model.selection - 1, 0)
        case "Enter": if rows.indices.contains(model.selection) { choose(rows[model.selection]) }
        case "Escape": model.field = nil; syncMenu(tab)
        default: break
        }
    }

    /// Keeps the page forwarding keys exactly while the menu shows rows.
    func syncMenu(_ tab: EngineTab) {
        tab.evaluateJavaScript(PasswordsScripts.menu(open: model.isMenuVisible))
    }

    func choose(_ row: PasswordsModel.Row) {
        guard let field = model.field, let tab = selectedTab(), ObjectIdentifier(tab) == field.tab else { return }
        model.isChoosing = true
        defer { model.isChoosing = false }
        switch row {
        case .login(let login):
            model.field = nil
            syncMenu(tab)
            Task {
                // The helper shows macOS's "AutoFill for …" prompt (Touch ID or the Mac's password).
                guard let password = try? await client.password(for: login, host: field.host) else { return }
                tab.evaluateJavaScript(PasswordsScripts.fill(username: login.username, password: password, newPassword: false))
            }
        case .strongPassword(let password):
            generated[field.host] = password
            model.field = nil
            syncMenu(tab)
            tab.evaluateJavaScript(PasswordsScripts.fill(username: nil, password: password, newPassword: true))
        case .connect:
            model.field = nil
            syncMenu(tab)
            model.showPairing = true
            if client.state == .idle { Task { await client.connect() } }
        case .openApp:
            Self.openPasswordsApp()
        }
    }

    func submit(_ tab: EngineTab, _ body: [String: Any]) {
        guard context.settings.bool("passwords.offerToSave"), client.state == .ready, let (host, origin) = Self.site(of: tab),
              let password = body["password"] as? String, !password.isEmpty else { return }
        generated[host] = nil
        // The helper decides (already saved? never for this site?) and shows the native "Save Password?" sheet.
        Task { try? await client.save(url: origin, username: body["username"] as? String ?? "", password: password) }
    }

    func pair(_ code: String) async -> Bool {
        do {
            try await client.pair(code: code)
            model.showPairing = false
            return true
        } catch {
            return false
        }
    }

    func selectedTab() -> EngineTab? {
        context.runtime.windows.lazy.compactMap { self.context.runtime.selectedTab(in: $0)?.engineTab }.first { ObjectIdentifier($0) == self.model.field?.tab }
    }

    /// Apple's own strong-password generator ("xxxxxx-xxxxxx-xxxxxx"), as Safari suggests.
    static func strongPassword() -> String? {
        SecCreateSharedWebCredentialPassword() as String?
    }

    static func openPasswordsApp() {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Passwords") {
            NSWorkspace.shared.openApplication(at: url, configuration: .init())
        }
    }
}

@Observable
final class PasswordsModel {
    struct Field: Equatable {
        enum Kind { case login, newPassword }
        var tab: ObjectIdentifier
        var kind: Kind
        /// The field in content coordinates (points).
        var rect: CGRect
        var host: String
        var origin: String
    }

    enum Row: Hashable {
        case login(PasswordsLogin)
        case strongPassword(String)
        case connect
        case openApp
    }

    var state: PasswordsClient.State = .idle
    var field: Field?
    var logins: [PasswordsLogin] = []
    var strongPassword: String?
    var selection = 0
    var isChoosing = false
    var showPairing = false

    var rows: [Row] {
        guard field != nil else { return [] }
        if state == .needsCode { return [.connect] }
        guard state == .ready else { return [] }
        var rows: [Row] = strongPassword.map { [.strongPassword($0)] } ?? []
        rows += logins.map { .login($0) }
        return rows.isEmpty ? [] : rows + [.openApp]
    }

    var isMenuVisible: Bool { !rows.isEmpty }
}

extension PasswordsLogin: Hashable {
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}
