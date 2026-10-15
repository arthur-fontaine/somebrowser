import Foundation

/// Brave's default list set, split as Brave does: ad lists (relaxed on creator-friendly sites) and privacy
/// lists (always on). Unbreak lists hold exceptions and go into both.
nonisolated struct FilterList: Sendable, Equatable {
    enum Kind: Sendable { case ads, privacy, unbreak }
    var id: String
    var url: URL
    var kind: Kind
    /// May use trusted scriptlets (`trusted-*`), as uBlock Origin trusts its own lists.
    var trusted = false

    static let defaults: [FilterList] = [
        FilterList(id: "easylist", url: URL(string: "https://easylist.to/easylist/easylist.txt")!, kind: .ads),
        FilterList(id: "ublock-filters", url: URL(string: "https://ublockorigin.github.io/uAssets/filters/filters.txt")!, kind: .ads, trusted: true),
        FilterList(id: "easyprivacy", url: URL(string: "https://easylist.to/easylist/easyprivacy.txt")!, kind: .privacy),
        FilterList(id: "ublock-privacy", url: URL(string: "https://ublockorigin.github.io/uAssets/filters/privacy.txt")!, kind: .privacy, trusted: true),
        FilterList(id: "ublock-unbreak", url: URL(string: "https://ublockorigin.github.io/uAssets/filters/unbreak.txt")!, kind: .unbreak, trusted: true),
        FilterList(id: "brave-unbreak", url: URL(string: "https://raw.githubusercontent.com/brave/adblock-lists/master/brave-unbreak.txt")!, kind: .unbreak),
    ]
}

/// Downloads, caches and compiles the lists. Compiled engines are cached (serialized) so startup only
/// deserializes; lists refresh weekly. Nothing is fetched until the user browses (see `AdBlockFeature`).
nonisolated struct FilterListStore: Sendable {
    let directory: URL
    var lists: [FilterList] = FilterList.defaults
    /// The stand-ins `redirect=` serves and the scripts `##+js()` filters run: uBlock Origin's, assembled from its latest
    /// release (`UboResources`), plus Brave's own (already in adblock-rust's format). Brave ships the same set through
    /// its component updater, which isn't open to other clients.
    var resourcesURL = URL(string: "https://raw.githubusercontent.com/brave/adblock-resources/master/dist/resources.json")!
    var uboReleaseURL = URL(string: "https://api.github.com/repos/gorhill/uBlock/releases/latest")!
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
        var texts: [FilterList.Kind: [String]] = [:], trusted: [FilterList.Kind: [String]] = [:]
        for list in lists {
            let path = file("\(list.id).txt")
            if let data = try? await fetch(list.url), !data.isEmpty { try? data.write(to: path, options: .atomic) }
            if let text = try? String(contentsOf: path, encoding: .utf8) {
                if list.trusted { trusted[list.kind, default: []].append(text) } else { texts[list.kind, default: []].append(text) }
            }
        }
        await updateResources(fetch: fetch)
        let joined = { (kinds: [FilterList.Kind], from: [FilterList.Kind: [String]]) in kinds.flatMap { from[$0, default: []] }.joined(separator: "\n") }
        let (ads, adsTrusted) = (joined([.ads, .unbreak], texts), joined([.ads, .unbreak], trusted))
        let (privacy, privacyTrusted) = (joined([.privacy, .unbreak], texts), joined([.privacy, .unbreak], trusted))
        guard !(ads + adsTrusted + privacy + privacyTrusted).isEmpty else { throw URLError(.cannotLoadFromNetwork) }
        let engines = Engines(ads: AdBlockEngine(lists: ads, trustedLists: adsTrusted), privacy: AdBlockEngine(lists: privacy, trustedLists: privacyTrusted),
                              contentRules: contentRules ? AdBlockEngine.contentBlockingRules(lists: [privacy, privacyTrusted, ads, adsTrusted].joined(separator: "\n")) : nil)
        useResources(in: [engines.ads, engines.privacy])
        try engines.ads.serialized.write(to: file("ads.dat"), options: .atomic)
        try engines.privacy.serialized.write(to: file("privacy.dat"), options: .atomic)
        if let rules = engines.contentRules { try rules.write(to: file("content-rules.json"), atomically: true, encoding: .utf8) }
        return engines
    }

    /// Refreshes Brave's resources and, when uBlock Origin published a new release, re-assembles uBO's; then writes the
    /// merged `resources.json` (Brave's win on a name clash). A failure keeps the previous files.
    func updateResources(fetch: @Sendable (URL) async throws -> Data) async {
        if let data = try? await fetch(resourcesURL), (try? JSONDecoder().decode([AdBlockResource].self, from: data)) != nil {
            try? data.write(to: file("brave-resources.json"), options: .atomic)
        }
        struct Release: Decodable {
            struct Asset: Decodable { var name: String; var browser_download_url: URL }
            var tag_name: String
            var assets: [Asset]
        }
        let known = try? String(contentsOf: file("ubo.tag"), encoding: .utf8)
        if let data = try? await fetch(uboReleaseURL), let release = try? JSONDecoder().decode(Release.self, from: data),
           release.tag_name != known || !FileManager.default.fileExists(atPath: file("ubo-resources.json").path),
           let asset = release.assets.first(where: { $0.name.hasSuffix(".chromium.zip") }),
           let zip = try? await fetch(asset.browser_download_url),
           let resources = try? Self.assembleUbo(zip: zip) {
            try? JSONEncoder().encode(resources).write(to: file("ubo-resources.json"), options: .atomic)
            try? release.tag_name.write(to: file("ubo.tag"), atomically: true, encoding: .utf8)
        }
        let load = { (name: String) in (try? Data(contentsOf: file(name))).flatMap { try? JSONDecoder().decode([AdBlockResource].self, from: $0) } ?? [] }
        let brave = load("brave-resources.json")
        let braveNames = Set(brave.map(\.name))
        let merged = load("ubo-resources.json").filter { !braveNames.contains($0.name) } + brave
        if !merged.isEmpty, let data = try? JSONEncoder().encode(merged) { try? data.write(to: file("resources.json"), options: .atomic) }
    }

    /// Unpacks a uBlock Origin release zip (with `ditto`) and assembles its resources.
    static func assembleUbo(zip: Data) throws -> [AdBlockResource] {
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("ubo-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: work) }
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let archive = work.appendingPathComponent("ubo.zip"), unpacked = work.appendingPathComponent("x")
        try zip.write(to: archive)
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-x", "-k", archive.path, unpacked.path]
        try ditto.run()
        ditto.waitUntilExit()
        guard ditto.terminationStatus == 0 else { throw UboResources.AssemblyError.missing("unzip") }
        // The zip holds one folder (uBlock0.chromium/); accept a flat layout too.
        let candidates = [unpacked] + ((try? FileManager.default.contentsOfDirectory(at: unpacked, includingPropertiesForKeys: nil)) ?? [])
        guard let root = candidates.first(where: { FileManager.default.fileExists(atPath: $0.appendingPathComponent("js/resources/scriptlets.js").path) })
        else { throw UboResources.AssemblyError.missing("js/resources/scriptlets.js") }
        return try UboResources.assemble(extension: root)
    }

    static func download(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.setValue(nil, forHTTPHeaderField: "Cookie")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return data
    }
}
