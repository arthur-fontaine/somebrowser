import Foundation
import Testing
@testable import BrowserCore

struct TopHitTests {
    let now = Date(timeIntervalSince1970: 2_000_000_000)

    func entry(_ url: String, _ title: String, visits: Int, daysAgo: Double = 0) -> HistoryEntry {
        HistoryEntry(url: URL(string: url)!, title: title, lastVisit: now.addingTimeInterval(-daysAgo * 86_400), visitCount: visits)
    }

    @Test func domainThenNameThenTitleWord() {
        let sites = TopHit.sites(from: [
            entry("https://x.com/home", "Home / X", visits: 30),
            entry("https://xkcd.com/1", "xkcd: Barrel", visits: 2),
            entry("https://mail.google.com/mail/u/0/#inbox", "Inbox (3) - me@example.com - Gmail", visits: 40),
            entry("https://www.google.com/", "Google", visits: 5),
        ])
        #expect(TopHit.best("x", in: sites, now: now)?.site.host == "x.com")
        #expect(TopHit.best("gmail", in: sites, now: now)?.site.url.absoluteString == "https://mail.google.com/")
        #expect(TopHit.best("goo", in: sites, now: now)?.site.host == "mail.google.com")  // a name of it, visited most
        #expect(TopHit.best("co", in: sites, now: now) == nil)  // nothing starts with it: a top-level domain names nothing
        #expect(TopHit.best("swift ui", in: sites, now: now) == nil)
    }

    @Test func oneLetterAsksForMoreVisits() {
        let once = TopHit.sites(from: [entry("https://xkcd.com/", "xkcd", visits: 1)])
        let score = TopHit.best("x", in: once, now: now)!.score
        #expect(!TopHit.isConfident(score, query: "x"))
        #expect(TopHit.isConfident(score, query: "xk"))
        let old = TopHit.sites(from: [entry("https://xkcd.com/", "xkcd", visits: 1, daysAgo: 60)])
        #expect(!TopHit.isConfident(TopHit.best("xk", in: old, now: now)!.score, query: "xk"))
    }

    @Test func knownBrandsWithoutHistory() {
        #expect(TopHit.alias(for: "gmail")?.host() == "mail.google.com")
        #expect(TopHit.alias(for: "Gma")?.host() == "mail.google.com")
        #expect(TopHit.alias(for: "yt")?.host() == "youtube.com")
        #expect(TopHit.alias(for: "g") == nil)
    }
}
