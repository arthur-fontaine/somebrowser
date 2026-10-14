import AppKit
import BrowserCore
import SwiftUI

public final class FindFeature: BrowserFeature {
    let context: FeatureContext
    let model: FindModel

    public init(context: FeatureContext) {
        self.context = context
        model = FindModel(runtime: context.runtime)
    }

    public func activate() {
        let model = self.model
        let hasPage: (CommandInvocation) -> Bool = { inv in
            inv.window.flatMap { model.runtime.selectedTab(in: $0)?.engineTab } != nil
        }
        context.commands.handle("find.show", isEnabled: hasPage) { inv in if let w = inv.window { model.show(in: w) } }
        context.commands.handle("find.next", isEnabled: hasPage) { inv in if let w = inv.window { model.find(forward: true, in: w) } }
        context.commands.handle("find.previous", isEnabled: hasPage) { inv in if let w = inv.window { model.find(forward: false, in: w) } }
        context.commands.handle("find.hide") { inv in if let w = inv.window { model.hide(in: w) } }
        context.ui.contribute(.contentOverlay, id: "find.bar", order: 50) { window in FindBar(window: window, model: model) }
        // A new page invalidates matches.
        context.events.subscribe(TabSelected.self) { e in
            if let w = model.runtime.window(e.windowID) { model.hide(in: w) }
        }
    }
}

@Observable
final class FindModel {
    @ObservationIgnored let runtime: BrowserRuntime
    var queries: [UUID: String] = [:]
    static let flag = "find"

    init(runtime: BrowserRuntime) { self.runtime = runtime }

    func show(in window: BrowserWindowState) {
        window.flags.insert(Self.flag)
        if let q = queries[window.id], !q.isEmpty { find(forward: true, in: window) }
    }

    func hide(in window: BrowserWindowState) {
        guard window.flags.contains(Self.flag) else { return }
        window.flags.remove(Self.flag)
        runtime.selectedTab(in: window)?.engineTab?.stopFinding()
    }

    func setQuery(_ q: String, in window: BrowserWindowState) {
        queries[window.id] = q
        find(forward: true, in: window)
    }

    func find(forward: Bool, in window: BrowserWindowState) {
        guard let tab = runtime.selectedTab(in: window)?.engineTab else { return }
        let q = queries[window.id] ?? ""
        if !window.flags.contains(Self.flag) { window.flags.insert(Self.flag) }
        tab.find(q, forward: forward, caseSensitive: runtime.settings.bool("find.caseSensitive"))
    }

    func result(in window: BrowserWindowState) -> FindResult? { runtime.selectedTab(in: window)?.live?.findResult }
}

struct FindBar: View {
    let window: BrowserWindowState
    let model: FindModel
    @FocusState private var focused: Bool

    var body: some View {
        if window.flags.contains(FindModel.flag) {
            VStack {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Find in page", text: Binding(get: { model.queries[window.id] ?? "" }, set: { model.setQuery($0, in: window) }))
                        .textFieldStyle(.plain)
                        .frame(width: 180)
                        .focused($focused)
                        .onSubmit { model.find(forward: !NSEvent.modifierFlags.contains(.shift), in: window) }
                        .onKeyPress(.escape) { model.hide(in: window); return .handled }
                    if let r = model.result(in: window), !(model.queries[window.id] ?? "").isEmpty {
                        Text(r.matches == 0 ? "No matches" : "\(r.activeIndex) of \(r.matches)")
                            .font(.system(size: 11, design: .rounded)).foregroundStyle(.secondary).monospacedDigit()
                    }
                    Button { model.find(forward: false, in: window) } label: { Image(systemName: "chevron.up") }.buttonStyle(.borderless)
                    Button { model.find(forward: true, in: window) } label: { Image(systemName: "chevron.down") }.buttonStyle(.borderless)
                    Button("Done") { model.hide(in: window) }.buttonStyle(.borderless)
                }
                .padding(.horizontal, 12)
                .frame(height: 36)
                .background(.regularMaterial, in: Capsule())
                .shadow(color: .black.opacity(0.18), radius: 10, y: 3)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .trailing)
                Spacer()
            }
            .transition(.move(edge: .top).combined(with: .opacity))
            .overlayKeyboardFocus("find", in: window)
            .onAppear { focused = true }
        }
    }
}
