import AppKit
import BrowserCore
import SwiftUI

public extension SlotID {
    /// Extra toggles inside the site controls popover (ad blocking, pop-out view…).
    static let siteControlsRows: SlotID = "site-controls.rows"
}

public final class SiteControlsFeature: BrowserFeature {
    let context: FeatureContext
    static let flag = "site-controls"
    static let mutedKey = "site-controls.muted"

    public init(context: FeatureContext) { self.context = context }

    public func activate() {
        context.commands.handle("site-controls.show", isEnabled: { [weak self] inv in
            guard let self, let w = inv.window else { return false }
            return self.context.runtime.selectedTab(in: w)?.live?.url != nil
        }) { inv in inv.window?.toggle(flag: Self.flag) }

        // Per-site sound: applied on every navigation.
        context.events.subscribe(TabNavigated.self) { [weak self] e in
            guard let self, let tab = self.context.tabs.tab(e.tabID)?.engineTab, let site = SiteSettingsStore.site(for: e.url) else { return }
            let muted = self.context.siteSettings.bool(Self.mutedKey, for: site) ?? false
            if tab.isMuted != muted { tab.isMuted = muted }
        }
        context.events.subscribe(TabSelected.self) { [weak self] e in
            self?.context.runtime.window(e.windowID)?.flags.remove(Self.flag)
        }
        let feature = self
        context.ui.contribute(.overlay, id: "site-controls.popover", order: 110) { window in
            SiteControlsPopover(window: window, feature: feature)
        }
    }

    func setMuted(_ muted: Bool, site: String) {
        context.siteSettings.set(Self.mutedKey, muted ? .bool(true) : nil, for: site)
        for tab in context.tabs.allTabs where SiteSettingsStore.site(for: tab.live?.url) == site {
            tab.engineTab?.isMuted = muted
        }
    }

    func clearData(site: String) async {
        await (context.engine as? EngineSiteData)?.clearData(for: site)
        context.notify("Cleared data for \(site)", systemImage: "trash")
    }
}

struct SiteControlsPopover: View {
    @Environment(BrowserEnvironment.self) private var env
    let window: BrowserWindowState
    let feature: SiteControlsFeature
    @State private var dataSize: Int64?
    @State private var showPermissions = false

    var body: some View {
        if window.flags.contains(SiteControlsFeature.flag), let tab = env.runtime.selectedTab(in: window),
           let live = tab.live, let site = SiteSettingsStore.site(for: live.url) {
            ZStack(alignment: .topLeading) {
                Color.clear.contentShape(Rectangle()).onTapGesture { close() }
                panel(site: site, live: live)
                    .padding(.top, window.isSidebarVisible ? 84 : 46)
                    .padding(.leading, window.isSidebarVisible ? 10 : 60)
                    .transition(.scale(scale: 0.9, anchor: .topLeading).combined(with: .opacity))
            }
            .onKeyPress(.escape) { close(); return .handled }
        }
    }

    private func close() { withAnimation(.spring(duration: 0.25)) { _ = window.flags.remove(SiteControlsFeature.flag) } }

