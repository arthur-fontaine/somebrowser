import FeatureAdblockNative
import Foundation

/// A compiled Brave adblock-rust engine. Matching is read-only and thread-safe (requests are checked on the
/// engine's network thread).
nonisolated final class AdBlockEngine: @unchecked Sendable {
    private let handle: OpaquePointer

    /// Compiles filter list text (slow: do it off the main thread, then cache with `serialized`).
    init(lists: String) {
        handle = adb_engine_new(lists)
    }

    /// Restores a compiled engine; nil if the data comes from another adblock-rust version.
    init?(serialized data: Data) {
        guard let h = data.withUnsafeBytes({ adb_engine_deserialize($0.bindMemory(to: UInt8.self).baseAddress, data.count) }) else { return nil }
        handle = h
    }

    deinit { adb_engine_free(handle) }

    var serialized: Data {
        var length = 0
        guard let bytes = adb_engine_serialize(handle, &length) else { return Data() }
        defer { adb_bytes_free(bytes, length) }
        return Data(bytes: bytes, count: length)
    }

    enum Verdict: Equatable {
        case allow
        case block
        /// Serve this instead (a resource body from the lists' `redirect=` option, as a data: URL).
        case redirect(String)
        /// Load this URL instead (tracking parameters removed).
        case rewrite(URL)
    }

    /// `type` uses adblock-rust names: document, subdocument, script, stylesheet, image, font, xmlhttprequest…
    func check(url: String, source: String, type: String) -> Verdict {
        var redirect: UnsafeMutablePointer<CChar>?
        var rewritten: UnsafeMutablePointer<CChar>?
        let blocked = adb_check(handle, url, source, type, &redirect, &rewritten) == 1
        defer { adb_string_free(redirect); adb_string_free(rewritten) }
        if blocked, let redirect { return .redirect(String(cString: redirect)) }
        if blocked { return .block }
        if let rewritten, let u = URL(string: String(cString: rewritten)) { return .rewrite(u) }
        return .allow
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

    /// Apple content-blocker rules for the same lists (WebKit engine).
    static func contentBlockingRules(lists: String) -> String {
        guard let s = adb_content_blocking(lists) else { return "[]" }
        defer { adb_string_free(s) }
        return String(cString: s)
    }

    private static func decode<T: Decodable>(_ s: UnsafeMutablePointer<CChar>?) -> T? {
        guard let s else { return nil }
        defer { adb_string_free(s) }
        return try? JSONDecoder().decode(T.self, from: Data(String(cString: s).utf8))
    }
}
