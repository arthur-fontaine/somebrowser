import AppKit
import Foundation

/// Safari's agents sync only when Safari asks, so what's written here waits for Safari (README, "This browser on the
/// iPhone"). When something waits and Safari isn't running, Safari is launched hidden (not activated, no window
/// shown): its launch syncs Tab Groups, history and bookmarks. It's quit again once nothing waits, unless the user
/// brought it forward meanwhile. At most one launch per `minimumInterval` (setting `safari.background-sync`).
@MainActor
final class SafariBackgroundSync {
    /// Something written here hasn't reached iCloud yet.
    var isPending: () -> Bool = { false }
    /// Runs once Safari is up (favorites need Safari to be asked).
    var whenLaunched: () -> Void = {}
    var minimumInterval: Duration = .seconds(15 * 60)
    var settleDelay: Duration = .seconds(30)
    var timeout: Duration = .seconds(120)
    var pollInterval: Duration = .seconds(2)
    var app: SafariApp = SystemSafari()

    private var task: Task<Void, Never>?
    private var lastLaunch: ContinuousClock.Instant?

    /// Asks for a sync soon; changes come in bursts.
    func request() {
        guard task == nil else { return }
        task = Task { [weak self] in
            await self?.run()
            self?.task = nil
        }
    }

    private func run() async {
        try? await Task.sleep(for: settleDelay)
        if let lastLaunch {
            let wait = minimumInterval - (ContinuousClock.now - lastLaunch)
            if wait > .zero { try? await Task.sleep(for: wait) }
        }
        guard isPending(), !app.isRunning else { return }
        lastLaunch = .now
        guard let launched = await app.launchHidden() else { return }
        whenLaunched()
        let start = ContinuousClock.now
        while isPending(), ContinuousClock.now - start < timeout {
            try? await Task.sleep(for: pollInterval)
        }
        if app.isUntouched(launched) { app.quit(launched) }
    }
}

/// Safari as an app, swapped in tests.
@MainActor
protocol SafariApp {
    var isRunning: Bool { get }
    /// The launched app, opaque.
    func launchHidden() async -> AnyObject?
    /// Still hidden and in the background: the user didn't bring it forward.
    func isUntouched(_ app: AnyObject) -> Bool
    func quit(_ app: AnyObject)
}

@MainActor
struct SystemSafari: SafariApp {
    static let bundleID = "com.apple.Safari"

    var isRunning: Bool { !NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID).isEmpty }

    func launchHidden() async -> AnyObject? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.bundleID) else { return nil }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.hides = true
        configuration.addsToRecentItems = false
        return try? await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
    }

    func isUntouched(_ app: AnyObject) -> Bool {
        guard let app = app as? NSRunningApplication else { return false }
        return !app.isTerminated && app.isHidden && !app.isActive
    }

    func quit(_ app: AnyObject) { (app as? NSRunningApplication)?.terminate() }
}
