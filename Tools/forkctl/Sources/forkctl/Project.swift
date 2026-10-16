import Foundation

/// `Engines/<Dir>/engine.json`
struct EngineManifest: Codable, Equatable {
    struct Target: Codable, Equatable {
        var name: String
        /// Path relative to the repo root.
        var path: String
        /// `swift` or `objcxx` (Objective-C++ / C++ sources with a public `include/` dir).
        var language: String
        /// `library` (default) or `executable`.
        var type: String?
        var dependencies: [String]?
        var unsafeCFlags: [String]?
        var unsafeLinkerFlags: [String]?
        var frameworks: [String]?
    }

    var id: String
    var name: String
    var summary: String?
    /// Swift module exposing `entry`.
    var module: String
    /// Type conforming to `BrowserEngine`.
    var entry: String
    var targets: [Target]
    /// `plain` or `cef` — how `forkctl bundle` assembles the .app.
    var bundler: String?
    /// `NSPrincipalClass` of the app (CEF requires an NSApplication subclass implementing CefAppProtocol).
    var principalClass: String?
    /// Vendored binary distribution this engine needs (`cef`), fetched by `forkctl vendor`.
    var vendor: String?
}

struct FeatureEntry: Equatable {
    var manifest: FeatureManifest
    /// Directory relative to the repo root (e.g. `Features/Tabs`).
    var directory: String
    var isFork: Bool

    var targetName: String { "Feature" + pascalCase(manifest.id) }
    var testTargetName: String { targetName + "Tests" }
}

struct ResolvedBrand: Equatable {
    var name: String
    var formerNames: [String]
    var bundleId: String
    var urlScheme: String
    var userAgentBrand: String
    var icon: String?
    var homepage: String
    var repository: String
    var copyright: String

    /// File-system / identifier friendly form of the product name.
    var executableName: String { name.filter { $0.isLetter || $0.isNumber } }
}

struct Project {
    let root: URL
    let brand: ResolvedBrand
    let engine: EngineManifest
    let engines: [EngineManifest]
    let features: [FeatureEntry]
    let enabled: [FeatureEntry]
    let shortcutOverrides: [String: String]
    let settingOverrides: [String: JSONValue]
    let engineOptions: [String: JSONValue]
    let hasFork: Bool

    func path(_ relative: String) -> URL { root.appendingPathComponent(relative) }
}

enum ProjectError: Error, CustomStringConvertible {
    case missing(String)
    case invalid(String)

    var description: String {
        switch self {
        case .missing(let s): return "missing: \(s)"
        case .invalid(let s): return s
        }
    }
}

enum ProjectLoader {
    static func load(root: URL) throws -> Project {
        let fm = FileManager.default
        let defaults = try readJSON(ForkConfig.self, at: root.appendingPathComponent("Defaults/fork.json"))
        let forkURL = root.appendingPathComponent("Fork/fork.json")
        let hasFork = fm.fileExists(atPath: forkURL.path)
        let fork = hasFork ? try readJSON(ForkConfig.self, at: forkURL) : ForkConfig()

        // Brand: Defaults ← Fork, field by field.
        let b = (fork.brand ?? BrandConfig()).merged(over: defaults.brand ?? BrandConfig())
        guard let name = b.name, let bundleId = b.bundleId else {
            throw ProjectError.invalid("brand.name and brand.bundleId are required in Defaults/fork.json")
        }
        let brand = ResolvedBrand(
            name: name,
            formerNames: b.formerNames ?? [],
            bundleId: bundleId,
            urlScheme: b.urlScheme ?? name.lowercased().filter { $0.isLetter || $0.isNumber },
            userAgentBrand: b.userAgentBrand ?? name,
            icon: b.icon,
            homepage: b.homepage ?? "",
            repository: b.repository ?? "",
            copyright: b.copyright ?? ""
        )

        // Engines.
        var engines: [EngineManifest] = []
        for dir in try subdirectories(of: root.appendingPathComponent("Engines")) {
            let url = dir.appendingPathComponent("engine.json")
            if fm.fileExists(atPath: url.path) { engines.append(try readJSON(EngineManifest.self, at: url)) }
        }
        // FORKCTL_ENGINE overrides the configured engine for one command (CI runs the suite on every engine).
        let engineId = ProcessInfo.processInfo.environment["FORKCTL_ENGINE"] ?? fork.engine ?? defaults.engine ?? "webkit"
        guard let engine = engines.first(where: { $0.id == engineId }) else {
            throw ProjectError.invalid("engine '\(engineId)' not found; available: \(engines.map(\.id).sorted())")
        }

        // Features: upstream + fork overlay.
        var features: [FeatureEntry] = []
        for (base, isFork) in [("Features", false), ("Fork/Features", true)] {
            for dir in try subdirectories(of: root.appendingPathComponent(base)) {
                let url = dir.appendingPathComponent("feature.json")
                guard fm.fileExists(atPath: url.path) else { continue }
                let m = try readJSON(FeatureManifest.self, at: url)
                features.append(FeatureEntry(manifest: m, directory: "\(base)/\(dir.lastPathComponent)", isFork: isFork))
            }
        }

        let enabled = try resolveEnabled(features: features, defaults: defaults, fork: fork, engine: engineId)

        var shortcuts = defaults.shortcuts ?? [:]
        shortcuts.merge(fork.shortcuts ?? [:]) { $1 }
        var settings = defaults.settings ?? [:]
        settings.merge(fork.settings ?? [:]) { $1 }
        var options = defaults.engineOptions ?? [:]
        options.merge(fork.engineOptions ?? [:]) { $1 }

        return Project(root: root, brand: brand, engine: engine, engines: engines, features: features,
                       enabled: enabled, shortcutOverrides: shortcuts, settingOverrides: settings,
                       engineOptions: options, hasFork: hasFork)
    }

