import Foundation

/// Brave's default list set, split as Brave does: ad lists (relaxed on creator-friendly sites) and privacy
/// lists (always on). Unbreak lists hold exceptions and go into both.
nonisolated struct FilterList: Sendable, Equatable {
    enum Kind: Sendable { case ads, privacy, unbreak }
    var id: String
    var url: URL
    var kind: Kind

    static let defaults: [FilterList] = [
        FilterList(id: "easylist", url: URL(string: "https://easylist.to/easylist/easylist.txt")!, kind: .ads),
        FilterList(id: "ublock-filters", url: URL(string: "https://ublockorigin.github.io/uAssets/filters/filters.txt")!, kind: .ads),
        FilterList(id: "easyprivacy", url: URL(string: "https://easylist.to/easylist/easyprivacy.txt")!, kind: .privacy),
        FilterList(id: "ublock-privacy", url: URL(string: "https://ublockorigin.github.io/uAssets/filters/privacy.txt")!, kind: .privacy),
        FilterList(id: "ublock-unbreak", url: URL(string: "https://ublockorigin.github.io/uAssets/filters/unbreak.txt")!, kind: .unbreak),
        FilterList(id: "brave-unbreak", url: URL(string: "https://raw.githubusercontent.com/brave/adblock-lists/master/brave-unbreak.txt")!, kind: .unbreak),
    ]
}

/// Downloads, caches and compiles the lists. Compiled engines are cached (serialized) so startup only
/// deserializes; lists refresh weekly. Nothing is fetched until the user browses (see `AdBlockFeature`).
nonisolated struct FilterListStore: Sendable {
    let directory: URL
    var lists: [FilterList] = FilterList.defaults
    /// Brave's redirect and scriptlet resources (uBlock Origin's, in adblock-rust's format): the stand-ins `redirect=`
    /// serves and the scripts `##+js()` filters run.
    var resourcesURL = URL(string: "https://raw.githubusercontent.com/brave/adblock-resources/master/dist/resources.json")!
    var maxAge: TimeInterval = 7 * 24 * 3600

    struct Engines: Sendable {
        var ads: AdBlockEngine
        var privacy: AdBlockEngine
        /// Apple content-blocker JSON for engines that block through rule lists (WebKit).
        var contentRules: String?
    }

    private func file(_ name: String) -> URL { directory.appendingPathComponent(name) }

    var isStale: Bool {
        let date = (try? FileManager.default.attributesOfItem(atPath: file("ads.dat").path)[.modificationDate]) as? Date
        return date.map { Date().timeIntervalSince($0) > maxAge } ?? true
    }

    /// Cached engines, or nil when there is no (compatible) cache.
    func loadCached(contentRules: Bool) -> Engines? {
        guard let ads = (try? Data(contentsOf: file("ads.dat"))).flatMap(AdBlockEngine.init(serialized:)),
              let privacy = (try? Data(contentsOf: file("privacy.dat"))).flatMap(AdBlockEngine.init(serialized:)) else { return nil }
        let rules = contentRules ? (try? String(contentsOf: file("content-rules.json"), encoding: .utf8)) : nil
        useResources(in: [ads, privacy])
        return Engines(ads: ads, privacy: privacy, contentRules: rules)
    }

    private func useResources(in engines: [AdBlockEngine]) {
        guard let json = try? String(contentsOf: file("resources.json"), encoding: .utf8) else { return }
        for engine in engines { engine.useResources(json: json) }
    }

    /// Downloads every list (keeping the previous copy of any that fails), compiles and caches the engines.
    func update(contentRules: Bool, fetch: @Sendable (URL) async throws -> Data = Self.download) async throws -> Engines {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var texts: [FilterList.Kind: [String]] = [:]
        for list in lists {
            let path = file("\(list.id).txt")
            if let data = try? await fetch(list.url), !data.isEmpty { try? data.write(to: path, options: .atomic) }
            if let text = try? String(contentsOf: path, encoding: .utf8) { texts[list.kind, default: []].append(text) }
        }
        if let data = try? await fetch(resourcesURL), (try? JSONSerialization.jsonObject(with: data)) is [Any] {
            try? data.write(to: file("resources.json"), options: .atomic)
        }
        let unbreak = texts[.unbreak, default: []]
        let adsText = (texts[.ads, default: []] + unbreak).joined(separator: "\n")
        let privacyText = (texts[.privacy, default: []] + unbreak).joined(separator: "\n")
        guard !adsText.isEmpty || !privacyText.isEmpty else { throw URLError(.cannotLoadFromNetwork) }
        let engines = Engines(ads: AdBlockEngine(lists: adsText), privacy: AdBlockEngine(lists: privacyText),
                              contentRules: contentRules ? AdBlockEngine.contentBlockingRules(lists: privacyText + "\n" + adsText) : nil)
        useResources(in: [engines.ads, engines.privacy])
        try engines.ads.serialized.write(to: file("ads.dat"), options: .atomic)
        try engines.privacy.serialized.write(to: file("privacy.dat"), options: .atomic)
        if let rules = engines.contentRules { try rules.write(to: file("content-rules.json"), atomically: true, encoding: .utf8) }
        return engines
    }

    static func download(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.setValue(nil, forHTTPHeaderField: "Cookie")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return data
    }
}
