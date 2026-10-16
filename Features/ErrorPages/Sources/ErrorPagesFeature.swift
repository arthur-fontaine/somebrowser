import BrowserCore
import Foundation

/// The browser's own page for a site that can't be opened (offline, no such site, refused…) and for an invalid
/// certificate, in place of Chrome's pages (and of WebKit's blank one), at the address that failed. Visit Anyway
/// accepts the certificate for that site until the browser quits.
public final class ErrorPagesFeature: BrowserFeature {
    let context: FeatureContext
    /// The site each page's certificate error page was shown for: Visit Anyway only counts from that page.
    private var certificatePages: [ObjectIdentifier: String] = [:]

    static let visitAnywayHost = "visit-anyway.invalid"

    public init(context: FeatureContext) { self.context = context }

    public func activate() {
        context.hooks.errorPage = { [weak self] error in self?.page(for: error) }
        context.hooks.addNavigationPolicy { [weak self] action in
            guard action.url.host() == Self.visitAnywayHost else { return .allow }
            return self?.visitAnyway(action) ?? .cancel
        }
    }

    func page(for error: PageLoadError) -> String {
        let host = error.url.host() ?? error.url.absoluteString
        if error.kind == .certificate, let tab = error.tab { certificatePages[ObjectIdentifier(tab)] = host }
        return ErrorPage.html(for: error)
    }

    /// The error page's Visit Anyway link: accepted only from the certificate page shown for that very site.
    private func visitAnyway(_ action: NavigationAction) -> NavigationPolicy {
        guard let tab = action.sourceTab,
              let target = URLComponents(url: action.url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "to" })?.value
                .flatMap(URL.init(string:)),
              let host = target.host(), certificatePages[ObjectIdentifier(tab)] == host else { return .cancel }
        certificatePages[ObjectIdentifier(tab)] = nil
        context.hooks.acceptedInvalidCertificates.insert(host)
        DispatchQueue.main.async { tab.load(target) }  // not from inside the engine's navigation decision
        return .handled
    }
}

enum ErrorPage {
    static func html(for error: PageLoadError) -> String {
        let host = escape(error.url.host() ?? error.url.absoluteString)
        let certificate = error.kind == .certificate
        let title = certificate ? "This Connection Isn’t Private" : "Can’t Open \(host)"
        let message = certificate
            ? "\(host)’s certificate isn’t valid. Someone may be pretending to be this site to read what you send it."
            : "The site couldn’t be reached. Check your connection, or try again in a moment."
        let visitAnyway = (URLComponents(string: "https://\(ErrorPagesFeature.visitAnywayHost)/").map { c -> String in
            var c = c
            c.queryItems = [URLQueryItem(name: "to", value: error.url.absoluteString)]
            return c.string ?? ""
        }) ?? ""
        let actions = certificate
            ? #"<button onclick="history.length > 1 ? history.back() : location.replace('about:blank')">Go Back</button>"#
                + #"<a class="quiet" href="\#(escape(visitAnyway))">Visit Anyway</a>"#
            : #"<button onclick="location.reload()">Try Again</button>"#
        return """
        <!doctype html><html><head><meta charset="utf-8"><meta name="color-scheme" content="light dark">
        <title>\(title)</title><style>
        html { height: 100%; } body { margin: 0; min-height: 100%; display: grid; place-items: center; background: Canvas;
          font: 14px/1.45 -apple-system, BlinkMacSystemFont, sans-serif; color: CanvasText; }
        main { max-width: 440px; padding: 32px; text-align: center; }
        .symbol { font-size: 44px; opacity: .55; } h1 { font-size: 22px; font-weight: 600; margin: 12px 0 8px; }
        p { opacity: .7; margin: 0 0 6px; } .detail { font-size: 12px; opacity: .45; margin-bottom: 22px; }
        button { font: inherit; font-weight: 500; padding: 7px 18px; border-radius: 999px; border: 0; background: AccentColor;
          color: AccentColorText; cursor: default; } .quiet { display: block; margin-top: 14px; font-size: 12px; color: inherit; opacity: .55; }
        </style></head><body><main>
        <div class="symbol">\(certificate ? "⚠︎" : "◌")</div><h1>\(title)</h1><p>\(message)</p>
        <p class="detail">\(escape(error.description))</p>\(actions)
        </main></body></html>
        """
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }
}
