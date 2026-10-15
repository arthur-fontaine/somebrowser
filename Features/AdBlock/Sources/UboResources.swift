import Foundation
import JavaScriptCore

/// One adblock-rust resource (the format of Brave's `resources.json`).
nonisolated struct AdBlockResource: Codable, Equatable, Sendable {
    /// `{"mime": …}`, or `"template"` for old-style scriptlets (`{{1}}` placeholders).
    struct Kind: Codable, Equatable, Sendable {
        var mime: String?
        init(mime: String?) { self.mime = mime }
        init(from decoder: Decoder) throws {
            if let object = try? decoder.container(keyedBy: Key.self) { mime = try object.decode(String.self, forKey: .mime); return }
            guard try decoder.singleValueContainer().decode(String.self) == "template" else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "unknown resource kind"))
            }
            mime = nil
        }
        func encode(to encoder: Encoder) throws {
            if let mime { var object = encoder.container(keyedBy: Key.self); try object.encode(mime, forKey: .mime) }
            else { var single = encoder.singleValueContainer(); try single.encode("template") }
        }
        private enum Key: CodingKey { case mime }
    }
    var name: String
    var aliases: [String]
    var kind: Kind
    /// Base64.
    var content: String
    var dependencies: [String] = []
    /// Bit 0: only for trusted lists (uBlock Origin's own `trusted-*` scriptlets).
    var permission: Int = 0

    init(name: String, aliases: [String], kind: Kind, content: String, dependencies: [String], permission: Int) {
        (self.name, self.aliases, self.kind, self.content, self.dependencies, self.permission) = (name, aliases, kind, content, dependencies, permission)
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        aliases = try c.decodeIfPresent([String].self, forKey: .aliases) ?? []
        kind = try c.decode(Kind.self, forKey: .kind)
        content = try c.decode(String.self, forKey: .content)
        dependencies = try c.decodeIfPresent([String].self, forKey: .dependencies) ?? []
        permission = try c.decodeIfPresent(Int.self, forKey: .permission) ?? 0
    }
}

