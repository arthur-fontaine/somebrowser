import BrowserCore
import Foundation
import SwiftUI

/// Brave's ad blocker (adblock-rust, Brave's default lists): network blocking, cosmetic filtering and URL
/// cleaning, per-site off switch, and a creator-friendly mode: sites that declare a way to support them
/// (Web Monetization) keep their ads, while trackers stay blocked everywhere.
public final class AdBlockFeature: BrowserFeature {
    let context: FeatureContext
    let shield = Shield()
    let model = AdBlockModel()
    var store: FilterListStore
    private var updating = false
    /// Cosmetic exceptions of each tab's page (generic hiding must honor them).
    private var exceptions: [ObjectIdentifier: [String]] = [:]

    public init(context: FeatureContext) {
        self.context = context
        store = FilterListStore(directory: context.dataDirectory)
    }

    var usesContentRules: Bool { context.engine.capabilities.contains(.contentRuleLists) && !context.engine.capabilities.contains(.requestBlocking) }

    public func activate() {
        syncSettings()
        for key in ["adblock.enabled", "adblock.supportCreators"] { context.settings.observe(key) { [weak self] _ in self?.syncSettings() } }
        let shield = self.shield
        context.hooks.addRequestFilter { request in shield.verdict(for: request) }
        context.hooks.onContentRuleListFailed = { [weak self] identifier, error in
            guard identifier == "adblock" else { return }
            self?.context.notify("Ad blocking lists couldn't load: \(error.localizedDescription)", systemImage: "exclamationmark.shield")
        }
        context.hooks.addUserScript(UserScript(source: AdBlockScripts.observer, injectionTime: .documentEnd, mainFrameOnly: false, world: .isolated))
        // Generic hiding is applied to the top document; iframes' own cosmetics are a later step.
        context.hooks.handleFrameMessages(named: "adblock.classes") { [weak self] tab, m in
            if m.isMainFrame { self?.genericHide(tab, m.body as? [String: Any] ?? [:]) }
        }
        // Only the top document speaks for its site (an ad iframe must not declare the page creator-friendly).
        context.hooks.handleFrameMessages(named: "adblock.creator") { [weak self] tab, m in
            if m.isMainFrame, let url = tab.state.url { self?.creatorDeclared(on: url) }
        }
        context.events.subscribe(TabNavigated.self) { [weak self] event in self?.navigated(event) }

        context.commands.handle("adblock.toggle-site") { [weak self] inv in self?.toggleSite(in: inv.window) }
        context.commands.handle("adblock.update-lists") { [weak self] _ in self?.updateLists(force: true) }

        let model = self.model, runtime = context.runtime
        context.ui.contribute("site-controls.rows", id: "adblock.site-row", order: 5) { [weak self] window in
            ShieldRow(model: model, site: SiteSettingsStore.site(for: runtime.selectedTab(in: window)?.live?.url),
                      blocked: { self?.shield.blockedCount(for: $0) ?? 0 }, toggle: { self?.toggleSite(in: window) })
        }

        // Cached engines load off the main thread; lists are fetched only once the user browses.
        let store = self.store, rules = usesContentRules
        Task.detached(priority: .utility) { [weak self] in
            guard let engines = store.loadCached(contentRules: rules) else { return }
            await self?.install(engines)
        }
    }

    // MARK: Settings & state

    func syncSettings() {
        shield.configure(enabled: context.settings.bool("adblock.enabled"), supportCreators: context.settings.bool("adblock.supportCreators"),
                         disabledSites: Set(context.runtime.siteSettings.sites(with: "adblock.enabled").filter { $0.value.boolValue == false }.keys),
                         creatorSites: Set(context.runtime.siteSettings.sites(with: "adblock.creator").filter { $0.value.boolValue == true }.keys))
        model.revision += 1
        pushContentRules()
    }

    @MainActor func install(_ engines: FilterListStore.Engines) {
        shield.install(engines)
        model.ready = true
        pushContentRules()
    }

    func pushContentRules() {
        guard usesContentRules else { return }
        let rules = shield.enabled ? shield.contentRules(exceptingSites: shield.disabledSites) : nil
        context.hooks.setContentRuleList(rules, identifier: "adblock")
    }

