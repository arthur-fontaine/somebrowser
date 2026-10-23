import AppKit
import BrowserCore
import LocalAuthentication
import SwiftUI

/// Your tabs, the private space and the Claude space (`SpaceKind`). The private space locks whenever a window leaves
/// it; coming back asks for Touch ID (or the Mac's password) before its tabs and pages show.
public final class SpacesFeature: BrowserFeature {
    let context: FeatureContext
    var runtime: BrowserRuntime { context.runtime }

    /// Asks the user to prove it's them; replaced in tests. End-to-end tests answer with `BROWSER_TEST_TOUCH_ID`
    /// (`allow` or `deny`): it only reaches a process launched with it, whose private space starts empty.
    nonisolated(unsafe) static var authenticate: (_ reason: String, _ done: @escaping @MainActor (Bool) -> Void) -> Void = { reason, done in
        if let answer = ProcessInfo.processInfo.environment["BROWSER_TEST_TOUCH_ID"] {
            DispatchQueue.main.async { done(answer == "allow") }
            return
        }
        let context = LAContext()
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: nil) else { DispatchQueue.main.async { done(true) }; return }
        context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { ok, _ in
            DispatchQueue.main.async { done(ok) }
        }
    }

    public init(context: FeatureContext) { self.context = context }

    public func activate() {
        let c = context.commands
        c.handle("spaces.next") { [weak self] inv in self?.step(1, inv.window) }
        c.handle("spaces.previous") { [weak self] inv in self?.step(-1, inv.window) }
        c.handle("spaces.unlock", isEnabled: { $0.window?.isLocked == true }) { [weak self] inv in
            if let w = inv.window { self?.unlock(w) }
        }
        c.handle("spaces.lock", isEnabled: { $0.window?.isPrivate == true && $0.window?.isLocked == false }) { [weak self] inv in
            guard let self, let w = inv.window else { return }
            self.runtime.switchSpace(self.context.tabs.normalSpace.id, in: w)
        }
        // Entering a locked private space asks at once.
        context.events.subscribe(SpaceSwitched.self) { [weak self] e in
            guard let self, let w = self.context.windows.first(where: { $0.id == e.windowID }), w.isLocked else { return }
            self.unlock(w)
        }

        let runtime = self.runtime
        context.ui.contribute("sidebar.footer.center", id: "spaces.switcher", order: 50) { window in SpaceSwitcher(window: window, runtime: runtime) }
        context.ui.contribute(.contentOverlay, id: "spaces.locked", order: 5) { window in LockedContent(window: window, runtime: runtime) }
    }

    func step(_ delta: Int, _ window: BrowserWindowState?) {
        guard let w = window else { return }
        let spaces = context.tabs.spaces
        guard let i = spaces.firstIndex(where: { $0.id == w.spaceID }) else { return }
        let j = i + delta
        guard spaces.indices.contains(j) else { NSSound.beep(); return }
        runtime.switchSpace(spaces[j].id, in: w)
    }

    private var unlocking: Set<UUID> = []

    func unlock(_ window: BrowserWindowState) {
        guard window.isLocked, unlocking.insert(window.id).inserted else { return }
        Self.authenticate("unlock your private tabs") { [weak self, weak window] ok in
            guard let self, let window else { return }
            self.unlocking.remove(window.id)
            if ok { self.runtime.unlockPrivateSpace(in: window) }
        }
    }
}

// MARK: Switcher

/// One symbol per space, shown only once there are two (most of the time there is only yours): a glass segmented
/// control, its selection sliding between spaces.
struct SpaceSwitcher: View {
    let window: BrowserWindowState
    let runtime: BrowserRuntime
    @Namespace private var selection

    var body: some View {
        let spaces = runtime.tabs.spaces
        if spaces.count > 1 {
            // Segments concentric inside the capsule: 36 tall, 4 in, so each is a 28 pt capsule.
            HStack(spacing: 0) {
                ForEach(spaces) { space in
                    let selected = space.id == window.spaceID
                    Button { runtime.switchSpace(space.id, in: window) } label: {
                        SpaceSymbol(space.kind, activeUntil: space.agentActedAt?.addingTimeInterval(BrowserTab.agentActivityWindow))
                            .foregroundStyle(selected ? .primary : .secondary)
                            .frame(width: 15, height: 15)
                            .frame(width: 36, height: Design.Size.control - 8)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .background {
                        if selected { Capsule().fill(Design.Fill.selection).matchedGeometryEffect(id: "selection", in: selection) }
                    }
                    .help(space.kind.title)
                    .accessibilityLabel(space.kind.title)
                }
            }
            .padding(Design.Space.segment)
            .glassControl(in: Capsule(), hover: false)
            .animation(Design.Motion.selection, value: window.spaceID)
        }
    }
}

// MARK: Lock

/// Over the content of a locked private space: nothing of its pages, a way in.
struct LockedContent: View {
    let window: BrowserWindowState
    let runtime: BrowserRuntime

    var body: some View {
        if window.isLocked {
            VStack(spacing: 14) {
                SpaceSymbol(.private).frame(width: 44, height: 44).foregroundStyle(.secondary)
                Text("Private tabs are locked").font(.title3.weight(.semibold))
                Text("Use Touch ID or your password to see them.").foregroundStyle(.secondary)
                Button("Unlock") { try? runtime.commands.run("spaces.unlock", window: window) }
                    .buttonStyle(.glassProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.background)
        }
    }
}