    @ViewBuilder
    private func panel(site: String, live: EngineTabState) -> some View {
        let permissions = env.runtime.capabilities.permissions
        let muted = env.runtime.siteSettings.bool(SiteControlsFeature.mutedKey, for: site) ?? false
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: live.security == .secure ? "lock.fill" : "lock.open.fill")
                Text(live.security == .secure ? "Connection is Secure" : live.security == .local ? "Local Page" : "Connection is Not Secure")
                    .font(.system(size: 13, weight: .semibold))
            }
            .foregroundStyle(live.security == .secure ? .green : .orange)
            .padding(.horizontal, 14).frame(height: 40)
            Divider()
            VStack(spacing: 2) {
                if let permissions {
                    PermissionToggle(title: "Camera", on: "video", off: "video.slash", kind: .camera, site: site, service: permissions)
                    PermissionToggle(title: "Microphone", on: "mic", off: "mic.slash", kind: .microphone, site: site, service: permissions)
                }
                ControlRow(title: "Sound", symbol: muted ? "speaker.slash" : "speaker.wave.2", isOn: Binding(
                    get: { !muted }, set: { feature.setMuted(!$0, site: site) }))
                SlotHost(.siteControlsRows, window: window)
            }
            .padding(6)
            Divider()
            VStack(spacing: 2) {
                Button { Task { await feature.clearData(site: site); dataSize = nil } } label: {
                    HStack {
                        Label("Data and Cookies", systemImage: "externaldrive")
                        Spacer()
                        Text(dataSize.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "Clear")
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 8).frame(height: 30).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if let permissions {
                    Button { withAnimation(.spring(duration: 0.3)) { showPermissions.toggle() } } label: {
                        HStack {
                            Label("Permissions", systemImage: "hand.raised")
                            Spacer()
                            Image(systemName: "chevron.right").rotationEffect(.degrees(showPermissions ? 90 : 0)).foregroundStyle(.tertiary)
                        }
                        .padding(.horizontal, 8).frame(height: 30).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if showPermissions {
                        PermissionList(site: site, service: permissions).transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }
            }
            .padding(6)
        }
        .font(.system(size: 13))
        .frame(width: 300)
        .glassSurface(in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(color: .black.opacity(0.25), radius: 20, y: 8)
        .task(id: site) { dataSize = await (env.runtime.engine as? EngineSiteData)?.dataSize(for: site) }
    }
}

/// A row with an icon that morphs with its state (Radian's speaker waves) and an animated switch.
struct ControlRow: View {
    let title: String
    let symbol: String
    @Binding var isOn: Bool
    @State private var hovering = false

    var body: some View {
        HStack {
            Image(systemName: symbol).contentTransition(.symbolEffect(.replace)).frame(width: 20)
            Text(title)
            Spacer()
            Toggle("", isOn: $isOn.animation(.spring(duration: 0.3, bounce: 0.3))).toggleStyle(.switch).labelsHidden().controlSize(.small)
        }
        .padding(.horizontal, 8)
        .frame(height: 32)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(hovering ? Color.primary.opacity(0.05) : .clear))
        .onHover { hovering = $0 }
    }
}

struct PermissionToggle: View {
    let title: String
    let on: String
    let off: String
    let kind: PermissionRequest.Kind
    let site: String
    let service: PermissionsService
    @State private var refresh = 0

    var body: some View {
        let granted = service.decision(kind, for: site) == .grant
        ControlRow(title: title, symbol: granted ? on : off, isOn: Binding(
            get: { _ = refresh; return service.decision(kind, for: site) == .grant },
            set: { service.setDecision($0 ? .grant : nil, kind, for: site); refresh += 1 }))
    }
}

struct PermissionList: View {
    let site: String
    let service: PermissionsService

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach([PermissionRequest.Kind.camera, .microphone, .location, .notifications, .clipboard, .popups], id: \.self) { kind in
                HStack {
                    Text(kind.rawValue.capitalized).foregroundStyle(.secondary)
                    Spacer()
                    Picker("", selection: Binding(
                        get: { service.decision(kind, for: site).map { $0 == .grant ? "allow" : "block" } ?? "ask" },
                        set: { service.setDecision($0 == "allow" ? .grant : $0 == "block" ? .deny : nil, kind, for: site) })) {
                        Text("Ask").tag("ask")
                        Text("Allow").tag("allow")
                        Text("Block").tag("block")
                    }
                    .labelsHidden().pickerStyle(.menu).controlSize(.small).frame(width: 90)
                }
            }
            if let last = service.log.first(where: { $0.site == site }) {
                Text("Last: \(last.granted ? "allowed" : "blocked") \(last.kinds.joined(separator: ", ")) \(last.date.formatted(.relative(presentation: .named)))")
                    .font(.caption).foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 10).padding(.bottom, 6)
    }
}
