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

    /// Streaming services known to need protected media: their pages open in WebKit from the first one, so signing in
    /// happens there and no page ever moves. Hosts, matched with their subdomains.
    static let knownHosts: Set<String> = [
        "netflix.com", "disneyplus.com", "primevideo.com", "max.com", "hbomax.com", "hulu.com", "paramountplus.com",
        "peacocktv.com", "crunchyroll.com", "canalplus.com", "tv.apple.com", "music.apple.com", "open.spotify.com",
    ]

    init(mode: Mode, file: URL?) {
        self.mode = mode
        self.file = file
        func load(_ file: URL?) -> Set<String> {
            Set(file.flatMap { try? Data(contentsOf: $0) }.flatMap { try? JSONDecoder().decode([String].self, from: $0) } ?? [])
        }
        sites = load(file)
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

    private func save(_ set: Set<String>, to file: URL?) {
        guard let file else { return }
        try? JSONEncoder().encode(set.sorted()).write(to: file, options: .atomic)
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
