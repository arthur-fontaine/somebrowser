import BrowserCore
import Foundation

public final class SearchFeature: BrowserFeature {
    let context: FeatureContext
    let service: DefaultSearchService

    public init(context: FeatureContext) {
        self.context = context
        service = DefaultSearchService(settings: context.settings)
        let outbound = context.runtime.outbound, source = context.featureID
        service.fetch = { url in try? await outbound.data(for: URLRequest(url: url), purpose: "search suggestions", source: source).0 }
    }

    public func activate() {
        context.capabilities.provide(SearchService.self, service)
        // The engine's own UI (Chromium's "Search … for" menu item) searches with the same engine.
        context.settings.observe("search.engine") { [weak self] _ in self?.syncEngine() }
        syncEngine()
    }

    func syncEngine() {
        context.hooks.defaultSearch = DefaultSearchEngine(name: service.engine.name, template: service.engine.search)
    }
}

/// URL detection, engine templates, keyword site search and suggestions.
final class DefaultSearchService: SearchService {
    struct Engine {
        let name: String
        let search: String
        let suggest: String?
    }

    static let engines: [String: Engine] = [
        "duckduckgo": Engine(name: "DuckDuckGo", search: "https://duckduckgo.com/?q=%s", suggest: "https://duckduckgo.com/ac/?q=%s&type=list"),
        "kagi": Engine(name: "Kagi", search: "https://kagi.com/search?q=%s", suggest: "https://kagi.com/api/autosuggest?q=%s"),
        "brave": Engine(name: "Brave Search", search: "https://search.brave.com/search?q=%s", suggest: "https://search.brave.com/api/suggest?q=%s"),
        "startpage": Engine(name: "Startpage", search: "https://www.startpage.com/do/search?q=%s", suggest: nil),
        "ecosia": Engine(name: "Ecosia", search: "https://www.ecosia.org/search?q=%s", suggest: "https://ac.ecosia.org/autocomplete?q=%s&type=list"),
        "bing": Engine(name: "Bing", search: "https://www.bing.com/search?q=%s", suggest: "https://api.bing.com/osjson.aspx?query=%s"),
        "google": Engine(name: "Google", search: "https://www.google.com/search?q=%s", suggest: "https://suggestqueries.google.com/complete/search?client=firefox&q=%s"),
        "perplexity": Engine(name: "Perplexity", search: "https://www.perplexity.ai/search?q=%s", suggest: nil),
    ]

    private let settings: SettingsStore
    /// Suggestion requests; the feature routes them through Security Core's log.
    var fetch: (URL) async -> Data? = { _ in nil }

    init(settings: SettingsStore) { self.settings = settings }

    var engine: Engine { Self.engines[settings.string("search.engine")] ?? Self.engines["duckduckgo"]! }
    var engineName: String { engine.name }

    /// `yt` → template, parsed from the setting.
    var keywords: [String: String] {
        var map: [String: String] = [:]
        for pair in settings.string("search.keywords").split(separator: ",") {
            let parts = pair.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count == 2, !parts[0].isEmpty { map[parts[0].lowercased()] = parts[1] }
        }
        return map
    }

    /// Splits "yt cats" into the keyword template and the query.
    func keywordSearch(_ input: String) -> (template: String, query: String)? {
        let trimmed = input.trimmingCharacters(in: .whitespaces)
        guard let space = trimmed.firstIndex(of: " ") else { return nil }
        let key = trimmed[..<space].lowercased()
        guard let template = keywords[key] else { return nil }
        let query = trimmed[space...].trimmingCharacters(in: .whitespaces)
        return query.isEmpty ? nil : (template, query)
    }

