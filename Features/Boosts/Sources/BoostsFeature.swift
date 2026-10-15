import AppKit
import BrowserCore
import SwiftUI

/// Boosts (Arc): make a site yours. Per site: your CSS (applied before the first paint), your JavaScript (once the page
/// is parsed) and zapped elements (click to hide them on every visit). Stored with the site's settings.
public final class BoostsFeature: BrowserFeature {
    let context: FeatureContext
    let model = BoostsModel()
    static let key = "boosts.boost"
    static let editorFlag = "boosts.editor"
    /// Tabs in zap mode: only they may add zapped elements (any page can post the message).
    private var zapping: Set<ObjectIdentifier> = []

    public init(context: FeatureContext) {
        self.context = context
    }

    public func activate() {
        context.hooks.addDocumentStartScript { [weak self] url in self?.boost(for: url)?.documentStartScript }
        context.hooks.handleFrameMessages(named: "boosts.zap") { [weak self] page, message in
            guard let self, message.isMainFrame, self.zapping.contains(ObjectIdentifier(page)),
                  let selector = (message.body as? [String: Any])?["selector"] as? String, !selector.isEmpty,
                  let site = SiteSettingsStore.site(for: page.state.url) else { return }
            var boost = self.boost(site: site) ?? Boost()
            if !boost.zapped.contains(selector) { boost.zapped.append(selector) }
            self.save(boost, site: site)
        }
        context.hooks.handleFrameMessages(named: "boosts.zap-end") { [weak self] page, _ in self?.zapping.remove(ObjectIdentifier(page)) }
        context.events.subscribe(TabNavigated.self) { [weak self] e in
            if let page = self?.context.tabs.tab(e.tabID)?.engineTab { self?.zapping.remove(ObjectIdentifier(page)) }
        }

        let runtime = context.runtime
        let hasPage = { (inv: CommandInvocation) in inv.window.flatMap { runtime.selectedTab(in: $0)?.engineTab } != nil }
        context.commands.handle("boosts.edit", isEnabled: hasPage) { [weak self] inv in self?.edit(in: inv.window) }
        context.commands.handle("boosts.zap", isEnabled: hasPage) { [weak self] inv in self?.zap(in: inv.window) }
        context.commands.handle("boosts.toggle-site", isEnabled: { [weak self] inv in
            guard let self, let site = self.site(in: inv.window) else { return false }
            return self.boost(site: site) != nil
        }) { [weak self] inv in self?.toggle(in: inv.window) }

        let model = self.model
        context.ui.contribute("site-controls.rows", id: "boosts.row", order: 7) { [weak self] window in
            BoostRow(model: model, site: self?.site(in: window), boost: { self?.boost(site: $0) },
                     toggle: { self?.toggle(in: window) }, edit: { self?.edit(in: window) })
        }
        context.ui.contribute(.overlay, id: "boosts.editor", order: 88) { [weak self] window in
            BoostEditor(model: model, window: window, save: { self?.saveDraft(in: window) },
                        zap: { self?.zap(in: window) }, close: { window.flags.remove(Self.editorFlag) })
        }
    }

    // MARK: Storage

    func boost(site: String) -> Boost? {
        guard case .string(let json)? = context.runtime.siteSettings.value(Self.key, for: site) else { return nil }
        return try? JSONDecoder().decode(Boost.self, from: Data(json.utf8))
    }

    func boost(for url: URL) -> Boost? {
        guard ["http", "https"].contains(url.scheme), let site = SiteSettingsStore.site(for: url) else { return nil }
        return boost(site: site)
    }

    func save(_ boost: Boost, site: String) {
        let json = boost.isEmpty ? nil : (try? JSONEncoder().encode(boost)).map { String(decoding: $0, as: UTF8.self) }
        context.runtime.siteSettings.set(Self.key, json.map { .string($0) }, for: site)
        model.revision += 1
    }

    func site(in window: BrowserWindowState?) -> String? {
        guard let window, let url = context.runtime.selectedTab(in: window)?.live?.url, ["http", "https"].contains(url.scheme) else { return nil }
        return SiteSettingsStore.site(for: url)
    }

    // MARK: Actions

    func edit(in window: BrowserWindowState?) {
        guard let window, let site = site(in: window) else { return }
        model.site = site
        model.draft = boost(site: site) ?? Boost()
        model.error = nil
        window.flags.insert(Self.editorFlag)
    }

    /// Saves the editor's Boost and reloads the page so it applies from the start.
    func saveDraft(in window: BrowserWindowState) {
        guard let site = model.site else { return }
        if let error = Boost.syntaxError(in: model.draft.js) {
            model.error = "JavaScript: \(error)"
            return
        }
        save(model.draft, site: site)
        window.flags.remove(Self.editorFlag)
        context.runtime.selectedTab(in: window)?.engineTab?.reload(bypassingCache: false)
    }

    func toggle(in window: BrowserWindowState?) {
        guard let site = site(in: window), var boost = boost(site: site) else { return }
        boost.enabled.toggle()
        save(boost, site: site)
        context.notify(boost.enabled ? "Boost on for \(site)" : "Boost off for \(site)", systemImage: "paintbrush", window: window)
        window.flatMap { context.runtime.selectedTab(in: $0)?.engineTab }?.reload(bypassingCache: false)
    }

    func zap(in window: BrowserWindowState?) {
        guard let window, let page = context.runtime.selectedTab(in: window)?.engineTab else { return }
        window.flags.remove(Self.editorFlag)
        zapping.insert(ObjectIdentifier(page))
        page.evaluateJavaScript(ZapScript.start, completion: nil)
        context.notify("Click elements to zap them · Esc when done", systemImage: "bolt", window: window)
    }
}

@Observable
final class BoostsModel {
    var site: String?
    var draft = Boost()
    var error: String?
    /// Bumped when a Boost changes, for the site-controls row.
    var revision = 0
}
