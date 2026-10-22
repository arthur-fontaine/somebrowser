import BrowserCore
import BrowserTesting
import Foundation
import Testing
@testable import FeatureSearch

@MainActor
struct SearchTests {
    func service() throws -> (TestHarness, SearchService) {
        let h = try TestHarness(features: [SearchFeature.self], manifestDirectory: #filePath)
        return (h, try #require(h.runtime.capabilities.search))
    }

    @Test func detectsURLs() throws {
        let (_, s) = try service()
        for yes in ["example.com", "https://x.y/z", "localhost:3000", "192.168.1.1", "sub.domain.co.uk/path?q=1", "about:blank", "file:///tmp/a.html"] {
            #expect(s.looksLikeURL(yes), "\(yes)")
        }
        for no in ["hello world", "swift", "what is 2.5", "a.b c", "1.5"] {
            #expect(!s.looksLikeURL(no), "\(no)")
        }
    }

    @Test func buildsURLs() throws {
        let (_, s) = try service()
        #expect(s.url(for: "example.com")?.absoluteString == "https://example.com")
        #expect(s.url(for: "localhost:3000/a")?.absoluteString == "http://localhost:3000/a")
        #expect(s.url(for: "  https://x.org/p  ")?.absoluteString == "https://x.org/p")
        #expect(s.url(for: "swift & rust")?.absoluteString == "https://duckduckgo.com/?q=swift%20%26%20rust")
    }

    @Test func keywordSiteSearch() throws {
        let (_, s) = try service()
        #expect(s.url(for: "yt lo-fi")?.absoluteString == "https://www.youtube.com/results?search_query=lo-fi")
        #expect(s.url(for: "yt")?.host() == "duckduckgo.com")
    }

    @Test func engineIsASetting() throws {
        let (h, s) = try service()
        h.runtime.settings.set("search.engine", .string("kagi"))
        #expect(s.engineName == "Kagi")
        #expect(s.url(for: "cats")?.host() == "kagi.com")
    }

    /// Chrome edits a results page's terms, not its URL: the current engine's, on its host or a country's.
    @Test func readsTheTermsOfAResultsPage() throws {
        let (h, s) = try service()
        h.runtime.settings.set("search.engine", .string("google"))
        #expect(s.searchTerms(in: URL(string: "https://www.google.com/search?q=hello+world&sca_esv=1&ei=x")!) == "hello world")
        #expect(s.searchTerms(in: URL(string: "https://www.google.fr/search?client=safari&q=caf%C3%A9%20%26%20tea")!) == "café & tea")
        #expect(s.searchTerms(in: URL(string: "https://www.google.co.uk/search?q=x")!) == "x")
        for no in ["https://www.google.com/maps?q=paris", "https://www.google.com/search?tbm=isch", "https://google.evil.com/search?q=x",
                   "https://duckduckgo.com/?q=cats"] {
            #expect(s.searchTerms(in: URL(string: no)!) == nil, "\(no)")
        }
        h.runtime.settings.set("search.engine", .string("duckduckgo"))
        #expect(s.searchTerms(in: URL(string: "https://duckduckgo.com/?q=cats&ia=web")!) == "cats")
    }

    @Test func parsesBothSuggestionFormats() {
        #expect(DefaultSearchService.parseSuggestions(Data(#"["sw",["swift","swiftui"]]"#.utf8)) == ["swift", "swiftui"])
        #expect(DefaultSearchService.parseSuggestions(Data(#"[{"phrase":"a"},{"phrase":"b"}]"#.utf8)) == ["a", "b"])
    }

    @Test func suggestionsRespectPrivacySetting() async throws {
        let (h, s) = try service()
        let concrete = try #require(s as? DefaultSearchService)
        nonisolated(unsafe) var fetched = 0
        concrete.fetch = { _ in fetched += 1; return Data(#"["q",["x"]]"#.utf8) }
        #expect(await s.suggestions(for: "query") == ["x"])
        h.runtime.settings.set("search.suggestions", false)
        #expect(await s.suggestions(for: "query").isEmpty)
        #expect(fetched == 1)
    }
}

@MainActor
struct DefaultSearchHookTests {
    @Test func engineUIFollowsTheChosenEngine() throws {
        let h = try TestHarness(features: [SearchFeature.self], manifestDirectory: #filePath)
        #expect(h.engine.hooks.defaultSearch == DefaultSearchEngine(name: "DuckDuckGo", template: "https://duckduckgo.com/?q=%s"))
        h.runtime.settings.set("search.engine", .string("kagi"))
        #expect(h.engine.hooks.defaultSearch?.name == "Kagi")
    }
}
