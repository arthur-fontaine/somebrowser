import Foundation

/// Replaces the compile-time safety of central exhaustive enums (see docs/research/tinycast-architecture.md):
/// every id is unique, namespaced, bound, and every override targets something that exists.
enum Validator {
    struct Issue: CustomStringConvertible {
        enum Level: String { case error, warning }
        var level: Level
        var message: String
        var description: String { "\(level.rawValue): \(message)" }
    }

    static let upstreamBrandName = "Somebrowser"

    static func run(_ p: Project) -> [Issue] {
        var issues: [Issue] = []
        func error(_ s: String) { issues.append(Issue(level: .error, message: s)) }
        func warn(_ s: String) { issues.append(Issue(level: .warning, message: s)) }

        // Unique feature ids per layer (a fork may shadow an upstream id only via `replaces`).
        var seen: [String: FeatureEntry] = [:]
        for f in p.features {
            if let other = seen[f.manifest.id], other.isFork == f.isFork {
                error("duplicate feature id '\(f.manifest.id)' in \(other.directory) and \(f.directory)")
            }
            seen[f.manifest.id] = f
            if f.manifest.id != f.manifest.id.lowercased() || f.manifest.id.contains(" ") {
                error("feature id '\(f.manifest.id)' must be lowercase kebab-case")
            }
        }

        // Commands and settings: unique, namespaced by feature id.
        var commandOwner: [String: String] = [:]
        var settingOwner: [String: String] = [:]
        for f in p.enabled {
            let m = f.manifest
            for c in m.commands {
                if !c.id.hasPrefix(m.id + ".") { error("command '\(c.id)' must be namespaced '\(m.id).…' (\(f.directory))") }
                if let o = commandOwner[c.id] { error("command '\(c.id)' declared by both '\(o)' and '\(m.id)'") }
                commandOwner[c.id] = m.id
                for s in [c.shortcut].compactMap({ $0 }) + (c.alternateShortcuts ?? []) where !isValidShortcut(s) {
                    error("command '\(c.id)': invalid shortcut '\(s)'")
                }
            }
            for s in m.settings {
                if !s.key.hasPrefix(m.id + ".") { error("setting '\(s.key)' must be namespaced '\(m.id).…' (\(f.directory))") }
                if let o = settingOwner[s.key] { error("setting '\(s.key)' declared by both '\(o)' and '\(m.id)'") }
                settingOwner[s.key] = m.id
                if !["bool", "int", "double", "string", "choice"].contains(s.type) { error("setting '\(s.key)': unknown type '\(s.type)'") }
                if s.type == "choice" && (s.options ?? []).isEmpty { error("setting '\(s.key)': choice needs options") }
            }
            // Entry type exists in the feature sources.
            if !sourcesDeclare(type: m.entry, in: p.path("\(f.directory)/Sources")) {
                error("feature '\(m.id)': entry type '\(m.entry)' not found in \(f.directory)/Sources")
            }
            if !FileManager.default.fileExists(atPath: p.path("\(f.directory)/Tests").path) {
                error("feature '\(m.id)' has no Tests/ directory — every feature ships automated tests (\(f.directory))")
            }
            if !FileManager.default.fileExists(atPath: p.path("\(f.directory)/README.md").path) {
                warn("feature '\(m.id)' has no README.md")
            }
        }

        // Overrides must target existing ids.
        for (id, _) in p.shortcutOverrides where commandOwner[id] == nil {
            warn("shortcut override for unknown or disabled command '\(id)'")
        }
        for (key, _) in p.settingOverrides where settingOwner[key] == nil {
            warn("setting override for unknown or disabled setting '\(key)'")
        }

        // Shortcut collisions after overrides.
        var byShortcut: [String: [String]] = [:]
        for f in p.enabled {
            for c in f.manifest.commands {
                let primary: String? = p.shortcutOverrides[c.id].map { $0.isEmpty ? nil : $0 } ?? c.shortcut
                for s in [primary].compactMap({ $0 }) + (c.alternateShortcuts ?? []) {
                    byShortcut[normalizeShortcut(s), default: []].append(c.id)
                }
            }
        }
        for (s, ids) in byShortcut where ids.count > 1 {
            error("shortcut '\(s)' bound to several commands: \(ids.sorted().joined(separator: ", ")) — override one in Fork/fork.json")
        }

        // Features never import each other (they talk through capabilities).
        let featureModules = Set(p.features.map(\.targetName))
        for f in p.features {
            for (file, module) in imports(in: p.path("\(f.directory)/Sources")) where featureModules.contains(module) && module != f.targetName {
                error("\(file): imports \(module) — features must use capabilities, not import other features")
            }
        }

        // The browser's own requests go through Core's OutboundConnections, Security Core's log: no URLSession in features
        // or engines, so none escapes it.
        for dir in p.features.map({ p.path("\($0.directory)/Sources") }) + [p.path("Engines")] {
            for file in swiftFiles(in: dir) where !file.path.contains("/Tests/") {
                if usesURLSession((try? String(contentsOf: file, encoding: .utf8)) ?? "") {
                    error("\(relative(file, p)): uses URLSession — request through context.fetch (features) or hooks.fetch (engines) so Security Core logs it")
                }
            }
        }

        // No stray product-name literals outside generated code (renaming must stay a one-line change).
        if p.brand.name == upstreamBrandName || !p.hasFork {
            for dir in ["Core/Sources", "Shell/Sources", "Features", "Engines"] {
                for file in swiftFiles(in: p.path(dir)) {
                    let text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
                    if text.contains("\"\(upstreamBrandName)") || text.contains(" \(upstreamBrandName) ") {
                        error("\(relative(file, p)): contains the literal '\(upstreamBrandName)' — use Brand.name")
                    }
                }
            }
        }
        return issues
    }

