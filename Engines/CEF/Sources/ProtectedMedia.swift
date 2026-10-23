import BrowserCore
import Foundation

/// Netflix and other DRM sites on a Mac: Widevine in a custom Chromium needs VMP certification (Netflix refuses
/// uncertified builds), while Apple's FairPlay works in any app's WKWebView. So a page asking for protected media is
/// moved to a WebKit tab, and its site is remembered so the next visits go straight there. Clear Key stays in Chromium.
/// Engine option `protectedMedia`: `webkit` (default), `chromium` (a Widevine build, VMP-signed), `off`.
final class ProtectedMedia {
    enum Mode: String { case webkit, chromium, off }

    let mode: Mode
    private(set) var sites: Set<String>
    private let file: URL?
    /// Sites whose Chromium cookies went to WebKit (see `takeCookies`).
    private var cookiesTaken: Set<String>
    private let cookiesFile: URL?

    /// Streaming services known to need protected media: their pages open in WebKit from the first one, so signing in
    /// happens there and no page ever moves. Hosts, matched with their subdomains.
    static let knownHosts: Set<String> = [
        "netflix.com", "disneyplus.com", "primevideo.com", "max.com", "hbomax.com", "hulu.com", "paramountplus.com",
        "peacocktv.com", "crunchyroll.com", "canalplus.com", "tv.apple.com", "music.apple.com", "open.spotify.com",
    ]

    init(mode: Mode, file: URL?) {
        self.mode = mode
        self.file = file
        cookiesFile = file.map { $0.deletingPathExtension().appendingPathExtension("cookies.json") }
        func load(_ file: URL?) -> Set<String> {
            Set(file.flatMap { try? Data(contentsOf: $0) }.flatMap { try? JSONDecoder().decode([String].self, from: $0) } ?? [])
        }
        sites = load(file)
        cookiesTaken = load(cookiesFile)
    }

    /// Pages of this URL's site play in WebKit.
    func needsWebKit(_ url: URL?) -> Bool {
        guard mode == .webkit, let url, let site = Self.site(of: url) else { return false }
        if sites.contains(site) { return true }
        let host = url.host()?.lowercased() ?? ""
        return Self.knownHosts.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    func remember(_ url: URL) {
        guard let site = Self.site(of: url), sites.insert(site).inserted else { return }
        save(sites, to: file)
    }

    /// Whether a WebKit page of this URL's site should first get the site's Chromium cookies, so it stays signed in.
    /// Once per site: afterwards WebKit's own cookies are the newer ones (the site no longer runs in Chromium), and
    /// copying again would bring back a session the user signed out of. Private sessions are new each time.
    func takeCookies(for url: URL, isPrivate: Bool) -> Bool {
        guard let site = Self.site(of: url) else { return false }
        if isPrivate { return true }
        guard cookiesTaken.insert(site).inserted else { return false }
        save(cookiesTaken, to: cookiesFile)
        return true
    }

    private func save(_ set: Set<String>, to file: URL?) {
        guard let file else { return }
        try? JSONEncoder().encode(set.sorted()).write(to: file, options: .atomic)
    }

    /// A cookie as the bridge reads it from Chromium (`CEFRuntime cookiesOfSite:`), for WebKit's store.
    nonisolated static func httpCookie(_ c: [String: Any]) -> HTTPCookie? {
        guard let name = c["name"] as? String, let value = c["value"] as? String, let domain = c["domain"] as? String else { return nil }
        var properties: [HTTPCookiePropertyKey: Any] = [.name: name, .value: value, .domain: domain,
                                                        .path: (c["path"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "/"]
        if c["secure"] as? Bool == true { properties[.secure] = "TRUE" }
        if c["httpOnly"] as? Bool == true { properties[HTTPCookiePropertyKey("HttpOnly")] = "TRUE" }
        if let expires = c["expires"] as? Date { properties[.expires] = expires } else { properties[.discard] = "TRUE" }
        switch c["sameSite"] as? String {
        case "lax": properties[.sameSitePolicy] = HTTPCookieStringPolicy.sameSiteLax
        case "strict": properties[.sameSitePolicy] = HTTPCookieStringPolicy.sameSiteStrict
        default: break
        }
        return HTTPCookie(properties: properties)
    }

    /// The reverse, for the bridge's `setCookies:`.
    nonisolated static func bridgeCookie(_ c: BrowserCookie) -> [String: Any] {
        var out: [String: Any] = ["name": c.name, "value": c.value, "domain": c.domain, "path": c.path, "secure": c.isSecure, "httpOnly": c.isHTTPOnly]
        if let expires = c.expires { out["expires"] = expires }
        switch c.sameSite {
        case .lax?: out["sameSite"] = "lax"
        case .strict?: out["sameSite"] = "strict"
        case .noRestriction?: out["sameSite"] = "none"
        case nil: break
        }
        return out
    }

    /// The registrable part of a host, roughly (www.netflix.com → netflix.com; bbc.co.uk stays whole).
    static func site(of url: URL) -> String? {
        guard ["http", "https"].contains(url.scheme ?? ""), let host = url.host()?.lowercased() else { return nil }
        let labels = host.split(separator: ".")
        // IP addresses (and IPv6 hosts) are sites as they are.
        guard labels.count > 2, !host.contains(":"), !labels.allSatisfy({ $0.allSatisfy(\.isNumber) }) else { return host }
        let secondLevel = ["co", "com", "net", "org", "gov", "ac", "edu", "ne", "or", "go"]
        let keep = labels[labels.count - 1].count == 2 && secondLevel.contains(String(labels[labels.count - 2])) ? 3 : 2
        return labels.suffix(keep).joined(separator: ".")
    }

    /// In Chromium pages, before the page's own scripts: a request for a DRM key system (Widevine, PlayReady,
    /// FairPlay) tells the browser, which reopens the page in WebKit; the page's promise never settles meanwhile.
    static let detectorScript = """
    (() => {
      const request = navigator.requestMediaKeySystemAccess && navigator.requestMediaKeySystemAccess.bind(navigator);
      if (!request) return;
      Object.defineProperty(navigator, 'requestMediaKeySystemAccess', { configurable: true, writable: true, value: (keySystem, configs) => {
        if (/widevine|playready|fps|fairplay/i.test(String(keySystem))) {
          window.__browser && window.__browser.post('__protectedMedia', String(keySystem));
          return new Promise(() => {});
        }
        return request(keySystem, configs);
      } });
    })();
    """
}
