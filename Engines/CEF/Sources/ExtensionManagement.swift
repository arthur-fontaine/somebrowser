import BrowserCore
import CEFBridge
import Foundation

/// Chrome's extensions page (`chrome://extensions`), never shown: the browser's Extensions panel reads and changes
/// extensions through Chrome's own management API there (`chrome.developerPrivate`, `chrome.management`), as that page
/// does. Its window is ordered in off screen, so the dialogs Chrome parents to it (confirming a removal) show, and go to
/// the browser's own dialog (`ChromeDialogs`). Opened when asked, closed after a minute unused (a WebUI renderer while
/// open). It contacts nobody (checked with the net log).
@MainActor
final class ExtensionManagement: EngineTabDelegate {
    private weak var engine: CEFEngine?
    private(set) var page: CEFPage?
    private var loaded = false
    private var waiting: [String] = []
    private var replies: [Int: (Any?) -> Void] = [:]
    private var nextID = 1
    private var idle: Timer?
    var idleTimeout: TimeInterval = 60

    init(engine: CEFEngine) { self.engine = engine }

    /// Runs `body` in Chrome's extensions page, where `reply(value)` answers and `fail(error)` answers `["error": …]`.
    func call(_ body: String, reply: ((Any?) -> Void)? = nil) {
        let id = nextID
        nextID += 1
        if let reply { replies[id] = reply }
        let script = """
            (() => { const reply = r => __browser.post('__management', { id: \(id), r: r === undefined ? null : r });
              const fail = e => reply({ error: String(e && e.message || e) });
              try { \(body) } catch (e) { fail(e) } return 1 })()
            """
        if loaded, let page { page.evaluateJavaScript(script, completion: nil) } else { waiting.append(script); open() }
        keepAlive()
    }

    /// A reply from the page (only this page's: others' messages never get here).
    func received(_ body: Any) {
        guard let d = body as? [String: Any], let id = d["id"] as? Int, let reply = replies.removeValue(forKey: id) else { return }
        reply(d["r"] is NSNull ? nil : d["r"])
    }

    private func open() {
        guard page == nil, let engine else { return }
        let page = CEFPage(engine: engine)
        page.delegate = self
        page.attach(CEFTab(utilityWithURL: "chrome://extensions/", delegate: page))
        self.page = page
    }

    private func keepAlive() {
        idle?.invalidate()
        idle = Timer.scheduledTimer(withTimeInterval: idleTimeout, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }
    }

    func close() {
        idle?.invalidate()
        page?.close()
        page = nil
        loaded = false
        waiting.removeAll()
        replies.removeAll()  // a late answer finds nothing
    }

    // MARK: EngineTabDelegate

    func engineTabDidFinishLoad(_ tab: EngineTab) {
        guard tab === page, !loaded else { return }
        loaded = true
        let scripts = waiting
        waiting.removeAll()
        for script in scripts { page?.evaluateJavaScript(script, completion: nil) }
    }

    func engineTab(_ tab: EngineTab, didOpen newTab: EngineTab, url: URL?, disposition: OpenDisposition, userGesture: Bool) {
        newTab.close()
    }

    func engineTabDidCrash(_ tab: EngineTab) { close() }

    // MARK: Operations

    static func literal(_ value: Any) -> String {
        (try? JSONSerialization.data(withJSONObject: [value], options: [.fragmentsAllowed]))
            .flatMap { String(data: $0, encoding: .utf8) }.map { String($0.dropFirst().dropLast()) } ?? "null"
    }

    func details(of id: String, completion: @escaping (ExtensionDetails?) -> Void) {
        call("""
            chrome.developerPrivate.getExtensionInfo(\(Self.literal(id))).then(e => reply({
              version: e.version, summary: e.description, enabled: e.state === 'ENABLED',
              siteAccess: e.permissions.runtimeHostPermissions ? e.permissions.runtimeHostPermissions.hostAccess : null,
              permissions: e.permissions.simplePermissions.map(p => p.message),
              allowedInPrivate: e.incognitoAccess.isActive, modifiable: e.userMayModify && !e.mustRemainInstalled }), fail)
            """) { value in
            guard let d = value as? [String: Any], d["error"] == nil else { return completion(nil) }
            completion(ExtensionDetails(id: id, version: d["version"] as? String ?? "", summary: d["summary"] as? String ?? "",
                                        isEnabled: d["enabled"] as? Bool ?? false,
                                        siteAccess: (d["siteAccess"] as? String).flatMap(ExtensionDetails.SiteAccess.init(rawValue:)),
                                        permissions: d["permissions"] as? [String] ?? [],
                                        allowedInPrivate: d["allowedInPrivate"] as? Bool ?? false,
                                        isUserModifiable: d["modifiable"] as? Bool ?? false))
        }
    }

    func setEnabled(_ id: String, _ enabled: Bool, done: @escaping (Bool) -> Void) {
        call("chrome.management.setEnabled(\(Self.literal(id)), \(enabled)).then(() => reply(true), fail)") { done($0 as? Bool == true) }
    }

    func setSiteAccess(_ id: String, _ access: ExtensionDetails.SiteAccess) {
        call("chrome.developerPrivate.updateExtensionConfiguration({ extensionId: \(Self.literal(id)), hostAccess: '\(access.rawValue)' }).then(() => reply(true), fail)")
    }

    func setAllowedInPrivate(_ id: String, _ allowed: Bool) {
        call("chrome.developerPrivate.updateExtensionConfiguration({ extensionId: \(Self.literal(id)), incognitoAccess: \(allowed) }).then(() => reply(true), fail)")
    }

    /// Chrome asks to confirm (its dialog, shown as the browser's own); `done(true)` once removed.
    func remove(_ id: String, done: @escaping (Bool) -> Void) {
        call("chrome.developerPrivate.removeMultipleExtensions([\(Self.literal(id))]).then(() => reply(true), fail)") { done($0 as? Bool == true) }
    }
}
