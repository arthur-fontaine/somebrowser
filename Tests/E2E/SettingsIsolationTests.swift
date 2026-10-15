import BrowserTesting
import Foundation
import Testing

/// A data directory given with BROWSER_DATA_DIR keeps its settings to itself: tests and automation never change the
/// real profile's.
@Suite(.serialized, .enabled(if: AppDriver.executableFromEnvironment != nil, "set BROWSER_E2E_APP (./forkctl test --e2e)"))
struct SettingsIsolationTests {
    @Test func settingsStayInTheDataDirectory() throws {
        let executable = URL(fileURLWithPath: AppDriver.executableFromEnvironment!)
        let bundle = try #require(Bundle(url: executable.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()))
        let real = try #require(UserDefaults(suiteName: bundle.bundleIdentifier))
        let key = "setting.adblock.cosmetic"
        let before = real.data(forKey: key)
        let app = try AppDriver(executable: executable.path)
        _ = try app.call(["op": "setting", "key": "adblock.cosmetic", "value": before == nil ? false : true])
        try app.quit()
        real.synchronize()
        #expect(real.data(forKey: key) == before)
        let own = NSDictionary(contentsOf: app.directory.appendingPathComponent("data/settings.plist"))
        #expect(own?[key] != nil)
    }
}
