import Foundation
import Testing
@testable import BrowserCore

@MainActor
struct AgentSparkTests {
    /// The animation stops on the spark at full size (the logo), never midway, and within one loop.
    @Test func itRestsOnTheFullSpark() {
        for offset in stride(from: 0.0, to: 2, by: 0.013) {
            let stop = Date(timeIntervalSinceReferenceDate: 800_000_000 + offset)
            let rest = AgentSpark.rest(after: stop)
            #expect(rest >= stop && rest.timeIntervalSince(stop) < 9 * AgentSpark.frameDuration + 0.001)
            #expect(AgentSpark.index(at: rest.timeIntervalSinceReferenceDate + 0.001) == AgentSpark.fullFrame)
        }
    }
}
