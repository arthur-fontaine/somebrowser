import AppKit
import BrowserCore
import WebKit

/// WKWebView-based engine. Features that need per-request blocking use content rule lists instead
/// (adblock-rust can emit Apple's content-blocker format).
public final class WebKitEngine: BrowserEngine {
    public let id = "webkit"
    public let capabilities: EngineCapabilities = [.contentRuleLists, .reparentableViews, .devTools, .multipleViewportsPerWindow]
    public let hooks = EngineHooks()

    let options: [String: SettingValue]
    private(set) var dataStore: WKWebsiteDataStore = .default()
    private var privateStore: WKWebsiteDataStore?
    private var compiledRuleLists: [String: WKContentRuleList] = [:]
    private var liveTabs = NSHashTable<WebKitTab>.weakObjects()

    public init(options: [String: SettingValue]) {
        self.options = options
        hooks.onUserScriptsChanged = { [weak self] in self?.refreshScripts() }
        hooks.onContentRuleListsChanged = { [weak self] in self?.compileRuleLists() }
    }

    public func bootstrap(profileDirectory: URL) throws {
        // A stable identifier per profile so forks with another bundle id keep separate data.
        let id = UUID(uuidString: options["webkit.profile"]?.stringValue ?? "") ?? UUID(uuidString: "5A3E9C2B-6D1F-4B8E-9C4A-1F2E3D4C5B6A")!
        dataStore = WKWebsiteDataStore(forIdentifier: id)
    }

    public func runMainLoop(ready: @escaping () -> Void) {
        DispatchQueue.main.async(execute: ready)
        NSApp.run()
    }

    public func makeViewport(in container: NSView) -> EngineViewport { WebKitViewport(container: container) }

    public func makeTab(_ request: EngineTabRequest) -> EngineTab {
        let tab = WebKitTab(engine: self, configuration: makeConfiguration(isPrivate: request.isPrivate))
        liveTabs.add(tab)
        if let data = request.restorationData {
            tab.webView.interactionState = data
        } else if let url = request.url {
            tab.load(url)
        }
        return tab
    }

    /// Popups must use the configuration WebKit hands us (it carries the opener relationship).
    func adoptPopup(configuration: WKWebViewConfiguration) -> WebKitTab {
        let tab = WebKitTab(engine: self, configuration: configuration)
        liveTabs.add(tab)
        return tab
    }

    public func shutdown(completion: @escaping () -> Void) { completion() }

    // MARK: Configuration

    func makeConfiguration(isPrivate: Bool) -> WKWebViewConfiguration {
        let c = WKWebViewConfiguration()
        if isPrivate {
            if privateStore == nil { privateStore = .nonPersistent() }
            c.websiteDataStore = privateStore!
        } else {
            c.websiteDataStore = dataStore
        }
        c.preferences.isElementFullscreenEnabled = true
        c.preferences.isTextInteractionEnabled = true
        c.allowsAirPlayForMediaPlayback = true
        c.mediaTypesRequiringUserActionForPlayback = []
        c.applicationNameForUserAgent = "Version/26.0 Safari/605.1.15"
        c.preferences.setValue(true, forKey: "developerExtrasEnabled")
        install(scriptsInto: c.userContentController)
        for list in compiledRuleLists.values { c.userContentController.add(list) }
        return c
    }

    private func install(scriptsInto ucc: WKUserContentController, documentStart: (script: String, host: String)? = nil) {
        ucc.removeAllScriptMessageHandlers()
        for world in [WKContentWorld.page, WKContentWorld.defaultClient] {
            ucc.add(ScriptMessageProxy(engine: self), contentWorld: world, name: "browser")
        }
        installScripts(into: ucc, documentStart: documentStart)
    }

    private func installScripts(into ucc: WKUserContentController, documentStart: (script: String, host: String)?) {
        ucc.removeAllUserScripts()
        for world in [WKContentWorld.page, WKContentWorld.defaultClient] {
            ucc.addUserScript(WKUserScript(source: Self.bridgeScript, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: world))
        }
        ucc.addUserScript(WKUserScript(source: Self.pageObserverScript, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .defaultClient))
        for s in hooks.userScripts {
            ucc.addUserScript(WKUserScript(
                source: s.source,
                injectionTime: s.injectionTime == .documentStart ? .atDocumentStart : .atDocumentEnd,
                forMainFrameOnly: s.mainFrameOnly,
                in: s.world == .page ? .page : .defaultClient))
        }
        if let documentStart {
            let host = String(data: (try? JSONEncoder().encode(documentStart.host)) ?? Data(), encoding: .utf8) ?? "\"\""
            ucc.addUserScript(WKUserScript(source: "if (location.hostname === \(host)) {\n\(documentStart.script)\n}",
                                           injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .page))
        }
    }

