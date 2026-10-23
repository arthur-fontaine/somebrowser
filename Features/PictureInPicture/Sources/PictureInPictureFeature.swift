import AppKit
import BrowserCore
import SwiftUI

public final class PictureInPictureFeature: BrowserFeature {
    let context: FeatureContext
    private(set) var session: PiPSession?
    static let siteKey = "pip.auto"

    public init(context: FeatureContext) { self.context = context }

    public func activate() {
        context.events.subscribe(TabSelected.self) { [weak self] e in self?.tabSelected(e) }
        NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: nil, queue: .main) { [weak self] note in
            let window = note.object as? NSWindow
            MainActor.assumeIsolated { if let window { self?.occlusionChanged(window) } }
        }
        context.events.subscribe(TabsClosed.self) { [weak self] e in
            guard let self, let s = self.session, e.tabIDs.contains(s.tabID) else { return }
            self.close(expand: false)
        }
        context.commands.handle("pip.toggle", isEnabled: { [weak self] inv in
            guard let self else { return false }
            return self.session != nil || inv.window.flatMap { self.context.runtime.selectedTab(in: $0)?.engineTab } != nil
        }) { [weak self] inv in
            guard let self else { return }
            if self.session != nil { self.close(expand: true); return }
            if let w = inv.window { self.popOutSelected(in: w) }
        }
        // Chromium's "Picture in Picture" on a video: this panel rather than Chrome's window.
        context.hooks.pictureInPicture = { [weak self] page, source in
            guard let self, let w = self.context.windows.first(where: { self.context.runtime.selectedTab(in: $0)?.engineTab === page })
            else { return false }
            self.popOutSelected(in: w, video: source)
            return true
        }
        context.commands.handle("pip.close", isEnabled: { [weak self] _ in self?.session != nil }) { [weak self] _ in
            self?.close(expand: false)
        }
        let runtime = context.runtime
        context.ui.contribute("site-controls.rows", id: "pip.site-row", order: 10) { window in
            PopOutRow(window: window, runtime: runtime)
        }
        // Before share (250), so it comes and goes without moving the others.
        context.ui.contribute("address-bar.trailing", id: "pip.button", order: 240) { [weak self] window in
            if let self { PiPButton(window: window, runtime: runtime) { self.popOutSelected(in: window) } }
        }
    }

    // MARK: Triggers

    /// As Chrome's automatic PiP: a video playing with sound (a muted one, a landing page's backdrop, stays), or a call.
    func shouldPopOut(_ tab: BrowserTab) -> Bool {
        guard let live = tab.live, context.settings.bool("pip.autoPopOut") else { return false }
        if let site = SiteSettingsStore.site(for: live.url), context.siteSettings.bool(Self.siteKey, for: site) == false { return false }
        let inCall = live.isCapturingCamera || live.isCapturingMicrophone
        if inCall { return context.settings.bool("pip.calls") }
        return live.isPlayingVideo && live.isPlayingAudio && !live.isMuted
    }

    func tabSelected(_ e: TabSelected) {
        if let s = session, e.tabID == s.tabID {
            close(expand: false, reselecting: true)
            return
        }
        // A floating video stays: only the user replaces it (`pip.toggle`).
        guard session == nil, let previousID = e.previousTabID, previousID != e.tabID,
              let previous = context.tabs.tab(previousID), shouldPopOut(previous),
              let window = context.runtime.window(e.windowID) else { return }
        popOut(previous, from: window)
    }

    // MARK: Window visibility

    /// Whether macOS shows any of the window: fully covered, minimized, hidden with the app or on another Space, it
    /// doesn't. A window still showing anywhere (another display, beside another app's) keeps its video, even when
    /// another app is in front.
    private func isShowing(_ w: BrowserWindowState) -> Bool {
        context.shell?.nsWindow(for: w)?.occlusionState.contains(.visible) ?? true
    }

    private func occlusionChanged(_ ns: NSWindow) {
        guard let w = context.windows.first(where: { context.shell?.nsWindow(for: $0) === ns }) else { return }
        // Switching windows or Spaces (Mission Control too) hides or shows a window for an instant: only what still
        // holds a moment later counts.
        let showing = isShowing(w)
        DispatchQueue.main.asyncAfter(deadline: .now() + (showing ? 0.15 : 0.3)) { [weak self, weak w] in
            guard let self, let w, self.isShowing(w) == showing else { return }
            if showing { self.windowShown(w) } else { self.windowHidden(w) }
        }
    }

    /// The window stopped showing: its playing video floats, the tab staying selected in it.
    func windowHidden(_ w: BrowserWindowState) {
        guard session == nil, let tab = context.runtime.selectedTab(in: w), shouldPopOut(tab) else { return }
        popOut(tab, from: w, fromPage: false)  // the window isn't on screen: it rises in its corner
        session?.returnsWithWindow = true
    }

    /// Showing again, the window takes back the video that left with it, playing on.
    func windowShown(_ w: BrowserWindowState) {
        guard let s = session, s.returnsWithWindow, s.windowID == w.id, w.selectedTabID == s.tabID else { return }
        close(expand: false, reselecting: true)
    }

    // MARK: Session

    /// The user's own pop-out: the window leaves the tab (its content floats away), whatever plays in it. `video` picks
    /// the page's video (its address), else the one playing.
    func popOutSelected(in w: BrowserWindowState, video: URL? = nil) {
        guard let tab = context.runtime.selectedTab(in: w) else { return }
        let previous = w.mru.first { $0 != tab.id && context.tabs.tab($0) != nil }
        context.runtime.select(previous, in: w)
        popOut(tab, from: w, video: video)
    }

    func popOut(_ tab: BrowserTab, from window: BrowserWindowState, video: URL? = nil, fromPage: Bool = true) {
        if session != nil { close(expand: false) }
        guard let engineTab = tab.engineTab, let floating = context.engine as? EngineFloating,
              let content = floating.detachForFloating(engineTab) else { return }
        let isCall = tab.live?.isCapturingCamera == true || tab.live?.isCapturingMicrophone == true
        // The page's area on screen (the video's place in it comes from the page).
        let nsWindow = context.shell?.nsWindow(for: window)
        let startFrame = !fromPage ? nil : nsWindow.map { w in
            w.convertToScreen(window.contentFrame.isEmpty ? w.contentLayoutRect : window.contentFrame)
        }
        // On the window's display; once the window stopped showing, where the user went: the window now in front.
        let screen = fromPage ? nsWindow?.screen?.visibleFrame : PiPGeometry.frontWindowScreen() ?? PiPGeometry.pointerScreen()
        session = PiPSession(feature: self, tabID: tab.id, engineTab: engineTab, content: content, isCall: isCall,
                             windowID: window.id, startFrame: startFrame, screen: screen, video: video,
                             width: CGFloat(max(240, context.settings.int("pip.width"))))
        context.runtime.holdAwake(tab.id, reason: "pip")
    }

    /// `expand` brings the user back to the tab; otherwise the video pauses and the tab stays where it was.
    func close(expand: Bool, reselecting: Bool = false) {
        guard let s = session else { return }
        session = nil
        context.runtime.releaseAwake(s.tabID, reason: "pip")
        s.tearDown(pause: !expand && !reselecting)
        (context.engine as? EngineFloating)?.reattachAfterFloating(s.engineTab)
        if expand {
            let window = context.runtime.window(s.windowID) ?? context.keyWindow
            if let window {
                context.runtime.select(s.tabID, in: window)
                context.shell?.nsWindow(for: window)?.makeKeyAndOrderFront(nil)
                NSApp.activate()
            }
        } else if let w = context.windows.first(where: { $0.selectedTabID == s.tabID }) {  // reselected, or never left
            w.viewport?.present(s.engineTab)
        }
    }
}

