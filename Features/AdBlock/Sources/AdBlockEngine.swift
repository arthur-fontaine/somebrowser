import FeatureAdblockNative
import Foundation

/// A compiled Brave adblock-rust engine. Matching is read-only and thread-safe (requests are checked on the
/// engine's network thread).
nonisolated final class AdBlockEngine: @unchecked Sendable {
    private let handle: OpaquePointer

    /// Compiles filter list text (slow: do it off the main thread, then cache with `serialized`). `trustedLists` may use
    /// trusted scriptlets (uBlock Origin's own lists).
    init(lists: String, trustedLists: String? = nil) {
        handle = adb_engine_new(lists, trustedLists)
    }

    /// Restores a compiled engine; nil if the data comes from another adblock-rust version.
    init?(serialized data: Data) {
        guard let h = data.withUnsafeBytes({ adb_engine_deserialize($0.bindMemory(to: UInt8.self).baseAddress, data.count) }) else { return nil }
        handle = h
    }

    deinit { adb_engine_free(handle) }

    /// Loads Brave's redirect and scriptlet resources (`resources.json`); they aren't part of `serialized`. Call before
    /// sharing the engine. Returns how many were loaded, nil if the JSON doesn't parse.
    @discardableResult
    func useResources(json: String) -> Int? {
        let count = adb_engine_use_resources(handle, json)
        return count < 0 ? nil : Int(count)
    }

    var serialized: Data {
        var length = 0
        guard let bytes = adb_engine_serialize(handle, &length) else { return Data() }
        defer { adb_bytes_free(bytes, length) }
        return Data(bytes: bytes, count: length)
    }

    enum Verdict: Equatable {
        case allow
        case block
        /// Answer with this instead (a stand-in from the lists' `redirect=` option, e.g. a no-op script).
        case respond(mimeType: String, body: Data)
        /// Load this URL instead (tracking parameters removed).
        case rewrite(URL)
    }

    /// `type` uses adblock-rust names: document, subdocument, script, stylesheet, image, font, xmlhttprequest…
    func check(url: String, source: String, type: String) -> Verdict {
        var redirect: UnsafeMutablePointer<CChar>?
        var rewritten: UnsafeMutablePointer<CChar>?
        let blocked = adb_check(handle, url, source, type, &redirect, &rewritten) == 1
        defer { adb_string_free(redirect); adb_string_free(rewritten) }
        if blocked, let redirect, let (mimeType, body) = Self.parseDataURL(String(cString: redirect)) { return .respond(mimeType: mimeType, body: body) }
        if blocked { return .block }
        if let rewritten, let u = URL(string: String(cString: rewritten)) { return .rewrite(u) }
        return .allow
    }

    /// adblock-rust hands redirect resources over as `data:<mime>;base64,<body>`.
    static func parseDataURL(_ url: String) -> (mimeType: String, body: Data)? {
        guard url.hasPrefix("data:"), let comma = url.firstIndex(of: ",") else { return nil }
        let meta = url[url.index(url.startIndex, offsetBy: 5)..<comma].split(separator: ";")
        let payload = String(url[url.index(after: comma)...])
        let body = meta.contains("base64") ? Data(base64Encoded: payload) : payload.removingPercentEncoding.map { Data($0.utf8) }
        return body.map { (meta.first.map(String.init) ?? "text/plain", $0) }
    }

    struct Cosmetic: Decodable, Equatable {
        var hide_selectors: [String]
        var exceptions: [String]
        var injected_script: String
        var generichide: Bool
    }

    func cosmetic(for url: String) -> Cosmetic? {
        Self.decode(adb_cosmetic(handle, url))
    }

    /// Generic hide selectors matching these classes and ids (unless the page's exceptions cancel them).
    func hiddenSelectors(classes: [String], ids: [String], exceptions: [String]) -> [String] {
        let json = { (v: [String]) in String(decoding: (try? JSONEncoder().encode(v)) ?? Data("[]".utf8), as: UTF8.self) }
        return Self.decode(adb_hidden_selectors(handle, json(classes), json(ids), json(exceptions))) ?? []
    }

    /// Apple content-blocker rules for the same lists (WebKit engine), fitted to WebKit's limit.
    static func contentBlockingRules(lists: String) -> String {
        guard let s = adb_content_blocking(lists) else { return "[]" }
        defer { adb_string_free(s) }
        return fitContentRules(String(cString: s))
    }

    /// WebKit rejects a rule list over 150,000 rules, and exceptions (`ignore-previous-rules`) only cancel rules
    /// of their own list, so the list can't be split. Element hiding is dropped (the injected cosmetic styles
    /// already do it on every engine); past `limit`, the last network rules go, never the exceptions.
    static func fitContentRules(_ json: String, limit: Int = 145_000) -> String {
        guard let rules = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [[String: Any]] else { return "[]" }
        let action = { (rule: [String: Any]) in (rule["action"] as? [String: Any])?["type"] as? String }
        var kept = rules.filter { action($0) != "css-display-none" }
        if kept.count > limit {
            var excess = kept.count - limit
            var drop = Set<Int>()
            for i in stride(from: kept.count - 1, through: 0, by: -1) where excess > 0 && action(kept[i]) != "ignore-previous-rules" {
                drop.insert(i)
                excess -= 1
            }
            kept = kept.enumerated().filter { !drop.contains($0.offset) }.map(\.element)
        }
        let data = (try? JSONSerialization.data(withJSONObject: kept)) ?? Data("[]".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    private static func decode<T: Decodable>(_ s: UnsafeMutablePointer<CChar>?) -> T? {
        guard let s else { return nil }
        defer { adb_string_free(s) }
        return try? JSONDecoder().decode(T.self, from: Data(String(cString: s).utf8))
    }
}
