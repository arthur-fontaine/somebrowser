import BrowserCore
import BrowserTesting
import Foundation
import Testing
@testable import FeatureErrorPages

@MainActor
struct ErrorPagesFeatureTests {
    func harness() throws -> TestHarness { try TestHarness(features: [ErrorPagesFeature.self], manifestDirectory: #filePath) }

    @Test func pagesSayWhatFailed() throws {
        let h = try harness()
        let url = URL(string: "https://down.example/a")!
        let network = try #require(h.runtime.engine.hooks.errorPage?(PageLoadError(url: url, kind: .network, description: "ERR_CONNECTION_REFUSED", tab: nil)))
        #expect(network.contains("Can’t Open down.example") && network.contains("Try Again") && !network.contains("Visit Anyway"))
        let hostile = ErrorPage.html(for: PageLoadError(url: URL(string: "https://x.example")!, kind: .network, description: "<script>x</script>", tab: nil))
        #expect(!hostile.contains("<script>x"))
    }

    /// Visit Anyway accepts the certificate of the site the page was shown for; a link made by a page doesn't.
    @Test func visitAnywayOnlyFromItsOwnPage() async throws {
        let h = try harness()
        let tab = h.openTab("https://good.example")
        let page = h.fakeTab(tab)
        let bad = URL(string: "https://bad.example/x")!
        let html = try #require(h.runtime.engine.hooks.errorPage?(PageLoadError(url: bad, kind: .certificate, description: "ERR_CERT_DATE_INVALID", tab: page)))
        #expect(html.contains("Visit Anyway"))
        func visit(_ target: URL) -> NavigationPolicy {
            var c = URLComponents(string: "https://\(ErrorPagesFeature.visitAnywayHost)/")!
            c.queryItems = [URLQueryItem(name: "to", value: target.absoluteString)]
            return h.runtime.engine.hooks.decide(NavigationAction(url: c.url!, sourceTab: page, userGesture: true))
        }
        #expect(visit(URL(string: "https://bank.example/")!) == .cancel)
        #expect(!h.runtime.engine.hooks.acceptedInvalidCertificates.contains("bank.example"))
        #expect(visit(bad) == .handled)
        #expect(h.runtime.engine.hooks.acceptedInvalidCertificates == ["bad.example"])
        for _ in 0..<50 where page.state.url != bad { try await Task.sleep(for: .milliseconds(10)) }
        #expect(page.state.url == bad)
        #expect(visit(bad) == .cancel)  // used once
    }
}