/// One floating video: the panel, its controls and the page script.
final class PiPSession {
    let tabID: NodeID
    let engineTab: EngineTab
    let windowID: UUID
    let isCall: Bool
    /// Floated because its window stopped showing: back in it when the window shows again.
    var returnsWithWindow = false
    let panel: PiPPanel
    let model: PiPControlsModel
    private weak var feature: PictureInPictureFeature?

    init(feature: PictureInPictureFeature, tabID: NodeID, engineTab: EngineTab, content: FloatingContent, isCall: Bool,
         windowID: UUID, startFrame: CGRect?, screen: CGRect?, video: URL?, width: CGFloat) {
        self.feature = feature
        self.tabID = tabID
        self.engineTab = engineTab
        self.windowID = windowID
        self.isCall = isCall
        model = PiPControlsModel(isCall: isCall)
        let size = CGSize(width: width, height: (width * 9 / 16).rounded())
        panel = PiPPanel(content: content, size: size, model: model, flies: startFrame != nil)
        model.perform = { [weak self] action in self?.perform(action) }
        panel.takeStill = { [weak engineTab] done in
            guard let engineTab else { return done(nil) }
            engineTab.snapshot(maxWidth: 1920, completion: done)
        }
        if isCall {
            panel.present(from: startFrame, on: screen)
        } else {
            // The flight starts once the page shows only the video, in its shape: re-aimed midway, it stuttered. A page
            // slow to answer doesn't hold it up.
            var presented = false
            var startFrame = startFrame
            let present = { [weak panel] in
                guard !presented else { return }
                presented = true
                panel?.present(from: startFrame, on: screen)
            }
            engineTab.evaluateJavaScript(PiPScripts.enter(video: video)) { [weak self] result in
                guard case .success(let value) = result, let d = value as? [Double], d.count == 8, d[1] > 0 else { return present() }
                self?.panel.setAspect(CGFloat(d[0] / d[1]))
                // It flies from where the video was on the page.
                if let page = startFrame, let rect = PiPGeometry.screenRect(ofPageRect: CGRect(x: d[2], y: d[3], width: d[4], height: d[5]),
                                                                          viewport: CGSize(width: d[6], height: d[7]), shownIn: page) {
                    startFrame = rect
                }
                present()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: present)
        }
        model.onHoverChanged = { [weak self] hovering in if hovering { self?.refreshState() } }
    }

