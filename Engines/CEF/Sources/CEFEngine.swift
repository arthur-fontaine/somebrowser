import AppKit
import BrowserCore
import CEFBridge
import Foundation

/// Chromium through CEF in Chrome style: full Chrome extensions and `chrome://` pages, each tab hosted
/// in its own frameless page window attached as a child of the browser window (docs/decisions/0002).
public final class CEFEngine: NSObject, BrowserEngine, EngineExtensions, CEFRuntimeDelegate {
    public static var applicationClass: NSApplication.Type { BrowserCEFApplication.self }

    public let id = "cef-chrome"
    public let capabilities: EngineCapabilities = [.chromeExtensions, .chromeURLs, .requestBlocking, .devTools, .childWindowContent]
    public let hooks = EngineHooks()
    let options: [String: SettingValue]
    private let runtime = CEFRuntime.shared()
    private var downloads: [UInt32: DownloadItem] = [:]
    private var profile: URL?
    private var profileWatcher: DispatchSourceFileSystemObject?
    private var preferenceStamps: [Date?] = []
    public private(set) var installedExtensions: [BrowserExtension] = []
    public var onExtensionsChanged: (() -> Void)?

    public init(options: [String: SettingValue]) {
        self.options = options
        super.init()
        hooks.onUserScriptsChanged = { [weak self] in self?.syncScripts() }
        hooks.onDefaultSearchChanged = { [weak self] in self?.syncDefaultSearch() }
    }

    static let deadEndpoint = "http://127.0.0.1:9"

    /// Runtime switches that keep Chromium quiet: no Google background services, pings or crash uploads.
    /// Not `disable-background-networking`: it also stops extension updates. Each Google endpoint an idle
    /// profile contacted is switched off by name instead (audit: `--log-net-log=<file>`, see TODO.md).
    static let privacySwitches: [String: String] = [
        "disable-component-update": "",
        "allow-browser-signin": "false",
        // Chromium's own Google endpoints (account checks, AI-mode eligibility, Optimization Guide's component,
        // which ignores disable-component-update) point at a closed local port. Pages on Google sites and
        // Web Store installs/updates use their own URLs and are unaffected.
        "gaia-url": CEFEngine.deadEndpoint,
        "google-base-url": CEFEngine.deadEndpoint,
        "google-apis-url": CEFEngine.deadEndpoint,
        "component-updater": "url-source=\(CEFEngine.deadEndpoint)",
        "disable-domain-reliability": "",
        "disable-breakpad": "",
        "disable-client-side-phishing-detection": "",
        "disable-sync": "",
        "no-pings": "",
        "no-default-browser-check": "",
        "no-first-run": "",
        // Our runtime restores sessions; Chrome must not reopen its own windows at launch.
        "no-startup-window": "",
        "metrics-recording-only": "",
        "disable-search-engine-choice-screen": "",
        "enable-blink-features": "DocumentPictureInPictureCefOptions",
        // Chromium's own notification center instead of asking macOS for notification rights at launch.
        "disable-features": [
            "NativeNotifications", "MediaRouter", "AutofillServerCommunication", "Translate",
            "OptimizationHints", "OptimizationGuideManifestBroker", "OptimizationGuideModelExecution",
            "OnDeviceModelBackgroundDownload", "OnDeviceModelPerformanceParams",
            "NetworkTimeServiceQuerying", "AimServerEligibilityEnabled", "AimServerRequestOnStartupEnabled",
            // The hidden Chrome toolbar would otherwise preload a WebUI renderer for its bubbles.
            "PreloadTopChromeWebUI", "WebUIOmniboxPopup",
            // Chrome's footer under extension pages ("set by …", customize): window chrome pages here don't have.
            "NtpFooter",
        ].joined(separator: ","),
    ]

    /// Chrome's own search engine is never used for the omnibox (search is a feature); it is only enabled (as the
    /// user's engine, see `syncDefaultSearch`) for Chrome UI that searches by itself.
    static let privacyPreferences: [String: Any] = [
        "default_search_provider.enabled": false,
        "search.suggest_enabled": false,
        "alternate_error_pages.enabled": false,
    ]

