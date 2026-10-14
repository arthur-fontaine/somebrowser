import Foundation

nonisolated struct NavigationEntry: Codable, Equatable, Sendable {
    var url: URL
    var title: String
}

/// Back/forward entries a page was restored with. Chromium can't be handed a history, so a restored page starts with
/// one entry and these live beside it: Back past Chromium's first entry and Forward past its last step through them
/// (the page replaces its own entry, so Chromium's list doesn't grow).
nonisolated struct RestoredHistory: Equatable, Sendable {
    /// Oldest first.
    var back: [NavigationEntry] = []
    /// Next first.
    var forward: [NavigationEntry] = []

    var isEmpty: Bool { back.isEmpty && forward.isEmpty }

    private struct Stored: Codable {
        var v = 1
        var entries: [NavigationEntry]
        var index: Int
    }

    /// The whole list (restored entries around Chromium's) and the current position.
    static func encode(native: [NavigationEntry], index: Int, around restored: RestoredHistory) -> Data? {
        guard native.indices.contains(index) else { return nil }
        let atEnd = index == native.count - 1
        let entries = restored.back + native + (atEnd ? restored.forward : [])
        return try? JSONEncoder().encode(Stored(entries: entries, index: restored.back.count + index))
    }

    /// The entry to load and the history around it.
    static func decode(_ data: Data) -> (current: NavigationEntry, history: RestoredHistory)? {
        guard let stored = try? JSONDecoder().decode(Stored.self, from: data), stored.v == 1,
              stored.entries.indices.contains(stored.index) else { return nil }
        let i = stored.index
        return (stored.entries[i], RestoredHistory(back: Array(stored.entries[..<i]), forward: Array(stored.entries[(i + 1)...])))
    }

    /// Back from Chromium's first entry: the entry to show instead of `current`.
    mutating func stepBack(from current: NavigationEntry) -> NavigationEntry? {
        guard let previous = back.popLast() else { return nil }
        forward.insert(current, at: 0)
        return previous
    }

    /// Forward from Chromium's last entry.
    mutating func stepForward(from current: NavigationEntry) -> NavigationEntry? {
        guard !forward.isEmpty else { return nil }
        back.append(current)
        return forward.removeFirst()
    }
}
