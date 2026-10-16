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
            guard let w = inv.window, let tab = self.context.runtime.selectedTab(in: w) else { return }
            // Leave the tab (its content floats away) and pop it out.
            let previous = w.mru.first { $0 != tab.id && self.context.tabs.tab($0) != nil }
            self.context.runtime.select(previous, in: w)
            self.popOut(tab, from: w)
        }
        context.commands.handle("pip.close", isEnabled: { [weak self] _ in self?.session != nil }) { [weak self] _ in
            self?.close(expand: false)
        }
        let runtime = context.runtime
        context.ui.contribute("site-controls.rows", id: "pip.site-row", order: 10) { window in
            PopOutRow(window: window, runtime: runtime)
        }
    }

    // MARK: Triggers

    func shouldPopOut(_ tab: BrowserTab) -> Bool {
        guard let live = tab.live, context.settings.bool("pip.autoPopOut") else { return false }
        if let site = SiteSettingsStore.site(for: live.url), context.siteSettings.bool(Self.siteKey, for: site) == false { return false }
        let inCall = live.isCapturingCamera || live.isCapturingMicrophone
        if inCall { return context.settings.bool("pip.calls") }
        return live.isPlayingVideo
    }

    func tabSelected(_ e: TabSelected) {
        if let s = session, e.tabID == s.tabID {
            close(expand: false, reselecting: true)
            return
        }
        guard let previousID = e.previousTabID, previousID != e.tabID, session?.tabID != previousID,
              let previous = context.tabs.tab(previousID), shouldPopOut(previous),
              let window = context.runtime.window(e.windowID) else { return }
        popOut(previous, from: window)
    }

    // MARK: Session

    func popOut(_ tab: BrowserTab, from window: BrowserWindowState) {
        if session != nil { close(expand: false) }
        guard let engineTab = tab.engineTab, let floating = context.engine as? EngineFloating,
              let content = floating.detachForFloating(engineTab) else { return }
        let isCall = tab.live?.isCapturingCamera == true || tab.live?.isCapturingMicrophone == true
        let startFrame = context.shell?.nsWindow(for: window).map { w in w.convertToScreen(w.contentLayoutRect) }
        session = PiPSession(feature: self, tabID: tab.id, engineTab: engineTab, content: content, isCall: isCall,
                             windowID: window.id, startFrame: startFrame,
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
        } else if reselecting, let w = context.windows.first(where: { $0.selectedTabID == s.tabID }) {
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
    let panel: PiPPanel
    let model: PiPControlsModel
    private weak var feature: PictureInPictureFeature?

    init(feature: PictureInPictureFeature, tabID: NodeID, engineTab: EngineTab, content: FloatingContent, isCall: Bool,
         windowID: UUID, startFrame: CGRect?, width: CGFloat) {
        self.feature = feature
        self.tabID = tabID
        self.engineTab = engineTab
        self.windowID = windowID
        self.isCall = isCall
        model = PiPControlsModel(isCall: isCall)
        let size = CGSize(width: width, height: (width * 9 / 16).rounded())
        panel = PiPPanel(content: content, size: size, model: model)
        model.perform = { [weak self] action in self?.perform(action) }
        if isCall {
            panel.present(from: startFrame)
        } else {
            // The flight starts once the page shows only the video, in its shape: re-aimed midway, it stuttered. A page
            // slow to answer doesn't hold it up.
            var presented = false
            let present = { [weak panel] in
                guard !presented else { return }
                presented = true
                panel?.present(from: startFrame)
            }
            engineTab.evaluateJavaScript(PiPScripts.enter) { [weak self] result in
                if case .success(let value) = result, let dims = value as? [Double], dims.count == 2, dims[1] > 0 {
                    self?.panel.setAspect(CGFloat(dims[0] / dims[1]))
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

enum PiPScripts {
    /// Video-only presentation: the largest playing video fills the page; everything else hides.
    static let enter = """
    (() => {
      const vids = [...document.querySelectorAll('video')].filter(v => v.readyState > 0);
      const v = vids.filter(v => !v.paused).sort((a, b) => b.videoWidth * b.videoHeight - a.videoWidth * a.videoHeight)[0] || vids[0];
      if (!v) return null;
      window.__pipVideo = v;
      if (!document.getElementById('__pip_style')) {
        const s = document.createElement('style'); s.id = '__pip_style';
        s.textContent = `html.__pip, html.__pip body { overflow: hidden !important; background: #000 !important; }
          html.__pip body * { visibility: hidden !important; }
          html.__pip video.__pip_target { visibility: visible !important; position: fixed !important; inset: 0 !important;
            width: 100vw !important; height: 100vh !important; max-width: none !important; max-height: none !important;
            z-index: 2147483647 !important; object-fit: contain !important; background: #000 !important; transform: none !important; }`;
        document.documentElement.appendChild(s);
      }
      v.classList.add('__pip_target');
      if (v.controls) { v.dataset.pipControls = '1'; v.controls = false; }  // our own controls take over
      document.documentElement.classList.add('__pip');
      return [v.videoWidth, v.videoHeight];
    })()
    """
    static let exit = """
    (() => { document.documentElement.classList.remove('__pip');
      document.querySelectorAll('.__pip_target').forEach(v => {
        v.classList.remove('__pip_target');
        if (v.dataset.pipControls) { v.controls = true; delete v.dataset.pipControls; }
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