    func updateLists(force: Bool = false) {
        guard !updating, force || !shield.hasEngines || store.isStale, context.settings.bool("adblock.enabled") else { return }
        updating = true
        let store = self.store, rules = usesContentRules
        Task.detached(priority: .utility) { [weak self] in
            let engines = try? await store.update(contentRules: rules)
            await MainActor.run {
                self?.updating = false
                if let engines { self?.install(engines) }
            }
        }
    }

    // MARK: Pages

    func navigated(_ event: TabNavigated) {
        guard ["http", "https"].contains(event.url.scheme) else { return }
        updateLists()
        guard let tab = context.runtime.tabs.tab(event.tabID)?.engineTab else { return }
        exceptions[ObjectIdentifier(tab)] = nil
        guard context.settings.bool("adblock.cosmetic"), shield.shouldFilter(page: event.url),
              let resources = shield.cosmetic(for: event.url, ads: shield.blocksAds(on: event.url)) else { return }
        exceptions[ObjectIdentifier(tab)] = resources.exceptions
        tab.evaluateJavaScript(AdBlockScripts.inject(selectors: resources.hide_selectors, script: resources.injected_script))
    }

    func genericHide(_ tab: EngineTab, _ body: [String: Any]) {
        guard let url = tab.state.url, shield.shouldFilter(page: url), shield.blocksAds(on: url) else { return }
        let selectors = shield.hiddenSelectors(classes: body["classes"] as? [String] ?? [], ids: body["ids"] as? [String] ?? [],
                                               exceptions: exceptions[ObjectIdentifier(tab)] ?? [])
        if !selectors.isEmpty { tab.evaluateJavaScript(AdBlockScripts.inject(selectors: selectors, script: "")) }
    }

    /// A site declared how to support it: remember it, and let its ads through when the user supports creators.
    func creatorDeclared(on page: URL) {
        guard let site = SiteSettingsStore.site(for: page) else { return }
        guard context.runtime.siteSettings.bool("adblock.creator", for: site) != true else { return }
        context.runtime.siteSettings.set("adblock.creator", .bool(true), for: site)
        syncSettings()
    }

    func toggleSite(in window: BrowserWindowState?) {
        guard let window, let tab = context.runtime.selectedTab(in: window), let site = SiteSettingsStore.site(for: tab.live?.url) else { return }
        let off = context.runtime.siteSettings.bool("adblock.enabled", for: site) == false
        context.runtime.siteSettings.set("adblock.enabled", off ? nil : .bool(false), for: site)
        syncSettings()
        tab.engineTab?.reload(bypassingCache: false)
    }
}

@Observable
final class AdBlockModel {
    var ready = false
    var revision = 0
}

