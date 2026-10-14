import Foundation
import Observation

/// Typed, namespaced settings declared in feature.json. Each key is observed independently, so a view
/// reading `adblock.enabled` is not invalidated when `pip.autoPopOut` changes.
public final class SettingsStore {
    @Observable
    final class Box {
        var value: SettingValue
        init(_ value: SettingValue) { self.value = value }
    }

    public private(set) var descriptors: [SettingDescriptor] = []
    private var boxes: [String: Box] = [:]
    private var defaults: [String: SettingValue] = [:]
    private let storage: UserDefaults?
    private var observers: [String: [(SettingValue) -> Void]] = [:]
    private let prefix = "setting."

    /// `storage` nil keeps values in memory (tests).
    public init(storage: UserDefaults?) {
        self.storage = storage
    }

    public func register(_ descriptors: [SettingDescriptor], overrides: [String: SettingValue] = [:]) {
        for d in descriptors {
            let def = overrides[d.key] ?? d.defaultValue
            defaults[d.key] = def
            if let i = self.descriptors.firstIndex(where: { $0.key == d.key }) { self.descriptors[i] = d } else { self.descriptors.append(d) }
            let stored = storage?.data(forKey: prefix + d.key).flatMap { try? JSONDecoder().decode(SettingValue.self, from: $0) }
            boxes[d.key] = Box(stored ?? def)
        }
    }

    public func descriptor(_ key: String) -> SettingDescriptor? { descriptors.first { $0.key == key } }

    public func value(_ key: String) -> SettingValue {
        guard let box = boxes[key] else {
            assertionFailure("setting '\(key)' is not declared in any feature.json")
            return .string("")
        }
        return box.value
    }

    public func bool(_ key: String) -> Bool { value(key).boolValue ?? false }
    public func int(_ key: String) -> Int { value(key).intValue ?? 0 }
    public func double(_ key: String) -> Double { value(key).doubleValue ?? 0 }
    public func string(_ key: String) -> String { value(key).stringValue ?? "" }

    /// Decodes a JSON-valued (or string) setting.
    public func decode<T: Decodable>(_ type: T.Type, _ key: String) -> T? {
        guard let s = value(key).stringValue else { return nil }
        return try? JSONDecoder().decode(T.self, from: Data(s.utf8))
    }

    public func set(_ key: String, _ value: SettingValue) {
        guard let box = boxes[key] else { assertionFailure("setting '\(key)' is not declared"); return }
        guard box.value != value else { return }
        box.value = value
        if value == defaults[key] {
            storage?.removeObject(forKey: prefix + key)
        } else if let data = try? JSONEncoder().encode(value) {
            storage?.set(data, forKey: prefix + key)
        }
        observers[key]?.forEach { $0(value) }
    }

    public func set(_ key: String, _ value: Bool) { set(key, .bool(value)) }

    public func encode<T: Encodable>(_ value: T, _ key: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        set(key, .json(String(decoding: data, as: UTF8.self)))
    }

    public func reset(_ key: String) {
        if let d = defaults[key] { set(key, d) }
    }

    public func defaultValue(_ key: String) -> SettingValue? { defaults[key] }

    /// Calls `observer` after every change of `key`.
    public func observe(_ key: String, _ observer: @escaping (SettingValue) -> Void) {
        observers[key, default: []].append(observer)
    }
}
