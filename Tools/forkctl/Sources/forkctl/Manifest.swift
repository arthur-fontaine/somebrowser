import Foundation

/// `Features/<Name>/feature.json` — the single static description of a feature.
/// Swift code implements behaviour; everything a fork may want to inspect or override lives here.
struct FeatureManifest: Codable, Equatable {
    var id: String
    var name: String
    var summary: String
    /// Swift type implementing `BrowserFeature` in the feature's `Sources/`.
    var entry: String
    /// Capability ids this feature registers (other features resolve them, never import the module).
    var provides: [String] = []
    /// Capabilities that must be provided by some enabled feature.
    var requires: [String] = []
    /// Capabilities used when present.
    var optional: [String] = []
    /// Engine ids this feature works with; `["*"]` means any.
    var engines: [String] = ["*"]
    /// Upstream feature id this (fork) feature replaces.
    var replaces: String?
    /// Disabled unless a fork enables it explicitly.
    var enabledByDefault: Bool = true
    var commands: [CommandSpec] = []
    var settings: [SettingSpec] = []
    /// Extra Swift module dependencies inside the repo (e.g. a native bridge target).
    var modules: [String] = []
    /// Linked system frameworks.
    var frameworks: [String] = []
    /// A Rust crate (directory relative to the feature) built as a staticlib; its `include/` holds the C header
    /// and a module map, imported as `<Target>Native`.
    var cargo: String?

    enum CodingKeys: String, CodingKey {
        case id, name, summary, entry, provides, requires, optional, engines, replaces, enabledByDefault,
             commands, settings, modules, frameworks, cargo
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        summary = try c.decodeIfPresent(String.self, forKey: .summary) ?? ""
        entry = try c.decode(String.self, forKey: .entry)
        provides = try c.decodeIfPresent([String].self, forKey: .provides) ?? []
        requires = try c.decodeIfPresent([String].self, forKey: .requires) ?? []
        optional = try c.decodeIfPresent([String].self, forKey: .optional) ?? []
        engines = try c.decodeIfPresent([String].self, forKey: .engines) ?? ["*"]
        replaces = try c.decodeIfPresent(String.self, forKey: .replaces)
        enabledByDefault = try c.decodeIfPresent(Bool.self, forKey: .enabledByDefault) ?? true
        commands = try c.decodeIfPresent([CommandSpec].self, forKey: .commands) ?? []
        settings = try c.decodeIfPresent([SettingSpec].self, forKey: .settings) ?? []
        modules = try c.decodeIfPresent([String].self, forKey: .modules) ?? []
        frameworks = try c.decodeIfPresent([String].self, forKey: .frameworks) ?? []
        cargo = try c.decodeIfPresent(String.self, forKey: .cargo)
    }

    init(id: String, name: String, summary: String = "", entry: String) {
        self.id = id
        self.name = name
        self.summary = summary
        self.entry = entry
    }
}

struct CommandSpec: Codable, Equatable {
    var id: String
    var title: String
    /// e.g. `cmd+shift+t`. Overridable per fork in `fork.json` → `shortcuts`.
    var shortcut: String?
    /// Additional shortcuts for the same command (e.g. `cmd+[` and `cmd+left`).
    var alternateShortcuts: [String]?
    /// Native menu bar placement: `File`, `Edit`, `View`, `History`, `Tabs`, `Window`, `Help`, or nil.
    var menu: String?
    /// Items with the same group are kept together, separated from other groups.
    var group: String?
    var order: Int?
    /// Listed in the command bar (default true).
    var palette: Bool?
    /// Extra search keywords for the command bar.
    var keywords: [String]?
}

struct SettingSpec: Codable, Equatable {
    var key: String
    var title: String
    /// `bool`, `int`, `double`, `string`, `choice`
    var type: String
    var `default`: JSONValue
    var description: String?
    var options: [String]?
    /// How each option reads in Settings, in `options`' order.
    var optionTitles: [String]?
    var section: String?
}

/// Minimal JSON value so manifests and overrides can carry typed defaults without a dependency.
enum JSONValue: Codable, Equatable {
    case bool(Bool), int(Int), double(Double), string(String), array([JSONValue]), object([String: JSONValue]), null

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let i = try? c.decode(Int.self) { self = .int(i) }
        else if let d = try? c.decode(Double.self) { self = .double(d) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .bool(let b): try c.encode(b)
        case .int(let i): try c.encode(i)
        case .double(let d): try c.encode(d)
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        case .null: try c.encodeNil()
        }
    }

    /// Swift literal for `SettingValue` in generated code.
    var swiftSettingValue: String {
        switch self {
        case .bool(let b): return ".bool(\(b))"
        case .int(let i): return ".int(\(i))"
        case .double(let d): return ".double(\(d))"
        case .string(let s): return ".string(\(swiftStringLiteral(s)))"
        case .null: return ".string(\"\")"
        case .array, .object:
            let data = (try? JSONEncoder().encode(self)) ?? Data()
            return ".json(\(swiftStringLiteral(String(decoding: data, as: UTF8.self))))"
        }
    }
}

/// Branding: the only place a product name, bundle id, scheme or icon is defined.
struct BrandConfig: Codable, Equatable {
    var name: String?
    var bundleId: String?
    var urlScheme: String?
    var userAgentBrand: String?
    var icon: String?
    var homepage: String?
    var repository: String?
    var copyright: String?

    func merged(over base: BrandConfig) -> BrandConfig {
        BrandConfig(
            name: name ?? base.name,
            bundleId: bundleId ?? base.bundleId,
            urlScheme: urlScheme ?? base.urlScheme,
            userAgentBrand: userAgentBrand ?? base.userAgentBrand,
            icon: icon ?? base.icon,
            homepage: homepage ?? base.homepage,
            repository: repository ?? base.repository,
            copyright: copyright ?? base.copyright
        )
    }
}

/// `Defaults/fork.json` (upstream defaults) and `Fork/fork.json` (fork overrides) share this schema.
struct ForkConfig: Codable, Equatable {
    struct FeatureSelection: Codable, Equatable {
        var enable: [String]?
        var disable: [String]?
    }

    var brand: BrandConfig?
    var engine: String?
    var features: FeatureSelection?
    /// command id → shortcut string (`""` removes the shortcut).
    var shortcuts: [String: String]?
    /// setting key → default value override.
    var settings: [String: JSONValue]?
    /// Extra command-line switches / engine options.
    var engineOptions: [String: JSONValue]?
}

func swiftStringLiteral(_ s: String) -> String {
    var out = "\""
    for ch in s.unicodeScalars {
        switch ch {
        case "\"": out += "\\\""
        case "\\": out += "\\\\"
        case "\n": out += "\\n"
        case "\t": out += "\\t"
        default: out.unicodeScalars.append(ch)
        }
    }
    return out + "\""
}
