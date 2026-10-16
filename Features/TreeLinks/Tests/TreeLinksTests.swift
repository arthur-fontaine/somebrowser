import BrowserCore
import BrowserTesting
import Foundation
import Testing
@testable import FeatureTreeLinks

@MainActor
struct TreeLinksTests {
    func harness() throws -> TestHarness { try TestHarness(features: [TreeLinksFeature.self], manifestDirectory: #filePath) }

    func click(_ tab: BrowserTab, _ url: String, _ h: TestHarness, gesture: Bool = true) -> NavigationPolicy {
        h.engine.hooks.decide(NavigationAction(url: URL(string: url)!, sourceTab: tab.engineTab, userGesture: gesture))
    }

    @Test func linkClicksBranch() throws {
        let h = try harness()
        let a = h.openTab("https://news.example/")
        #expect(click(a, "https://news.example/story/1", h) == .openInNewTab(URL(string: "https://news.example/story/1")!))
        #expect(click(a, "https://other.example/", h) == .openInNewTab(URL(string: "https://other.example/")!))
    }

    /// A form sent to another site (Google Lens's image upload) stays in its tab: a new tab would load the URL without
    /// the form's data.
    @Test func formsStayInPlace() throws {
        let h = try harness()
        let a = h.openTab("https://www.google.example/")
        let upload = NavigationAction(url: URL(string: "https://lens.google.example/upload")!, sourceTab: a.engineTab, userGesture: true,
                                      isFormSubmission: true)
        #expect(h.engine.hooks.decide(upload) == .allow)
    }

    @Test func scriptsAnchorsAndNonWebLinksStayInPlace() throws {
        let h = try harness()
        let a = h.openTab("https://docs.example/page")
        #expect(click(a, "https://docs.example/page#section", h) == .allow)
        #expect(click(a, "https://docs.example/next", h, gesture: false) == .allow)
        #expect(click(a, "mailto:someone@example.com", h) == .allow)
    }

    @Test func exclusionsSameSiteAndPerTabToggle() throws {
        let h = try harness()
        let mail = h.openTab("https://mail.google.com/mail/u/0")
        #expect(click(mail, "https://mail.google.com/mail/u/0#inbox/123", h) == .allow)
        #expect(click(mail, "https://news.example/", h) == .allow)  // the source app opens links in place
        let doc = h.openTab("https://site.example/a")
        h.runtime.settings.set("tree-links.sameSite", false)
        #expect(click(doc, "https://site.example/b", h) == .allow)
        doc.opensLinksInPlace = true
        #expect(click(doc, "https://elsewhere.example/", h) == .allow)
        h.runtime.settings.set("tree-links.enabled", false)
        doc.opensLinksInPlace = false
        #expect(click(doc, "https://elsewhere.example/", h) == .allow)
    }

    @Test func alreadyOpenPagesAreFocused() async throws {
        let h = try harness()
        let existing = h.openTab("https://wiki.example/Swift")
        let a = h.openTab("https://blog.example/")
        #expect(click(a, "https://wiki.example/Swift#history", h) == .handled)
        try await Task.sleep(for: .milliseconds(30))
        #expect(h.selectedTab?.id == existing.id)
    }

    @Test func subdomainExclusionMatching() {
        #expect(TreeLinksFeature.matches("app.slack.com", ["slack.com"]))
        #expect(!TreeLinksFeature.matches("notslack.com", ["slack.com"]))
        #expect(LinkHoverBox.display(URL(string: "https://www.example.com/a?b=1")!) == "example.com/a?b=1")
    }
}