    func perform(_ action: PiPControlsModel.Action) {
        switch action {
        case .close: feature?.close(expand: false)
        case .expand: feature?.close(expand: true)
        case .togglePlay: engineTab.evaluateJavaScript(PiPScripts.togglePlay) { [weak self] _ in self?.refreshState() }
        case .seek(let delta): engineTab.evaluateJavaScript(PiPScripts.seek(delta)) { [weak self] _ in self?.refreshState() }
        case .seekTo(let fraction): engineTab.evaluateJavaScript(PiPScripts.seekTo(fraction)) { [weak self] _ in self?.refreshState() }
        case .toggleMute:
            engineTab.isMuted.toggle()
            model.muted = engineTab.isMuted
        }
    }

    func refreshState() {
        guard !isCall else { model.muted = engineTab.isMuted; return }
        engineTab.evaluateJavaScript(PiPScripts.state) { [weak self] result in
            guard let self, case .success(let value) = result, let v = value as? [Double], v.count == 3 else { return }
            self.model.paused = v[0] != 0
            self.model.time = v[1]
            self.model.duration = v[2]
            self.model.muted = self.engineTab.isMuted
            if self.model.hovering {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.refreshState() }
            }
        }
    }

    func tearDown(pause: Bool) {
        if !isCall {
            engineTab.evaluateJavaScript((pause ? PiPScripts.pause : "") + PiPScripts.exit)
        }
        panel.dismiss()
    }
}

enum PiPGeometry {
    /// The display (visible frame) of the frontmost app's front window: where the user went. Window bounds and owners
    /// are readable without the screen-recording permission (titles aren't, and aren't needed).
    static func frontWindowScreen() -> CGRect? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return nil }
        // Front to back; layer 0: regular windows (not menus, panels, ours floating). Invisible ones skipped: a full-screen
        // app's title bar waits above its display, clear.
        for info in list where (info[kCGWindowOwnerPID as String] as? pid_t) == app.processIdentifier
            && (info[kCGWindowLayer as String] as? Int) == 0 && (info[kCGWindowAlpha as String] as? Double ?? 1) > 0 {
            guard let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary),
                  let screen = screen(containing: CGPoint(x: rect.midX, y: rect.midY), quartzTopLeft: true) else { continue }
            return screen
        }
        return nil
    }

    static func pointerScreen() -> CGRect? { screen(containing: NSEvent.mouseLocation, quartzTopLeft: false) }

    /// Quartz measures from the main display's top-left, y down; AppKit from its bottom-left, y up.
    static func screen(containing p: CGPoint, quartzTopLeft: Bool) -> CGRect? {
        let point = quartzTopLeft ? CGPoint(x: p.x, y: (NSScreen.screens.first?.frame.height ?? 0) - p.y) : p
        return NSScreen.screens.first { $0.frame.contains(point) }?.visibleFrame
    }

    /// A rect of the page (CSS pixels from the viewport's top-left) on screen, the viewport shown in `page` (screen
    /// points, y up): what of it is visible, nil if nothing is.
    static func screenRect(ofPageRect r: CGRect, viewport: CGSize, shownIn page: CGRect) -> CGRect? {
        guard viewport.width > 0, viewport.height > 0 else { return nil }
        let sx = page.width / viewport.width, sy = page.height / viewport.height
        let rect = CGRect(x: page.minX + r.minX * sx, y: page.maxY - r.maxY * sy, width: r.width * sx, height: r.height * sy)
        let visible = rect.intersection(page)
        return visible.isNull || visible.width < 1 || visible.height < 1 ? nil : visible
    }
}