    static let modifierNames: Set<String> = ["cmd", "shift", "opt", "alt", "ctrl", "fn"]

    /// URLSession in code (not in a comment).
    static func usesURLSession(_ source: String) -> Bool {
        source.split(separator: "\n").contains { line in
            let code = line.trimmingCharacters(in: .whitespaces)
            return !code.hasPrefix("//") && (code.range(of: "//").map { String(code[..<$0.lowerBound]) } ?? code).contains("URLSession")
        }
    }

    static func isValidShortcut(_ s: String) -> Bool {
        let parts = s.lowercased().split(separator: "+", omittingEmptySubsequences: false).map(String.init)
        guard let key = parts.last, !key.isEmpty else { return s.hasSuffix("++") }
        return parts.dropLast().allSatisfy { modifierNames.contains($0) }
    }

    /// Canonical form so `shift+cmd+t` and `cmd+shift+t` collide.
    static func normalizeShortcut(_ s: String) -> String {
        var parts = s.lowercased().split(separator: "+", omittingEmptySubsequences: false).map(String.init)
        if s.hasSuffix("++") { parts = Array(parts.dropLast(2)) + ["+"] }
        let key = parts.last ?? ""
        let mods = Set(parts.dropLast().map { $0 == "alt" ? "opt" : $0 })
        let order = ["ctrl", "opt", "shift", "cmd", "fn"]
        return (order.filter(mods.contains) + [key]).joined(separator: "+")
    }

    static func sourcesDeclare(type: String, in dir: URL) -> Bool {
        let patterns = ["class \(type)", "struct \(type)", "actor \(type)", "enum \(type)"]
        return swiftFiles(in: dir).contains { file in
            let text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
            return patterns.contains { text.contains($0 + ":") || text.contains($0 + " ") || text.contains($0 + "{") }
        }
    }

    static func imports(in dir: URL) -> [(String, String)] {
        swiftFiles(in: dir).flatMap { file -> [(String, String)] in
            let text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
            return text.split(separator: "\n").compactMap { line in
                let l = line.trimmingCharacters(in: .whitespaces)
                guard l.hasPrefix("import ") || l.hasPrefix("@testable import ") else { return nil }
                return (file.lastPathComponent, String(l.split(separator: " ").last ?? ""))
            }
        }
    }

    static func swiftFiles(in dir: URL) -> [URL] {
        guard let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil) else { return [] }
        return e.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" && !$0.path.contains("/Generated/") }
    }

    static func relative(_ url: URL, _ p: Project) -> String {
        url.path.replacingOccurrences(of: p.root.path + "/", with: "")
    }
}
