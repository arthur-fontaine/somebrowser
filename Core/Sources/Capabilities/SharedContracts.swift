import Foundation
import SwiftUI

// Contracts shared by several features. A feature *provides* one by registering an instance in
// `CapabilityRegistry`; consumers resolve it and degrade gracefully when it is absent (feature disabled).

/// Turns what the user typed into a URL (address or search), and offers suggestions.
public protocol SearchService: AnyObject {
    /// URL to load for raw input: a URL if it looks like one, otherwise a search.
    func url(for input: String) -> URL?
    /// True when the input looks like an address rather than a query.
    func looksLikeURL(_ input: String) -> Bool
    /// Query suggestions from the search engine (may hit the network; respect the user's setting).
    func suggestions(for query: String) async -> [String]
    /// Display name of the current engine ("DuckDuckGo").
    var engineName: String { get }
}

/// Browsing history store.
public protocol HistoryService: AnyObject {
    func search(_ query: String, limit: Int) -> [HistoryEntry]
    func recent(limit: Int) -> [HistoryEntry]
    func remove(url: URL)
    func clear(since date: Date?)
}

public struct HistoryEntry: Identifiable, Hashable, Sendable {
    public var id: URL { url }
    public var url: URL
    public var title: String
    public var lastVisit: Date
    public var visitCount: Int

    public init(url: URL, title: String, lastVisit: Date, visitCount: Int) {
        self.url = url
        self.title = title
        self.lastVisit = lastVisit
        self.visitCount = visitCount
    }
}

/// One line in the command bar.
public struct OmniboxItem: Identifiable {
    public enum Icon {
        case system(String)
        case favicon(URL?)
        case image(NSImage)
    }

    public var id: String
    public var title: String
    public var subtitle: String?
    public var icon: Icon
    /// Section label ("Switch to Tab", "History", "Action"…).
    public var kind: String
    /// Higher ranks first. Exact/prefix matches of the title should score above fuzzy ones.
    public var score: Double
    /// Keyboard hint shown on the right (e.g. a command's shortcut).
    public var accessory: String?
    public var action: (BrowserWindowState) -> Void

    public init(id: String, title: String, subtitle: String? = nil, icon: Icon, kind: String, score: Double,
                accessory: String? = nil, action: @escaping (BrowserWindowState) -> Void) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.icon = icon
        self.kind = kind
        self.score = score
        self.accessory = accessory
        self.action = action
    }
}

/// Features that add results to the command bar (tabs, history, Safari tabs, actions…).
public protocol OmniboxProvider: AnyObject {
    func items(for query: String, in window: BrowserWindowState) -> [OmniboxItem]
}

/// Simple fuzzy scoring shared by providers so rankings are comparable.
public enum FuzzyMatch {
    /// 0 when no match. Prefix > word-prefix > substring > subsequence.
    public static func score(_ query: String, in text: String) -> Double {
        let q = query.lowercased().trimmingCharacters(in: .whitespaces)
        let t = text.lowercased()
        guard !q.isEmpty, !t.isEmpty else { return 0 }
        if t == q { return 1 }
        if t.hasPrefix(q) { return 0.9 }
        if t.contains(" " + q) || t.contains("/" + q) || t.contains("." + q) { return 0.75 }
        if t.contains(q) { return 0.6 }
        var it = t.makeIterator()
        var matched = 0
        for c in q {
            while let n = it.next() { if n == c { matched += 1; break } }
        }
        return matched == q.count ? 0.3 : 0
    }
}

public extension CapabilityRegistry {
    var search: SearchService? { resolve(SearchService.self) }
    var history: HistoryService? { resolve(HistoryService.self) }
}
