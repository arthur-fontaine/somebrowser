@testable import EngineCEF
import Foundation
import Testing

struct RestoredHistoryTests {
    func entry(_ name: String) -> NavigationEntry { NavigationEntry(url: URL(string: "https://\(name).example/")!, title: name) }

    @Test func roundTripsAroundChromiumsOwnList() throws {
        let restored = RestoredHistory(back: [entry("a")], forward: [entry("z")])
        // Chromium has b, c (current, last): the restored forward list still follows.
        let data = try #require(RestoredHistory.encode(native: [entry("b"), entry("c")], index: 1, around: restored))
        let decoded = try #require(RestoredHistory.decode(data))
        #expect(decoded.current == entry("c"))
        #expect(decoded.history == RestoredHistory(back: [entry("a"), entry("b")], forward: [entry("z")]))

        // Not at Chromium's last entry: its own forward entries replace the restored ones.
        let middle = try #require(RestoredHistory.encode(native: [entry("b"), entry("c")], index: 0, around: restored))
        #expect(RestoredHistory.decode(middle)?.history == RestoredHistory(back: [entry("a")], forward: [entry("c")]))
    }

    @Test func rejectsOtherFormats() {
        #expect(RestoredHistory.decode(Data("not json".utf8)) == nil)
        #expect(RestoredHistory.decode(Data(#"{"v":1,"entries":[],"index":0}"#.utf8)) == nil)
        #expect(RestoredHistory.encode(native: [], index: 0, around: RestoredHistory()) == nil)
    }

    @Test func stepsThroughTheRestoredEntries() {
        var history = RestoredHistory(back: [entry("a"), entry("b")], forward: [])
        #expect(history.stepBack(from: entry("c")) == entry("b"))
        #expect(history.stepBack(from: entry("b")) == entry("a"))
        #expect(history.stepBack(from: entry("a")) == nil)
        #expect(history.forward == [entry("b"), entry("c")])
        #expect(history.stepForward(from: entry("a")) == entry("b"))
        #expect(history == RestoredHistory(back: [entry("a")], forward: [entry("c")]))
    }
}