    func looksLikeURL(_ raw: String) -> Bool {
        let input = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty, !input.contains(" ") else { return false }
        if let scheme = URL(string: input)?.scheme?.lowercased(),
           ["http", "https", "file", "about", "chrome", "data", "ftp", "view-source", "chrome-extension", Brand.urlScheme].contains(scheme) {
            return true
        }
        let hostPart = input.split(separator: "/").first.map(String.init) ?? input
        let host = hostPart.split(separator: ":").first.map(String.init) ?? hostPart
        if host == "localhost" { return true }
        if host.split(separator: ".").count == 4, host.split(separator: ".").allSatisfy({ Int($0).map { (0...255).contains($0) } ?? false }) {
            return true
        }
        let labels = host.split(separator: ".")
        guard labels.count >= 2, let tld = labels.last, tld.count >= 2, tld.allSatisfy({ $0.isLetter }) else { return false }
        return labels.allSatisfy { !$0.isEmpty && $0.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" } }
    }

    func url(for raw: String) -> URL? {
        let input = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return nil }
        if let (template, query) = keywordSearch(input) { return Self.fill(template, query) }
        if looksLikeURL(input) {
            if let url = URL(string: input), url.scheme != nil, input.contains(":") && (input.contains("://") || url.scheme != "localhost") {
                if url.host() != nil || ["about", "data", "file", "chrome", "view-source"].contains(url.scheme ?? "") { return url }
            }
            let host = input.split(separator: "/").first.map(String.init) ?? input
            let scheme = host.hasPrefix("localhost") || host.first?.isNumber == true ? "http" : "https"
            return URL(string: "\(scheme)://\(input)")
        }
        return Self.fill(engine.search, input)
    }

    func searchURL(for raw: String) -> URL? {
        let input = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return nil }
        if let (template, query) = keywordSearch(input) { return Self.fill(template, query) }
        return Self.fill(engine.search, input)
    }

    func searchTerms(in url: URL) -> String? { Self.terms(in: url, template: engine.search) }

    func searchTerms(inAnyEngine url: URL) -> String? {
        searchTerms(in: url) ?? Self.engines.values.lazy.compactMap { Self.terms(in: url, template: $0.search) }.first
    }

    /// The query of a results page of this template: same path and query parameter, on its host or a country's
    /// (`google.fr` for `google.com`).
    static func terms(in url: URL, template: String) -> String? {
        let marker = "__terms__"
        guard ["http", "https"].contains(url.scheme?.lowercased()),
              let t = URLComponents(string: template.replacingOccurrences(of: "%s", with: marker)), let base = t.host?.lowercased(),
              let name = t.queryItems?.first(where: { $0.value == marker })?.name,
              let u = URLComponents(url: url, resolvingAgainstBaseURL: false), let host = u.host?.lowercased(),
              u.path == t.path, sameEngine(host, base),
              let raw = u.percentEncodedQueryItems?.first(where: { $0.name == name })?.value,
              let terms = raw.replacingOccurrences(of: "+", with: " ").removingPercentEncoding?.trimmingCharacters(in: .whitespaces),
              !terms.isEmpty else { return nil }
        return terms
    }

    static func sameEngine(_ host: String, _ base: String) -> Bool {
        let host = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        let base = base.hasPrefix("www.") ? String(base.dropFirst(4)) : base
        if host == base { return true }
        let stem = base.split(separator: ".").dropLast().joined(separator: ".") + "."
        guard stem.count > 1, host.hasPrefix(stem) else { return false }
        // A country's suffix (`fr`, `co.uk`), not another site (`google.evil.com`).
        let suffix = host.dropFirst(stem.count).split(separator: ".")
        return (1...2).contains(suffix.count) && suffix.allSatisfy { (2...3).contains($0.count) && $0.allSatisfy(\.isLetter) }
    }

    static func fill(_ template: String, _ query: String) -> URL? {
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryValueAllowed) ?? query
        return URL(string: template.replacingOccurrences(of: "%s", with: encoded))
    }

    func suggestions(for query: String) async -> [String] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard settings.bool("search.suggestions"), q.count >= 2, !looksLikeURL(q),
              let template = engine.suggest, let url = Self.fill(template, q), let data = await fetch(url) else { return [] }
        return Self.parseSuggestions(data)
    }

    /// Engines answer either the OpenSearch format `["q", ["s1", "s2"]]` or `[{"phrase": "s1"}]`.
    static func parseSuggestions(_ data: Data) -> [String] {
        guard let json = try? JSONSerialization.jsonObject(with: data) else { return [] }
        if let array = json as? [Any], array.count >= 2, let list = array[1] as? [String] { return Array(list.prefix(6)) }
        if let array = json as? [[String: Any]] { return array.compactMap { $0["phrase"] as? String }.prefix(6).map { $0 } }
        return []
    }
}

extension CharacterSet {
    static let urlQueryValueAllowed: CharacterSet = {
        var set = CharacterSet.urlQueryAllowed
        set.remove(charactersIn: "&+=?#")
        return set
    }()
}