    /// The tab's scripts again with its navigation's document-start script. WebKit reads user scripts when it creates a
    /// document, so setting them while the navigation is decided applies them to it.
    func setDocumentStartScript(_ script: String?, for url: URL, in tab: WebKitTab) {
        let next = script.map { (script: $0, host: url.host() ?? "") }
        guard tab.documentStartScript?.script != next?.script || tab.documentStartScript?.host != next?.host else { return }
        tab.documentStartScript = next
        installScripts(into: tab.webView.configuration.userContentController, documentStart: next)
    }

    private func refreshScripts() {
        for tab in liveTabs.allObjects {
            install(scriptsInto: tab.webView.configuration.userContentController, documentStart: tab.documentStartScript)
        }
    }

    private func compileRuleLists() {
        let store = WKContentRuleListStore.default()!
        for (identifier, json) in hooks.contentRuleLists {
            store.compileContentRuleList(forIdentifier: identifier, encodedContentRuleList: json) { [weak self] list, error in
                guard let self, let list else {
                    if let error { self?.hooks.onContentRuleListFailed?(identifier, error) }
                    return
                }
                self.compiledRuleLists[identifier] = list
                for tab in self.liveTabs.allObjects { tab.webView.configuration.userContentController.add(list) }
            }
        }
        for (identifier, old) in compiledRuleLists where hooks.contentRuleLists[identifier] == nil {
            compiledRuleLists[identifier] = nil
            for tab in liveTabs.allObjects { tab.webView.configuration.userContentController.remove(old) }
        }
    }

    func handleScriptMessage(_ message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let name = body["name"] as? String,
              let webView = message.webView, let tab = liveTabs.allObjects.first(where: { $0.webView === webView }) else { return }
        if name.hasPrefix("__") { tab.handleInternalMessage(name, body: body["body"]); return }
        hooks.dispatch(name, from: tab, ScriptMessage(body: body["body"] ?? NSNull(), isMainFrame: message.frameInfo.isMainFrame,
                                                      frameURL: message.frameInfo.request.url))
    }

    /// `window.__browser.post(name, body)` in every world.
    static let bridgeScript = """
    (() => {
      if (window.__browser) return;
      const h = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.browser;
      Object.defineProperty(window, '__browser', { value: Object.freeze({
        post(name, body) { try { h && h.postMessage({ name: String(name), body: body === undefined ? null : body }); } catch (e) {} }
      }), configurable: false, enumerable: false });
    })();
    """

    /// Media state, hovered links and favicons — WebKit has no public API for these.
    static let pageObserverScript = """
    (() => {
      const post = (n, b) => window.__browser && window.__browser.post(n, b);
      const media = () => {
        let audio = false, video = false;
        document.querySelectorAll('video, audio').forEach(m => {
          if (!m.paused && !m.ended && m.readyState > 2) {
            if (!m.muted && m.volume > 0) audio = true;
            if (m.tagName === 'VIDEO' && m.videoWidth > 0) video = true;
          }
        });
        post('__media', { audio, video });
      };
      ['play', 'pause', 'ended', 'volumechange', 'emptied'].forEach(e => document.addEventListener(e, media, true));
      let last = null;
      document.addEventListener('mouseover', e => {
        const a = e.target && e.target.closest && e.target.closest('a[href]');
        const href = a ? a.href : null;
        if (href !== last) { last = href; post('__hover', href); }
      }, true);
      const icon = () => {
        const l = document.querySelector('link[rel~="icon"][sizes="32x32"], link[rel~="icon"], link[rel="apple-touch-icon"]');
        post('__favicon', l ? l.href : (location.origin + '/favicon.ico'));
      };
      document.addEventListener('DOMContentLoaded', icon);
    })();
    """
}

/// WKUserContentController retains its handlers; this breaks the engine ↔ controller cycle.
private final class ScriptMessageProxy: NSObject, WKScriptMessageHandler {
    weak var engine: WebKitEngine?
    init(engine: WebKitEngine) { self.engine = engine }
    func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage) {
        engine?.handleScriptMessage(message)
    }
}

extension WebKitEngine: EngineSiteData {
    /// WebKit exposes records but not their size publicly; report nil so the UI shows "Clear" only.
    public func dataSize(for site: String) async -> Int64? { nil }

    public func clearData(for site: String) async {
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        let records = await dataStore.dataRecords(ofTypes: types)
        let matching = records.filter { $0.displayName == site || $0.displayName.hasSuffix("." + site) || site.hasSuffix($0.displayName) }
        await dataStore.removeData(ofTypes: types, for: matching)
    }
}

extension WebKitEngine: EngineFloating {
    public func detachForFloating(_ tab: EngineTab) -> FloatingContent? {
        guard let web = (tab as? WebKitTab)?.webView else { return nil }
        web.removeFromSuperview()
        return .view(web)
    }

    public func reattachAfterFloating(_ tab: EngineTab) {
        (tab as? WebKitTab)?.webView.removeFromSuperview()
    }
}