    public func bootstrap(profileDirectory: URL) throws {
        guard runtime.loadLibrary() else {
            throw NSError(domain: "CEF", code: 1, userInfo: [NSLocalizedDescriptionKey: "Chromium Embedded Framework could not be loaded"])
        }
        try FileManager.default.createDirectory(at: profileDirectory, withIntermediateDirectories: true)
        // Chrome's own session files would reopen stock windows; tabs are restored by the browser runtime.
        try? FileManager.default.removeItem(at: profileDirectory.appendingPathComponent("Default/Sessions"))
        runtime.delegate = self
        syncScripts()
        var switches = Self.privacySwitches
        // Development builds are ad-hoc signed: avoid Keychain prompts for Chromium's cookie key.
        if ProcessInfo.processInfo.environment["BROWSER_REAL_KEYCHAIN"] == nil { switches["use-mock-keychain"] = "" }
        // Printing shows the macOS print panel (with its PDF menu) instead of Chrome's web print preview.
        switches["disable-print-preview"] = ""
        for (key, value) in options where key.hasPrefix("switch.") {
            switches[String(key.dropFirst(7))] = value.stringValue ?? ""
        }
        runtime.profilePreferences = Self.privacyPreferences
        // `chromeToolbar: "none"` (engine option) drops the hidden toolbar: no extension actions, slightly less memory.
        runtime.extensionToolbar = options["chromeToolbar"]?.stringValue != "none"
        let profile = profileDirectory.appendingPathComponent("Default", isDirectory: true)
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
        self.profile = profile
        reloadExtensions()
        watchProfile(profile)
        try runtime.initialize(withRootCachePath: profileDirectory.path, switches: switches)
    }

    public func runMainLoop(ready: @escaping () -> Void) {
        DispatchQueue.main.async(execute: ready)
        runtime.runMessageLoop()
        // CefQuitMessageLoop was called from shutdown: clean up and leave (NSApp is waiting on terminateLater).
        runtime.shutdown()
        exit(0)
    }

    public func makeViewport(in container: NSView) -> EngineViewport { CEFViewport(container: container) }

    /// Chrome rewrites its preference files (atomically, by rename) when extensions change.
    private func watchProfile(_ profile: URL) {
        let fd = open(profile.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: .main)
        var pending = false
        source.setEventHandler { [weak self] in
            guard !pending else { return }
            pending = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { pending = false; self?.reloadExtensions() }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        profileWatcher = source
    }

    private func reloadExtensions() {
        guard let profile else { return }
        // The directory also churns with SQLite journals: only re-read when a preference file was replaced.
        let stamps = ["Preferences", "Secure Preferences"].map {
            (try? FileManager.default.attributesOfItem(atPath: profile.appendingPathComponent($0).path)[.modificationDate]) as? Date
        }
        guard stamps != preferenceStamps else { return }
        preferenceStamps = stamps
        let list = ChromiumExtensions.read(profile: profile)
        guard list != installedExtensions else { return }
        installedExtensions = list
        runtime.extensionToolbarWidth = Int32(Self.toolbarWidth(pinned: list.filter(\.isPinned).count))
        onExtensionsChanged?()
    }

    /// Wide enough for every pinned action, so Chrome doesn't overflow them into its menu.
    static func toolbarWidth(pinned: Int) -> Int { 560 + 40 * pinned }

    public func makeTab(_ request: EngineTabRequest) -> EngineTab {
        let page = CEFPage(engine: self)
        let restored = request.restorationData.flatMap(RestoredHistory.decode)
        let url = restored?.current.url ?? request.url
        if let restored {
            page.restored = restored.history
            page.restoring = restored.current
        }
        page.attach(CEFTab(url: url?.absoluteString, delegate: page))
        if url == nil { page.attachBlank() }
        return page
    }

    /// Closes every browser, then leaves CefRunMessageLoop; `runMainLoop` finishes with CefShutdown + exit.
    /// AppKit's own termination is cancelled because its terminate-later wait would keep the loop alive
    /// (and does not drain the main dispatch queue, so this runs synchronously on the main thread).
    public func shutdown(completion: @escaping () -> Void) {
        runtime.closeAllBrowsers { [weak self] in
            NSApp.reply(toApplicationShouldTerminate: false)
            self?.runtime.quitMessageLoop()
        }
    }

    // MARK: EngineExtensions

    @discardableResult public func runAction(of extensionID: String, in tab: EngineTab) -> Bool {
        guard runtime.extensionToolbar, let cefTab = (tab as? CEFPage)?.tab,
              let ext = installedExtensions.first(where: { $0.id == extensionID }) else { return false }
        cefTab.runExtensionActionNamed(ext.name) { _ in }
        return true
    }

    @discardableResult public func showExtensionsMenu(in tab: EngineTab) -> Bool {
        (tab as? CEFPage)?.tab?.showExtensionsMenu() ?? false
    }

    /// Chrome's default search follows the user's engine, for "Search … for" in the context menu. No suggestion URL,
    /// favicon or preconnect: Chrome never contacts the engine on its own.
    func syncDefaultSearch() {
        guard let search = hooks.defaultSearch, let host = URL(string: search.template.replacingOccurrences(of: "%s", with: "q"))?.host() else {
            runtime.setProfilePreference("default_search_provider.enabled", value: false)
            return
        }
        runtime.setProfilePreference("default_search_provider_data.template_url_data", value: Self.templateURLData(name: search.name, keyword: host,
                                     url: search.template.replacingOccurrences(of: "%s", with: "{searchTerms}")))
        runtime.setProfilePreference("default_search_provider.enabled", value: true)
    }

    /// Chrome's TemplateURLData dictionary (components/search_engines/template_url_data_util.cc).
    static func templateURLData(name: String, keyword: String, url: String) -> [String: Any] {
        ["short_name": name, "keyword": keyword, "url": url, "suggestions_url": "", "favicon_url": "", "safe_for_autoreplace": false,
         "prepopulate_id": 0, "input_encodings": ["UTF-8"], "alternate_urls": [String](), "sync_guid": "default-search-\(keyword)",
         "preconnect_to_search_url": false, "prefetch_likely_navigations": false, "is_active": 1]
    }

    func syncScripts() {
        let scripts = [Self.pageObserverScript].map { (source: $0, start: true, mainOnly: true) }
            + hooks.userScripts.map { (source: $0.source, start: $0.injectionTime == .documentStart, mainOnly: $0.mainFrameOnly) }
        runtime.userScripts = scripts.map { ["source": $0.source, "documentStart": $0.start, "mainFrameOnly": $0.mainOnly] as [String: Any] }
    }

    // MARK: CEFRuntimeDelegate

    /// IO thread: only touches the lock-protected filter list.
    nonisolated public func cefFilterRequest(_ url: String, firstParty: String?, type: String) -> String? {
        guard let u = URL(string: url) else { return nil }
        let request = WebRequest(url: u, documentURL: firstParty.flatMap(URL.init(string:)),
                                 type: WebRequest.ResourceType(rawValue: type) ?? .other)
        switch hooks.evaluate(request) {
        case .allow: return nil
        case .block: return ""
        case .redirect(let target): return target == u ? nil : target.absoluteString
        case .respond(let mimeType, let body): return "data:\(mimeType);base64,\(body.base64EncodedString())"  // served by the bridge
        }
    }

    public func cefDownloadPath(forSuggestedName name: String, url: String?) -> String? {
        let source = url.flatMap(URL.init(string:))
        let item = DownloadItem(sourceURL: source, suggestedFilename: name)
        let dest = hooks.downloadDestination?(source, name) ?? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0].appendingPathComponent(name)
        item.destination = dest
        pendingDownload = item
        return dest.path
    }