/// What the network thread reads: engines, settings snapshot, counters. Lock-protected.
nonisolated final class Shield: @unchecked Sendable {
    private let lock = NSLock()
    private var ads: AdBlockEngine?
    private var privacy: AdBlockEngine?
    private var rules: String?
    private(set) var enabled = true
    private var supportCreators = true
    private(set) var disabledSites: Set<String> = []
    private var creatorSites: Set<String> = []
    private var blocked: [String: Int] = [:]

    var hasEngines: Bool { lock.withLock { ads != nil } }

    func install(_ engines: FilterListStore.Engines) {
        lock.withLock { (ads, privacy, rules) = (engines.ads, engines.privacy, engines.contentRules) }
    }

    func configure(enabled: Bool, supportCreators: Bool, disabledSites: Set<String>, creatorSites: Set<String>) {
        lock.withLock { (self.enabled, self.supportCreators, self.disabledSites, self.creatorSites) = (enabled, supportCreators, disabledSites, creatorSites) }
    }

    func shouldFilter(page: URL) -> Bool {
        lock.withLock { enabled && !disabledSites.contains(Self.site(page)) }
    }

    func blocksAds(on page: URL) -> Bool {
        lock.withLock { !(supportCreators && creatorSites.contains(Self.site(page))) }
    }

    func verdict(for request: WebRequest) -> RequestVerdict {
        guard ["http", "https"].contains(request.url.scheme) else { return .allow }
        // Navigations are never blocked, only cleaned of tracking parameters (`removeparam`).
        if request.type == .document {
            guard shouldFilter(page: request.url), let privacy = lock.withLock({ privacy }),
                  case .rewrite(let clean) = privacy.check(url: request.url.absoluteString, source: request.url.absoluteString, type: "document")
            else { return .allow }
            return .redirect(clean)
        }
        guard let page = request.documentURL, shouldFilter(page: page) else { return .allow }
        let engines: [AdBlockEngine] = lock.withLock { [privacy] + (blocksAdsLocked(page) ? [ads] : []) }.compactMap { $0 }
        let type = Self.types[request.type] ?? "other"
        for engine in engines {
            switch engine.check(url: request.url.absoluteString, source: page.absoluteString, type: type) {
            case .allow: continue
            case .block, .redirect:
                lock.withLock { blocked[Self.site(page), default: 0] += 1 }
                return .block
            case .rewrite(let url): return .redirect(url)
            }
        }
        return .allow
    }

    private func blocksAdsLocked(_ page: URL) -> Bool { !(supportCreators && creatorSites.contains(Self.site(page))) }

    func cosmetic(for page: URL, ads: Bool) -> AdBlockEngine.Cosmetic? {
        let (adsEngine, privacyEngine) = lock.withLock { (self.ads, self.privacy) }
        guard var result = privacyEngine?.cosmetic(for: page.absoluteString) else { return nil }
        if ads, let more = adsEngine?.cosmetic(for: page.absoluteString) {
            result.hide_selectors += more.hide_selectors
            result.exceptions += more.exceptions
            result.injected_script += more.injected_script
            result.generichide = result.generichide || more.generichide
        }
        return result
    }

    func hiddenSelectors(classes: [String], ids: [String], exceptions: [String]) -> [String] {
        lock.withLock { ads }?.hiddenSelectors(classes: classes, ids: ids, exceptions: exceptions) ?? []
    }

    func blockedCount(for site: String) -> Int { lock.withLock { blocked[site] ?? 0 } }

    /// WebKit rule list, with sites the user turned off excepted.
    func contentRules(exceptingSites sites: Set<String>) -> String? {
        guard let rules = lock.withLock({ rules }), !rules.isEmpty else { return nil }
        guard !sites.isEmpty else { return rules }
        let exception = ["trigger": ["url-filter": ".*", "if-top-url": sites.map { "^https?://([^/]*\\.)?\(NSRegularExpression.escapedPattern(for: $0))[/:]" }],
                         "action": ["type": "ignore-previous-rules"]] as [String: Any]
        guard let data = rules.data(using: .utf8), var list = (try? JSONSerialization.jsonObject(with: data)) as? [Any],
              let out = try? JSONSerialization.data(withJSONObject: { list.append(exception); return list }()) else { return rules }
        return String(decoding: out, as: UTF8.self)
    }

    static func site(_ url: URL) -> String { SiteSettingsStore.site(for: url) ?? url.host ?? "" }

    static let types: [WebRequest.ResourceType: String] = [
        .document: "document", .subdocument: "subdocument", .stylesheet: "stylesheet", .script: "script", .image: "image",
        .font: "font", .xhr: "xmlhttprequest", .media: "media", .websocket: "websocket", .ping: "ping", .other: "other",
    ]
}

/// The "Ad blocking" row in site controls: blocked count and the per-site switch.
struct ShieldRow: View {
    let model: AdBlockModel
    let site: String?
    let blocked: (String) -> Int
    let toggle: () -> Void
    @Environment(BrowserEnvironment.self) private var env

    var body: some View {
        if let site {
            let _ = model.revision
            let on = env.runtime.siteSettings.bool("adblock.enabled", for: site) != false
            HStack {
                Image(systemName: on ? "shield.lefthalf.filled" : "shield.slash").contentTransition(.symbolEffect(.replace)).frame(width: 20)
                VStack(alignment: .leading, spacing: 0) {
                    Text("Ad Blocking")
                    if on { Text("\(blocked(site)) blocked").font(.caption).foregroundStyle(.secondary).contentTransition(.numericText()) }
                }
                Spacer()
                Toggle("", isOn: Binding(get: { on }, set: { _ in toggle() }))
                    .toggleStyle(.switch).labelsHidden().controlSize(.small)
            }
            .padding(.horizontal, 8)
            .frame(height: 36)
        }
    }
}
