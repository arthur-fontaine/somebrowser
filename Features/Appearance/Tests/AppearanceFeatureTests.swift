import BrowserCore
import BrowserTesting
import Testing
@testable import FeatureAppearance

@MainActor
struct AppearanceFeatureTests {
    /// The window's surface comes from this feature; glass unless the user picks solid.
    @Test func drawsTheWindowSurface() throws {
        let h = try TestHarness(features: [AppearanceFeature.self], manifestDirectory: #filePath)
        #expect(h.runtime.ui.views(for: "background").count == 1)
        #expect(h.runtime.settings.string(SurfaceStyle.settingKey) == SurfaceStyle.glass.rawValue)
    }
}
