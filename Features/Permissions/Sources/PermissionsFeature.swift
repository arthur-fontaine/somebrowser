import AppKit
import BrowserCore
import SwiftUI

public final class PermissionsFeature: BrowserFeature, PermissionsService {
    let context: FeatureContext
    let prompts = PromptQueue()
    private(set) public var log: [PermissionLogEntry] = []
    private var logURL: URL { context.dataDirectory.appendingPathComponent("permission-log.json") }

    public init(context: FeatureContext) {
        self.context = context
        if let data = try? Data(contentsOf: logURL), let entries = try? JSONDecoder().decode([PermissionLogEntry].self, from: data) {
            log = entries
        }
    }

    public func activate() {
        context.capabilities.provide(PermissionsService.self, self)
        context.hooks.addPermissionHandler { [weak self] request in self?.remembered(request) }
        context.hooks.permissionPrompt = { [weak self] request, reply in self?.prompt(request, reply: reply) }
        let prompts = self.prompts
        context.ui.contribute(.overlay, id: "permissions.prompt", order: 120) { window in
            PermissionPrompt(window: window, queue: prompts)
        }
    }

    static func key(_ kind: PermissionRequest.Kind) -> String { "permissions.\(kind.rawValue)" }

    public func decision(_ kind: PermissionRequest.Kind, for site: String) -> PermissionDecision? {
        switch context.siteSettings.value(Self.key(kind), for: site)?.stringValue {
        case "grant": .grant
        case "deny": .deny
        default: nil
        }
    }

    public func setDecision(_ decision: PermissionDecision?, _ kind: PermissionRequest.Kind, for site: String) {
        let value: SettingValue? = switch decision {
        case .grant: .string("grant")
        case .deny: .string("deny")
        default: nil
        }
        context.siteSettings.set(Self.key(kind), value, for: site)
    }

    /// Any remembered denial wins; all remembered grants → grant; otherwise ask.
    func remembered(_ request: PermissionRequest) -> PermissionDecision? {
        guard let site = SiteSettingsStore.site(for: request.origin) else { return nil }
        let decisions = request.kinds.map { decision($0, for: site) }
        let result: PermissionDecision?
        if decisions.contains(where: { $0 == .deny }) { result = .deny }
        else if decisions.allSatisfy({ $0 == .grant }) { result = .grant }
        else { result = nil }
        if let result { record(site, request.kinds, granted: result == .grant, source: "remembered") }
        return result
    }

    func prompt(_ request: PermissionRequest, reply: @escaping (Bool) -> Void) {
        let window = context.windows.first { w in context.runtime.selectedTab(in: w)?.engineTab === request.tab } ?? context.keyWindow
        prompts.enqueue(PromptQueue.Pending(request: request, windowID: window?.id, remember: context.settings.bool("permissions.rememberByDefault")) { [weak self] granted, remember in
            guard let self else { return }
            if let site = SiteSettingsStore.site(for: request.origin) {
                if remember { for k in request.kinds { self.setDecision(granted ? .grant : .deny, k, for: site) } }
                self.record(site, request.kinds, granted: granted, source: "user")
            }
            reply(granted)
        })
    }

    func record(_ site: String, _ kinds: [PermissionRequest.Kind], granted: Bool, source: String) {
        log.insert(PermissionLogEntry(date: Date(), site: site, kinds: kinds.map(\.rawValue), granted: granted, source: source), at: 0)
        if log.count > 500 { log.removeLast(log.count - 500) }
        try? JSONEncoder().encode(log).write(to: logURL, options: .atomic)
    }
}

@Observable
final class PromptQueue {
    struct Pending: Identifiable {
        let id = UUID()
        let request: PermissionRequest
        let windowID: UUID?
        var remember: Bool
        let answer: (Bool, Bool) -> Void
    }

    private(set) var pending: [Pending] = []

    func enqueue(_ p: Pending) { withAnimation(.spring(duration: 0.3, bounce: 0.2)) { pending.append(p) } }

    func current(for window: BrowserWindowState) -> Pending? {
        pending.first { $0.windowID == nil || $0.windowID == window.id }
    }

    func answer(_ id: UUID, granted: Bool, remember: Bool) {
        guard let i = pending.firstIndex(where: { $0.id == id }) else { return }
        let p = pending.remove(at: i)
        p.answer(granted, remember)
    }
}

struct PermissionPrompt: View {
    let window: BrowserWindowState
    let queue: PromptQueue
    @State private var remember = true

    var body: some View {
        if let p = queue.current(for: window) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Image(systemName: Self.symbol(p.request.kinds)).font(.system(size: 20)).foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(SiteSettingsStore.site(for: p.request.origin) ?? p.request.origin.absoluteString).font(.headline)
                        Text("wants to use your \(Self.describe(p.request.kinds))").foregroundStyle(.secondary)
                    }
                }
                Toggle("Remember for this site", isOn: $remember).toggleStyle(.checkbox)
                HStack {
                    Spacer()
                    Button("Don't Allow") { withAnimation { queue.answer(p.id, granted: false, remember: remember) } }
                    Button("Allow") { withAnimation { queue.answer(p.id, granted: true, remember: remember) } }
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(16)
            .frame(width: 340)
            .overlayKeyboardFocus("permissions", in: window)
            .glassSurface(in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .shadow(color: .black.opacity(0.25), radius: 18, y: 6)
            .padding(.top, 54)
            .padding(.leading, window.isSidebarVisible ? window.sidebarWidth + 14 : 14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .transition(.move(edge: .top).combined(with: .opacity))
            .onAppear { remember = p.remember }
        }
    }

    static func describe(_ kinds: [PermissionRequest.Kind]) -> String {
        let names = kinds.map { k -> String in
            switch k {
            case .camera: "camera"
            case .microphone: "microphone"
            case .location: "location"
            case .notifications: "notifications"
            case .clipboard: "clipboard"
            case .midi: "MIDI devices"
            case .screenCapture: "screen"
            case .popups: "pop-up windows"
            case .autoplay: "sound autoplay"
            }
        }
        return ListFormatter.localizedString(byJoining: names)
    }

    static func symbol(_ kinds: [PermissionRequest.Kind]) -> String {
        if kinds.contains(.camera) { return "video.fill" }
        if kinds.contains(.microphone) { return "mic.fill" }
        if kinds.contains(.location) { return "location.fill" }
        if kinds.contains(.notifications) { return "bell.fill" }
        return "hand.raised.fill"
    }
}