    private var pendingDownload: DownloadItem?

    public func cefDownload(_ identifier: UInt32, url: String, path: String?, received: Int64, total: Int64, complete: Bool, canceled: Bool) {
        let item: DownloadItem
        if let existing = downloads[identifier] {
            item = existing
        } else {
            item = pendingDownload ?? DownloadItem(sourceURL: URL(string: url), suggestedFilename: path.map { ($0 as NSString).lastPathComponent } ?? "download")
            pendingDownload = nil
            item.cancel = { [weak self] in self?.runtime.cancelDownload(identifier) }
            downloads[identifier] = item
            hooks.emit(.started(item))
        }
        if let path { item.destination = URL(fileURLWithPath: path) }
        item.receivedBytes = received
        item.totalBytes = total
        if canceled {
            item.error = "Canceled"
            downloads[identifier] = nil
            hooks.emit(.failed(item, "Canceled"))
        } else if complete {
            item.isFinished = true
            downloads[identifier] = nil
            hooks.emit(.finished(item))
        } else {
            hooks.emit(.progress(item))
        }
    }

    public func cefChromeOpenedURL(_ url: String) {
        if Self.adoptsChromeOpenedURL(url), let u = URL(string: url) { hooks.onEngineOpenedURL?(u) }
    }

    /// Chrome opens its new-tab page when it wants a tabbed window for its own UI (e.g. the "extension
    /// installed" bubble after a Web Store install), not because the user asked for a page.
    static func adoptsChromeOpenedURL(_ url: String) -> Bool {
        guard let u = URL(string: url), u.scheme == "chrome" else { return true }
        return !["newtab", "new-tab-page", "new-tab-page-third-party"].contains(u.host ?? "")
    }

    /// Same page observer as the WebKit engine: media state, hovered links (CEF has no audible callback).
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
    })();
    """
}

extension CEFEngine: EngineFloating {
    /// The page keeps its own window; it leaves the browser window and the caller restyles it.
    public func detachForFloating(_ tab: EngineTab) -> FloatingContent? {
        guard let page = tab as? CEFPage, let w = page.window else { return nil }
        w.parent?.removeChildWindow(w)
        return .window(w)
    }

    public func reattachAfterFloating(_ tab: EngineTab) {
        guard let page = tab as? CEFPage, let w = page.window else { return }
        w.parent?.removeChildWindow(w)
        w.level = .normal
        w.collectionBehavior = [.fullScreenAuxiliary]
        w.orderOut(nil)
    }
}