enum PiPScripts {
    /// Video-only presentation: `video` (its address), else the playing video (the one with sound, else the largest),
    /// fills the page; everything else hides.
    static func enter(video: URL?) -> String {
        let wanted = video.flatMap { try? String(data: JSONEncoder().encode($0.absoluteString), encoding: .utf8) } ?? "null"
        return """
    (() => {
      const vids = [...document.querySelectorAll('video')].filter(v => v.readyState > 0);
      // The one playing with sound first, then any playing; the largest on the page among them.
      const rank = v => (v.paused ? 0 : 2) + (!v.paused && !v.muted && v.volume > 0 ? 1 : 0);
      const area = v => { const r = v.getBoundingClientRect(); return r.width * r.height; };
      const wanted = \(wanted);
      const v = vids.find(v => wanted && (v.currentSrc === wanted || v.src === wanted))
        || vids.sort((a, b) => rank(b) - rank(a) || area(b) - area(a))[0];
      if (!v) return null;
      window.__pipVideo = v;
      const r = v.getBoundingClientRect();  // where it shows, before the page shows only it
      if (!document.getElementById('__pip_style')) {
        const s = document.createElement('style'); s.id = '__pip_style';
        s.textContent = `html.__pip, html.__pip body { overflow: hidden !important; background: #000 !important; }
          html.__pip body * { visibility: hidden !important; }
          html.__pip video.__pip_target { visibility: visible !important; position: fixed !important; inset: 0 !important;
            width: 100vw !important; height: 100vh !important; max-width: none !important; max-height: none !important;
            margin: 0 !important; border: 0 !important; padding: 0 !important; display: block !important;
            z-index: 2147483647 !important; object-fit: contain !important; background: #000 !important; transform: none !important; }`;
        document.documentElement.appendChild(s);
      }
      v.classList.add('__pip_target');
      // In the top layer, the video is laid out against the window: an ancestor with a transform (Twitch's player) or
      // a filter would otherwise hold it in its own box, cropped.
      if (v.showPopover && !v.hasAttribute('popover')) {
        v.dataset.pipPopover = '1'; v.popover = 'manual';
        try { v.showPopover(); } catch (e) {}
      }
      if (v.controls) { v.dataset.pipControls = '1'; v.controls = false; }  // our own controls take over
      document.documentElement.classList.add('__pip');
      return [v.videoWidth, v.videoHeight, r.left, r.top, r.width, r.height, innerWidth, innerHeight];
    })()
    """
    }
    static let exit = """
    (() => { document.documentElement.classList.remove('__pip');
      document.querySelectorAll('.__pip_target').forEach(v => {
        v.classList.remove('__pip_target');
        if (v.dataset.pipControls) { v.controls = true; delete v.dataset.pipControls; }
        if (v.dataset.pipPopover) { try { v.hidePopover(); } catch (e) {} v.removeAttribute('popover'); delete v.dataset.pipPopover; }
      });
      const s = document.getElementById('__pip_style'); if (s) s.remove(); })();
    """
    static let pause = "(() => { const v = window.__pipVideo; if (v) v.pause(); })();"
    static let togglePlay = "(() => { const v = window.__pipVideo; if (v) { v.paused ? v.play() : v.pause(); } })();"
    static let state = "(() => { const v = window.__pipVideo; return v ? [v.paused ? 1 : 0, v.currentTime || 0, isFinite(v.duration) ? v.duration : 0] : null; })()"
    static func seek(_ delta: Double) -> String { "(() => { const v = window.__pipVideo; if (v) v.currentTime = Math.max(0, v.currentTime + (\(delta))); })();" }
    static func seekTo(_ f: Double) -> String { "(() => { const v = window.__pipVideo; if (v && isFinite(v.duration)) v.currentTime = v.duration * \(f); })();" }
}

/// "Pop-out View" toggle in the site controls popover.
struct PopOutRow: View {
    let window: BrowserWindowState
    let runtime: BrowserRuntime

    var body: some View {
        if let site = SiteSettingsStore.site(for: runtime.selectedTab(in: window)?.live?.url) {
            let on = runtime.siteSettings.bool(PictureInPictureFeature.siteKey, for: site) ?? true
            HStack {
                Image(systemName: on ? "pip.enter" : "rectangle").contentTransition(.symbolEffect(.replace)).frame(width: 20)
                Text("Pop-out View")
                Spacer()
                Toggle("", isOn: Binding(get: { on }, set: { runtime.siteSettings.set(PictureInPictureFeature.siteKey, $0 ? nil : .bool(false), for: site) })
                    .animation(.spring(duration: 0.3, bounce: 0.3)))
                    .toggleStyle(.switch).labelsHidden().controlSize(.small)
            }
            .padding(.horizontal, 8)
            .frame(height: 32)
        }
    }
}

/// Picture in Picture in the address field, while the page plays a video.
struct PiPButton: View {
    let window: BrowserWindowState
    let runtime: BrowserRuntime
    let action: () -> Void

    var body: some View {
        if runtime.selectedTab(in: window)?.live?.isPlayingVideo == true {
            FieldButton(help: "Picture in Picture", action: action) {
                Image(systemName: "pip.enter").font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
            }
        }
    }
}
