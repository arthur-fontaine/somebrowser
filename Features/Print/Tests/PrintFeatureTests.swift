import BrowserCore
import BrowserTesting
import Testing
@testable import FeaturePrint

@MainActor
struct PrintFeatureTests {
    @Test func printsTheSelectedPageOnly() throws {
        let h = try TestHarness(features: [PrintFeature.self], manifestDirectory: #filePath)
        #expect(!h.context.commands.canRun("print.page", in: h.window))  // start page: nothing to print
        let tab = h.fakeTab(h.openTab("https://news.example/story"))
        #expect(h.context.commands.canRun("print.page", in: h.window))
        try h.run("print.page")
        #expect(tab.printCount == 1)
    }
}
