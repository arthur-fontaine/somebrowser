import AppKit
import BrowserCore
import CEFBridge
import Foundation

/// Chromium through CEF in Chrome style: full Chrome extensions and `chrome://` pages, each tab hosted
/// in its own frameless page window attached as a child of the browser window (docs/decisions/0002).
public final class CEFEngine: NSObject, BrowserEngine, CEFRuntimeDelegate {
    public static var applicationClass: NSApplication.Type { BrowserCEFApplication.self }

    public let id = "cef-chrome"
    public let capabilities: EngineCapabilities = [.chromeExtensions, .chromeURLs, .requestBlocking, .devTools, .childWindowContent]
    public let hooks = EngineHooks()
    let options: [String: SettingValue]
    private let runtime = CEFRuntime.shared()
    private var downloads: [UInt32: DownloadItem] = [:]

    public init(options: [String: SettingValue]) {
        self.options = options
        super.init()
        hooks.onUserScriptsChanged = { [weak self] in self?.syncScripts() }
    }

    /// Runtime switches that keep Chromium quiet: no Google background services, pings or crash uploads.
    static let privacySwitches: [String: String] = [
        "disable-background-networking": "",
        "disable-component-update": "",
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
        "disable-features": "NativeNotifications,MediaRouter,OptimizationHints,AutofillServerCommunication,Translate",
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
        for (key, value) in options where key.hasPrefix("switch.") {
            switches[String(key.dropFirst(7))] = value.stringValue ?? ""
        }
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

    public func makeTab(_ request: EngineTabRequest) -> EngineTab {
        let page = CEFPage(engine: self)
        page.attach(CEFTab(url: request.url?.absoluteString, delegate: page))
        if request.url == nil { page.attachBlank() }
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

    func syncScripts() {
        let scripts = [Self.pageObserverScript].map { (source: $0, start: true, mainOnly: true) }
            + hooks.userScripts.map { (source: $0.source, start: $0.injectionTime == .documentStart, mainOnly: $0.mainFrameOnly) }
        runtime.userScripts = scripts.map { ["source": $0.source, "documentStart": $0.start, "mainFrameOnly": $0.mainOnly] as [String: Any] }
    }

    // MARK: CEFRuntimeDelegate

    /// IO thread: only touches the lock-protected filter list.
    nonisolated public func cefShouldBlockRequest(_ url: String, firstParty: String?, type: String) -> Bool {
        guard let u = URL(string: url) else { return false }
        let request = WebRequest(url: u, documentURL: firstParty.flatMap(URL.init(string:)),
                                 type: WebRequest.ResourceType(rawValue: type) ?? .other)
        return hooks.evaluate(request) == .block
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
