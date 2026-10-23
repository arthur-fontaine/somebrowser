import Foundation

/// Runtime copy of `feature.json`, generated into the app by forkctl (with fork overrides applied).
/// Also decodable from a `feature.json` file so tests can load the manifest of the feature under test.
public struct FeatureManifest: Decodable, Sendable {
    public var id: String
    public var name: String
    public var summary: String
    public var provides: [String]
    public var requires: [String]
    public var optional: [String]
    public var commands: [CommandDescriptor]
    public var settings: [SettingDescriptor]
    /// The Settings page the settings go on (nil: General).
    public var settingsPage: String?
    /// Where the feature's section sits on its page, lower first.
    public var settingsOrder: Int

    public init(id: String, name: String, summary: String = "", provides: [String] = [], requires: [String] = [],
                optional: [String] = [], commands: [CommandDescriptor] = [], settings: [SettingDescriptor] = [],
                settingsPage: String? = nil, settingsOrder: Int = 100) {
        self.id = id
        self.name = name
        self.summary = summary
        self.provides = provides
        self.requires = requires
        self.optional = optional
        self.commands = commands
        self.settings = settings
        self.settingsPage = settingsPage
        self.settingsOrder = settingsOrder
    }

    enum CodingKeys: String, CodingKey { case id, name, summary, provides, requires, optional, commands, settings, settingsPage, settingsOrder }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try c.decode(String.self, forKey: .id),
            name: try c.decode(String.self, forKey: .name),
            summary: try c.decodeIfPresent(String.self, forKey: .summary) ?? "",
            provides: try c.decodeIfPresent([String].self, forKey: .provides) ?? [],
            requires: try c.decodeIfPresent([String].self, forKey: .requires) ?? [],
            optional: try c.decodeIfPresent([String].self, forKey: .optional) ?? [],
            commands: try c.decodeIfPresent([CommandDescriptor].self, forKey: .commands) ?? [],
            settings: try c.decodeIfPresent([SettingDescriptor].self, forKey: .settings) ?? [],
            settingsPage: try c.decodeIfPresent(String.self, forKey: .settingsPage),
            settingsOrder: try c.decodeIfPresent(Int.self, forKey: .settingsOrder) ?? 100
        )
    }
}

public struct CommandDescriptor: Decodable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var shortcut: String?
    public var alternateShortcuts: [String]
    public var menu: String?
    public var group: String?
    public var order: Int
    public var palette: Bool
    public var keywords: [String]

    public init(id: String, title: String, shortcut: String? = nil, alternateShortcuts: [String] = [], menu: String? = nil,
                group: String? = nil, order: Int = 1000, palette: Bool = true, keywords: [String] = []) {
        self.id = id
        self.title = title
        self.shortcut = shortcut
        self.alternateShortcuts = alternateShortcuts
        self.menu = menu
        self.group = group
        self.order = order
        self.palette = palette
        self.keywords = keywords
    }

    enum CodingKeys: String, CodingKey { case id, title, shortcut, alternateShortcuts, menu, group, order, palette, keywords }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try c.decode(String.self, forKey: .id),
            title: try c.decode(String.self, forKey: .title),
            shortcut: try c.decodeIfPresent(String.self, forKey: .shortcut),
            alternateShortcuts: try c.decodeIfPresent([String].self, forKey: .alternateShortcuts) ?? [],
            menu: try c.decodeIfPresent(String.self, forKey: .menu),
            group: try c.decodeIfPresent(String.self, forKey: .group),
            order: try c.decodeIfPresent(Int.self, forKey: .order) ?? 1000,
            palette: try c.decodeIfPresent(Bool.self, forKey: .palette) ?? true,
            keywords: try c.decodeIfPresent([String].self, forKey: .keywords) ?? []
        )
    }
}

public enum SettingKind: String, Decodable, Sendable {
    case bool, int, double, string, choice
}

/// How Settings edits a string: comma-separated items one per row, or `key=value` items as two columns.
public enum SettingEditor: String, Decodable, Sendable {
    case list, pairs
}