    /// Enabled = default-enabled features ± Defaults/Fork selections, minus replaced and engine-incompatible
    /// features, ordered so that providers come before the features requiring them.
    static func resolveEnabled(features: [FeatureEntry], defaults: ForkConfig, fork: ForkConfig, engine: String) throws -> [FeatureEntry] {
        var ids = Set(features.filter { $0.manifest.enabledByDefault }.map(\.manifest.id))
        for selection in [defaults.features, fork.features] {
            ids.formUnion(selection?.enable ?? [])
            ids.subtract(selection?.disable ?? [])
        }
        let byId = Dictionary(features.map { ($0.manifest.id, $0) }, uniquingKeysWith: { a, b in b.isFork ? b : a })
        for id in ids where byId[id] == nil {
            throw ProjectError.invalid("feature '\(id)' is enabled but no Features/*/feature.json declares it")
        }
        // A fork feature with `replaces: X` disables X.
        for id in ids { if let r = byId[id]?.manifest.replaces { ids.remove(r) } }
        // Engine compatibility.
        ids = ids.filter { id in
            let engines = byId[id]!.manifest.engines
            return engines.contains("*") || engines.contains(engine)
        }

        // Topological order by capability.
        let selected = ids.compactMap { byId[$0] }.sorted { $0.manifest.id < $1.manifest.id }
        var providers: [String: String] = [:]
        for f in selected { for cap in f.manifest.provides + [f.manifest.id] { providers[cap] = f.manifest.id } }
        var ordered: [FeatureEntry] = []
        var state: [String: Int] = [:]  // 1 visiting, 2 done
        func visit(_ f: FeatureEntry, path: [String]) throws {
            let id = f.manifest.id
            if state[id] == 2 { return }
            if state[id] == 1 { throw ProjectError.invalid("capability cycle: \((path + [id]).joined(separator: " → "))") }
            state[id] = 1
            for cap in f.manifest.requires + f.manifest.optional {
                guard let p = providers[cap] else {
                    if f.manifest.requires.contains(cap) {
                        throw ProjectError.invalid("feature '\(id)' requires capability '\(cap)' but no enabled feature provides it")
                    }
                    continue
                }
                if p != id, let pf = byId[p] { try visit(pf, path: path + [id]) }
            }
            state[id] = 2
            ordered.append(f)
        }
        for f in selected { try visit(f, path: []) }
        return ordered
    }
}

func readJSON<T: Decodable>(_ type: T.Type, at url: URL) throws -> T {
    guard let data = FileManager.default.contents(atPath: url.path) else { throw ProjectError.missing(url.path) }
    do { return try JSONDecoder().decode(T.self, from: data) }
    catch { throw ProjectError.invalid("\(url.path): \(error)") }
}

func subdirectories(of url: URL) throws -> [URL] {
    let fm = FileManager.default
    guard fm.fileExists(atPath: url.path) else { return [] }
    return try fm.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey])
        .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
}

func pascalCase(_ id: String) -> String {
    id.split(whereSeparator: { $0 == "-" || $0 == "_" || $0 == "." })
        .map { $0.prefix(1).uppercased() + $0.dropFirst() }
        .joined()
}