/// uBlock Origin's redirect stand-ins and scriptlets as adblock-rust resources, assembled from uBO's built extension the
/// way Brave's packager does with Node. Scriptlets are ES modules that register themselves (`registerScriptlet(fn, …)`);
/// JavaScriptCore has no module loader, so the module graph is bundled into one script first (`bundle`).
nonisolated enum UboResources {
    enum AssemblyError: Error { case script(String), missing(String) }

    /// `root` is the unpacked extension (`js/`, `web_accessible_resources/`).
    static func assemble(extension root: URL) throws -> [AdBlockResource] {
        try redirects(root) + scriptlets(root)
    }

    /// Scriptlets and the helper functions they depend on (`*.fn`, injected as dependencies only).
    static func scriptlets(_ root: URL) throws -> [AdBlockResource] {
        let script = try bundle(entry: "js/resources/scriptlets.js", root: root) + """

        JSON.stringify(__require('js/resources/scriptlets.js').builtinScriptlets.map(s => ({
          name: s.name, aliases: s.aliases || [], source: s.fn.toString(),
          dependencies: s.dependencies || [], trusted: !!s.requiresTrust,
        })))
        """
        struct Entry: Decodable { var name: String; var aliases: [String]; var source: String; var dependencies: [String]; var trusted: Bool }
        let entries = try JSONDecoder().decode([Entry].self, from: Data(try evaluate(script).utf8))
        return entries.map { e in
            AdBlockResource(name: e.name, aliases: e.aliases, kind: .init(mime: e.name.hasSuffix(".fn") ? "fn/javascript" : "application/javascript"),
                            content: Data(e.source.utf8).base64EncodedString(), dependencies: e.dependencies, permission: e.trusted ? 1 : 0)
        }
    }

    /// `redirect=` stand-ins: `js/redirect-resources.js` names them, `web_accessible_resources/` holds them.
    static func redirects(_ root: URL) throws -> [AdBlockResource] {
        let script = try bundle(entry: "js/redirect-resources.js", root: root) + """

        JSON.stringify([...__require('js/redirect-resources.js').default].map(([name, d]) =>
          ({ name, aliases: d.alias === undefined ? [] : [].concat(d.alias) })))
        """
        struct Entry: Decodable { var name: String; var aliases: [String] }
        let entries = try JSONDecoder().decode([Entry].self, from: Data(try evaluate(script).utf8))
        let directory = root.appendingPathComponent("web_accessible_resources")
        return entries.compactMap { e in
            guard let data = try? Data(contentsOf: directory.appendingPathComponent(e.name)) else { return nil }
            return AdBlockResource(name: e.name, aliases: e.aliases, kind: .init(mime: mime(for: e.name)),
                                   content: data.base64EncodedString(), dependencies: [], permission: 0)
        }
    }

    static func mime(for name: String) -> String {
        switch (name as NSString).pathExtension.lowercased() {
        case "js": "application/javascript"
        case "html": "text/html"
        case "css": "text/css"
        case "json": "application/json"
        case "txt": "text/plain"
        case "xml": "text/xml"
        case "gif": "image/gif"
        case "png": "image/png"
        case "mp3": "audio/mp3"
        case "mp4": "video/mp4"
        default: "application/octet-stream"
        }
    }

    // MARK: Bundling

    /// The module graph from `entry`, as one script: each module becomes a function of its exports object, run once on
    /// first `__require` (dependencies first, as ES modules would).
    static func bundle(entry: String, root: URL) throws -> String {
        var modules: [String: String] = [:]
        var pending = [entry]
        while let path = pending.popLast() {
            guard modules[path] == nil else { continue }
            guard let source = try? String(contentsOf: root.appendingPathComponent(path), encoding: .utf8) else { throw AssemblyError.missing(path) }
            let module = transform(source, path: path)
            modules[path] = module.body
            pending += module.imports
        }
        var out = """
        const __defs = {}, __cache = {};
        function __require(p) { if (!(p in __cache)) { __cache[p] = {}; __defs[p](__cache[p]); } return __cache[p]; }

        """
        for (path, body) in modules.sorted(by: { $0.key < $1.key }) {
            out += "__defs[\(literal(path))] = function (__exports) {\n\(body)\n};\n"
        }
        return out
    }

    /// Rewrites one module's `import`/`export` statements (the forms uBO uses) into `__require` and an exports object.
    static func transform(_ source: String, path: String) -> (body: String, imports: [String]) {
        var body = source
        var imports: [String] = []
        let base = (path as NSString).deletingLastPathComponent

        // import { a, b as c } from './x.js';  (possibly over several lines)
        body = replace(#"import\s*\{([^}]*)\}\s*from\s*['"]([^'"]+)['"]\s*;?"#, in: body) { groups in
            let target = resolve(groups[2], from: base)
            imports.append(target)
            let names = groups[1].split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
                .map { $0.replacingOccurrences(of: #"\s+as\s+"#, with: ": ", options: .regularExpression) }
            return "const { \(names.joined(separator: ", ")) } = __require(\(literal(target)));"
        }
        // import Name from './x.js';
        body = replace(#"import\s+([A-Za-z_$][\w$]*)\s+from\s*['"]([^'"]+)['"]\s*;?"#, in: body) { groups in
            let target = resolve(groups[2], from: base)
            imports.append(target)
            return "const \(groups[1]) = __require(\(literal(target))).default;"
        }
        // import './x.js';
        body = replace(#"import\s*['"]([^'"]+)['"]\s*;?"#, in: body) { groups in
            let target = resolve(groups[1], from: base)
            imports.append(target)
            return "__require(\(literal(target)));"
        }

        var exported: [String] = []
        body = replace(#"(?m)^(\s*)export\s+((?:async\s+)?function\s*\*?\s*|class\s+|const\s+|let\s+|var\s+)([A-Za-z_$][\w$]*)"#, in: body) { groups in
            exported.append(groups[3])
            return groups[1] + groups[2] + groups[3]
        }
        body = replace(#"(?m)^(\s*)export\s+default\s+"#, in: body) { groups in groups[1] + "__exports.default = " }
        body = replace(#"(?m)^\s*export\s*\{([^}]*)\}\s*;?"#, in: body) { groups in
            groups[1].split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.map { spec in
                let parts = spec.components(separatedBy: " as ").map { $0.trimmingCharacters(in: .whitespaces) }
                return "__exports[\(literal(parts.last!))] = \(parts.first!);"
            }.joined(separator: " ")
        }
        if !exported.isEmpty {
            body += "\nObject.assign(__exports, { \(exported.joined(separator: ", ")) });"
        }
        return (body, imports)
    }

    private static func resolve(_ specifier: String, from base: String) -> String {
        ((base as NSString).appendingPathComponent(specifier) as NSString).standardizingPath
    }

    private static func literal(_ s: String) -> String {
        String(decoding: (try? JSONEncoder().encode(s)) ?? Data("\"\"".utf8), as: UTF8.self)
    }

    private static func replace(_ pattern: String, in text: String, _ transform: ([String]) -> String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        var out = text
        let ns = text as NSString
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).reversed() {
            let groups = (0..<match.numberOfRanges).map { i in
                match.range(at: i).location == NSNotFound ? "" : ns.substring(with: match.range(at: i))
            }
            out = (out as NSString).replacingCharacters(in: match.range, with: transform(groups))
        }
        return out
    }

    private static func evaluate(_ script: String) throws -> String {
        guard let context = JSContext() else { throw AssemblyError.script("no JavaScript context") }
        var failure: String?
        context.exceptionHandler = { _, exception in failure = exception?.toString() }
        let result = context.evaluateScript(script)
        if let failure { throw AssemblyError.script(failure) }
        guard let text = result?.toString(), result?.isString == true else { throw AssemblyError.script("no result") }
        return text
    }
}
