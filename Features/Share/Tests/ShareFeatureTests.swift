import BrowserCore
import BrowserTesting
import Testing
@testable import FeatureShare

@MainActor
struct ShareFeatureTests {
    @Test func helloCommandIsHandled() async throws {
        let harness = try TestHarness(features: [ShareFeature.self], manifestDirectory: #filePath)
        #expect(harness.context.commands.canRun("share.hello"))
        try harness.run("share.hello")
        #expect(harness.notifications.last == "Hello from Share")
    }
}
