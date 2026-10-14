import BrowserCore
import Foundation

/// Frees the pages of background tabs (renderer memory and CPU) once they've been idle for a while, and right away when
/// macOS reports memory pressure. A hibernated tab keeps its URL, title and history and wakes when selected.
public final class HibernationFeature: BrowserFeature {
    private let context: FeatureContext
    private var timer: Timer?
    private var pressure: DispatchSourceMemoryPressure?

    public init(context: FeatureContext) {
        self.context = context
    }

    public func activate() {
        context.commands.handle("hibernation.hibernate-background") { [weak self] inv in
            guard let self else { return }
            let n = self.hibernate(idleFor: 0)
            self.context.notify(n == 0 ? "No background tabs to hibernate" : "Hibernated \(n) background tab\(n == 1 ? "" : "s")",
                                systemImage: "moon.zzz", window: inv.window)
        }
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer?.tolerance = 20
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler { [weak self, weak source] in
            guard let event = source?.data else { return }
            MainActor.assumeIsolated { self?.memoryPressure(critical: event.contains(.critical)) }
        }
        source.resume()
        pressure = source
    }

    public func deactivate() {
        timer?.invalidate()
        pressure?.cancel()
    }

    var threshold: TimeInterval? {
        switch context.settings.string("hibernation.after") {
        case "5m": 5 * 60
        case "15m": 15 * 60
        case "30m": 30 * 60
        case "1h": 3600
        case "4h": 4 * 3600
        default: nil
        }
    }

    func tick(now: Date = Date()) {
        guard let threshold else { return }
        hibernate(idleFor: threshold, now: now)
    }

    /// A warning frees what has been idle a few minutes; critical frees every background tab.
    func memoryPressure(critical: Bool, now: Date = Date()) {
        guard context.settings.bool("hibernation.memoryPressure") else { return }
        hibernate(idleFor: critical ? 0 : 5 * 60, now: now)
    }

    /// Hibernates background tabs idle for at least `idleFor`, longest idle first. Kept awake: tabs shown in a window or
    /// held by a feature (picture in picture), and pages playing sound or video or using the camera or microphone.
    @discardableResult
    func hibernate(idleFor: TimeInterval, now: Date = Date()) -> Int {
        let visible = Set(context.windows.compactMap(\.selectedTabID))
        let candidates = context.tabs.allTabs.filter { tab in
            guard let page = tab.live, !visible.contains(tab.id), !context.runtime.isHeldAwake(tab.id) else { return false }
            return now.timeIntervalSince(tab.lastActiveAt) >= idleFor
                && !page.isPlayingAudio && !page.isPlayingVideo && !page.isCapturingCamera && !page.isCapturingMicrophone
        }
        var freed = 0
        for tab in candidates.sorted(by: { $0.lastActiveAt < $1.lastActiveAt }) {
            context.runtime.discard(tab)
            if !tab.isLoaded { freed += 1 }
        }
        return freed
    }
}
