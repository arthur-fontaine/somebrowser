@testable import EngineCEF
import Testing

struct ChromeOpenedURLTests {
    @Test func adoptsPagesOpenedByExtensions() {
        #expect(CEFEngine.adoptsChromeOpenedURL("chrome-extension://ddkjiahejlhfcafbddmgiahcphecmpfh/dashboard.html"))
        #expect(CEFEngine.adoptsChromeOpenedURL("https://example.com/welcome"))
        #expect(CEFEngine.adoptsChromeOpenedURL("chrome://extensions/"))
    }

    @Test func ignoresChromesOwnNewTabPage() {
        #expect(!CEFEngine.adoptsChromeOpenedURL("chrome://newtab/"))
        #expect(!CEFEngine.adoptsChromeOpenedURL("chrome://new-tab-page/"))
    }
}