public struct SettingDescriptor: Decodable, Sendable, Identifiable {
    public var id: String { key }
    public var key: String
    public var title: String
    public var kind: SettingKind
    public var defaultValue: SettingValue
    public var description: String?
    public var options: [String]
    /// How each option reads in Settings ("DuckDuckGo"), in `options`' order; else the option, capitalized.
    public var optionTitles: [String]
    public var section: String?
    /// Shown after a number ("days").
    public var unit: String?
    public var editor: SettingEditor?

    public init(key: String, title: String, kind: SettingKind, defaultValue: SettingValue, description: String? = nil,
                options: [String] = [], optionTitles: [String] = [], section: String? = nil, unit: String? = nil,
                editor: SettingEditor? = nil) {
        self.key = key
        self.title = title
        self.kind = kind
        self.defaultValue = defaultValue
        self.description = description
        self.options = options
        self.optionTitles = optionTitles
        self.section = section
        self.unit = unit
        self.editor = editor
    }

    public func title(ofOption option: String) -> String {
        options.firstIndex(of: option).flatMap { optionTitles.indices.contains($0) ? optionTitles[$0] : nil } ?? option.capitalized
    }

    enum CodingKeys: String, CodingKey { case key, title, type, `default`, description, options, optionTitles, section, unit, editor }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            key: try c.decode(String.self, forKey: .key),
            title: try c.decode(String.self, forKey: .title),
            kind: try c.decode(SettingKind.self, forKey: .type),
            defaultValue: try c.decode(SettingValue.self, forKey: .default),
            description: try c.decodeIfPresent(String.self, forKey: .description),
            options: try c.decodeIfPresent([String].self, forKey: .options) ?? [],
            optionTitles: try c.decodeIfPresent([String].self, forKey: .optionTitles) ?? [],
            section: try c.decodeIfPresent(String.self, forKey: .section),
            unit: try c.decodeIfPresent(String.self, forKey: .unit),
            editor: try c.decodeIfPresent(SettingEditor.self, forKey: .editor)
        )
    }
}

public enum SettingValue: Equatable, Sendable, Codable, CustomStringConvertible {
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    /// Raw JSON for structured values (lists, rules…).
    case json(String)

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let i = try? c.decode(Int.self) { self = .int(i) }
        else if let d = try? c.decode(Double.self) { self = .double(d) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else { self = .json("null") }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .bool(let b): try c.encode(b)
        case .int(let i): try c.encode(i)
        case .double(let d): try c.encode(d)
        case .string(let s): try c.encode(s)
        case .json(let s): try c.encode(s)
        }
    }

    public var boolValue: Bool? { if case .bool(let b) = self { b } else { nil } }
    public var intValue: Int? {
        switch self {
        case .int(let i): i
        case .double(let d): Int(d)
        default: nil
        }
    }
    public var doubleValue: Double? {
        switch self {
        case .double(let d): d
        case .int(let i): Double(i)
        default: nil
        }
    }
    public var stringValue: String? {
        switch self {
        case .string(let s), .json(let s): s
        default: nil
        }
    }

    public var description: String {
        switch self {
        case .bool(let b): String(b)
        case .int(let i): String(i)
        case .double(let d): String(d)
        case .string(let s): s
        case .json(let s): s
        }
    }
}

/// One enabled feature, as listed by the generated `FeatureRegistry`.
public struct FeatureRegistration {
    public var manifest: FeatureManifest
    public var make: (FeatureContext) -> BrowserFeature

    public init(manifest: FeatureManifest, make: @escaping (FeatureContext) -> BrowserFeature) {
        self.manifest = manifest
        self.make = make
    }
}

/// A feature's entry point (`entry` in feature.json).
public protocol BrowserFeature: AnyObject {
    init(context: FeatureContext)
    /// Register commands, hooks, capabilities and views. Keep it cheap; defer heavy work.
    func activate()
    /// Called before quit (flush state).
    func deactivate()
}

public extension BrowserFeature {
    func deactivate() {}
}
