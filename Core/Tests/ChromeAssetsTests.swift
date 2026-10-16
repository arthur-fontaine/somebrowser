import AppKit
import Foundation
import Testing
@testable import BrowserCore

@MainActor
struct FaviconStoreTests {
    func image(_ color: NSColor) -> NSImage {
        NSImage(size: NSSize(width: 16, height: 16), flipped: false) { rect in
            color.setFill()
            rect.fill()
            return true
        }
    }

    @Test func oneIconPerSiteKeptOnDisk() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("favicons-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = FaviconStore(directory: dir)
        store.store(image(.red), for: URL(string: "https://www.example.com/a")!)
        #expect(store.image(for: URL(string: "https://example.com/b")) != nil)
        #expect(store.image(for: URL(string: "https://other.example/")) == nil)
        #expect(store.image(for: URL(string: "file:///tmp/x.html")) == nil)
        // Written off the main thread; a new store reads it back.
        try #require(waitUntil { FileManager.default.fileExists(atPath: dir.appendingPathComponent("example.com.png").path) })
        #expect(FaviconStore(directory: dir).image(for: URL(string: "http://example.com/")) != nil)
    }

    @Test func darkIconsAreToldApart() {
        #expect(IconTone.isDark(image(.black)))
        #expect(!IconTone.isDark(image(.white)))
        #expect(!IconTone.isDark(image(.orange)))
    }

    @Test func choicesReadAsTheirTitles() {
        let d = SettingDescriptor(key: "k", title: "K", kind: .choice, defaultValue: .string("a"), options: ["duckduckgo", "x"],
                                  optionTitles: ["DuckDuckGo"])
        #expect(d.title(ofOption: "duckduckgo") == "DuckDuckGo")
        #expect(d.title(ofOption: "x") == "X")  // no title given
    }

    @Test func blankTabsAndSitesAreNamedAlike() {
        #expect(BrowserTab(url: nil).displayTitle == "Start Page")
        #expect(SiteTile.name(for: URL(string: "https://www.github.com/x")) == "github.com")
        #expect(SiteTile.name(for: URL(string: "https://developer.apple.com/")) == "apple.com")
        #expect(SiteTile.name(for: URL(string: "https://news.bbc.co.uk/")) == "bbc.co.uk")
        #expect(SiteTile.name(for: URL(string: "http://127.0.0.1:8000/")) == "127.0.0.1")
        #expect(SiteTile.name(for: nil) == nil)
    }

    private func waitUntil(_ condition: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(5)
        while Date() < end {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        return false
    }
}
