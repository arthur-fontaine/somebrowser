import AppKit
import BrowserCore
import SwiftUI

public final class TabSwitcherFeature: BrowserFeature {
    let context: FeatureContext
    let model: SwitcherModel
    private var monitor: Any?

    public init(context: FeatureContext) {
        self.context = context
        model = SwitcherModel(runtime: context.runtime)
    }

    public func activate() {
        let model = self.model
        context.commands.handle("tab-switcher.next") { [weak self] inv in
            guard let w = inv.window else { return }
            model.advance(1, in: w)
            self?.watchControlKey(w)
        }
        context.commands.handle("tab-switcher.previous") { [weak self] inv in
            guard let w = inv.window else { return }
            model.advance(-1, in: w)
            self?.watchControlKey(w)
        }
        context.ui.contribute(.overlay, id: "tab-switcher", order: 150) { window in SwitcherOverlay(window: window, model: model) }
    }

    /// Commits when Control is released; ⌃W closes the highlighted tab, Esc cancels.
    private func watchControlKey(_ window: BrowserWindowState) {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { [weak self] event in
            guard let self else { return event }
            if event.type == .flagsChanged, !event.modifierFlags.contains(.control) {
                self.model.commit(in: window)
                self.stopWatching()
                return event
            }
            if event.type == .keyDown {
                if event.keyCode == 13 { self.model.closeHighlighted(in: window); return nil }  // W
                if event.keyCode == 53 { self.model.cancel(in: window); self.stopWatching(); return nil }  // Esc
            }
            return event
        }
    }

    private func stopWatching() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

@Observable
final class SwitcherModel {
    struct Cycle {
        var tabs: [NodeID]
        var index: Int
    }

    @ObservationIgnored let runtime: BrowserRuntime
    private(set) var cycles: [UUID: Cycle] = [:]

    init(runtime: BrowserRuntime) { self.runtime = runtime }

    func candidates(in window: BrowserWindowState) -> [NodeID] {
        let all = runtime.settings.bool("tab-switcher.allSpaces")
        var ids = window.mru.filter { id in
            runtime.tabs.tab(id) != nil && (all || runtime.tabs.spaceID(of: id) == window.spaceID || runtime.tabs.isFavorite(id))
        }
        if let s = window.selectedTabID, !ids.contains(s) { ids.insert(s, at: 0) }
        return ids
    }

    func advance(_ delta: Int, in window: BrowserWindowState) {
        if var c = cycles[window.id] {
            c.index = ((c.index + delta) % c.tabs.count + c.tabs.count) % c.tabs.count
            cycles[window.id] = c
        } else {
            let tabs = candidates(in: window)
            guard tabs.count > 1 else { return }
            cycles[window.id] = Cycle(tabs: tabs, index: delta > 0 ? 1 : tabs.count - 1)
        }
    }

    func commit(in window: BrowserWindowState) {
        guard let c = cycles.removeValue(forKey: window.id), c.tabs.indices.contains(c.index) else { return }
        runtime.select(c.tabs[c.index], in: window)
    }

    func cancel(in window: BrowserWindowState) { cycles[window.id] = nil }

    func closeHighlighted(in window: BrowserWindowState) {
        guard var c = cycles[window.id], c.tabs.indices.contains(c.index) else { return }
        let id = c.tabs.remove(at: c.index)
        runtime.close(id)
        if c.tabs.count < 2 { cycles[window.id] = nil; return }
        c.index = min(c.index, c.tabs.count - 1)
        cycles[window.id] = c
    }
}

struct SwitcherOverlay: View {
    let window: BrowserWindowState
    let model: SwitcherModel

    var body: some View {
        if let cycle = model.cycles[window.id] {
            HStack(spacing: 10) {
                ForEach(Array(cycle.tabs.prefix(9).enumerated()), id: \.element) { i, id in
                    if let tab = model.runtime.tabs.tab(id) {
                        VStack(spacing: 8) {
                            SwitcherFavicon(tab: tab).frame(width: 28, height: 28)
                            Text(tab.displayTitle).font(.system(size: 11, weight: .medium)).lineLimit(2)
                                .multilineTextAlignment(.center).frame(width: 104, height: 28)
                            if tab.live?.isCapturingCamera == true || tab.live?.isCapturingMicrophone == true {
                                Image(systemName: "video.fill").font(.system(size: 9)).foregroundStyle(.red)
                            }
                        }
                        .padding(10)
                        .frame(width: 124, height: 104)
                        .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(i == cycle.index ? Color.accentColor.opacity(0.25) : Color.primary.opacity(0.05)))
                        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(i == cycle.index ? Color.accentColor : .clear, lineWidth: 2))
                    }
                }
            }
            .padding(14)
            .glassSurface(in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .shadow(color: .black.opacity(0.3), radius: 30, y: 10)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .transition(.scale(scale: 0.96).combined(with: .opacity))
            .animation(.spring(duration: 0.18), value: cycle.index)
        }
    }
}

struct SwitcherFavicon: View {
    @Environment(BrowserEnvironment.self) private var env
    let tab: BrowserTab
    var body: some View {
        SiteIcon(tab.live?.favicon ?? env.runtime.favicons.image(for: tab.live?.url ?? tab.url))
    }
}
