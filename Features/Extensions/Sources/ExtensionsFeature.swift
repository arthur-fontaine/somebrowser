import AppKit
import BrowserCore
import SwiftUI

/// Chrome extensions from the sidebar. The engine runs actions through Chrome's own toolbar machinery, so
/// popups, `action.onClicked` and `activeTab` behave as in Chrome (docs/decisions/0003); the panel manages them (what
/// Chrome's extensions page does), through the engine.
public final class ExtensionsFeature: BrowserFeature {
    let context: FeatureContext
    let model = ExtensionsModel()
    let sidePanels: SidePanels
    static let panelFlag = "extensions.panel"
    static let storeURL = URL(string: "https://chromewebstore.google.com/")!

    public init(context: FeatureContext) {
        self.context = context
        sidePanels = SidePanels(context: context)
    }

    var engine: EngineExtensions? { context.engine as? EngineExtensions }
    /// Extensions change their badges at will: read every few seconds while pinned actions show and the app is active.
    var badgeInterval: TimeInterval = 2
    private var badgeTimer: Timer?

    public func activate() {
        guard let engine else { return }  // engines without Chrome extensions: no buttons, commands stay unhandled
        model.extensions = engine.installedExtensions
        engine.onExtensionsChanged = { [weak self] in self?.model.extensions = self?.engine?.installedExtensions ?? [] }

        context.commands.handle("extensions.menu") { [weak self] inv in self?.showMenu(in: inv.window) }
        context.commands.handle("extensions.cycle") { [weak self] inv in self?.cyclePinned(in: inv.window) }
        context.commands.handle("extensions.run") { [weak self] inv in
            if let id = inv.arguments["id"] { self?.run(id, in: inv.window) }
        }
        // Managing one (arguments: `id`, and `enabled`, `access` or `allowed`): the panel's details, also for automation.
        context.commands.handle("extensions.set-enabled") { [weak self] inv in
            guard let id = inv.arguments["id"] else { return }
            self?.setEnabled(id, inv.arguments["enabled"] != "false")
        }
        context.commands.handle("extensions.site-access") { [weak self] inv in
            guard let id = inv.arguments["id"], let access = inv.arguments["access"].flatMap(ExtensionDetails.SiteAccess.init(rawValue:)) else { return }
            self?.setSiteAccess(id, access)
        }
        context.commands.handle("extensions.allow-private") { [weak self] inv in
            guard let id = inv.arguments["id"] else { return }
            self?.setAllowedInPrivate(id, inv.arguments["allowed"] != "false")
        }
        context.commands.handle("extensions.remove") { [weak self] inv in
            if let id = inv.arguments["id"] { self?.engine?.remove(id) }
        }
        context.commands.handle("extensions.store") { [weak self] inv in self?.open(Self.storeURL, in: inv.window) }
        context.commands.handle("extensions.side-panel", isEnabled: { [weak self] _ in self?.model.enabled.contains { $0.sidePanelPath != nil } == true }) {
            [weak self] inv in self?.toggleSidePanel(inv.arguments["id"], in: inv.window)
        }
        sidePanels.activate { [weak model] id in model?.icons[id] }
        context.capabilities.provide(NewTabPageProvider.self, self)

        let model = self.model, settings = context.settings
        context.ui.contribute(.overlay, id: "extensions.panel", order: 55) { [weak self] window in
            ExtensionsPanel(model: model, window: window, run: { self?.run($0, in: window) },
                            pin: { self?.engine?.setPinned($0, $1) }, open: { self?.open($0, in: window) },
                            sidePanel: { self?.toggleSidePanel($0, in: window) },
                            manage: ExtensionsPanel.Management(
                                show: { self?.showDetails($0) },
                                setEnabled: { self?.setEnabled($0, $1) },
                                setSiteAccess: { self?.setSiteAccess($0, $1) },
                                setAllowedInPrivate: { self?.setAllowedInPrivate($0, $1) },
                                remove: { id in window.flags.remove(Self.panelFlag); self?.engine?.remove(id) }),
                            close: { window.flags.remove(Self.panelFlag); model.shownDetails = nil })
        }
        context.ui.contribute("sidebar.header", id: "extensions.buttons", order: 200) { [weak self] window in
            ExtensionButtons(model: model, windowID: window.id, showPinned: settings.bool("extensions.showPinned"),
                             run: { self?.run($0, in: window) }, menu: { self?.showMenu(in: window) })
        }
        let timer = Timer(timeInterval: badgeInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshBadges() }
        }
        timer.tolerance = badgeInterval / 2  // coalesced with other wake-ups
        RunLoop.main.add(timer, forMode: .common)
        badgeTimer = timer
    }

    /// Each window's selected page's badges, if it's live (an asleep page shows none).
    func refreshBadges(force: Bool = false) {
        guard let engine, force || NSApp?.isActive == true else { return }
        var badges: [UUID: [String: String]] = [:]
        if context.settings.bool("extensions.showPinned"), !model.pinned.isEmpty {
            for window in context.windows {
                guard let page = context.runtime.selectedTab(in: window)?.engineTab else { continue }
                let found = engine.actionBadges(in: page)
                if !found.isEmpty { badges[window.id] = found }
            }
        }
        if badges != model.badges { model.badges = badges }
    }

    /// The selected page, loaded if it was discarded: actions always act on a live tab.
    func liveTab(in window: BrowserWindowState?) -> EngineTab? {
        guard let window, let tab = context.runtime.selectedTab(in: window) else { return nil }
        return context.runtime.live(tab)
    }

    func run(_ id: String, in window: BrowserWindowState?) {
        guard model.enabled.contains(where: { $0.id == id }) else { return }
        // Chrome would open its own side panel, which pages here can't show.
        if let window, let ext = model.extensions.first(where: { $0.id == id }), ext.opensSidePanelOnClick, ext.sidePanelPath != nil {
            return sidePanels.toggle(ext, in: window)
        }
        guard let engine, let tab = liveTab(in: window) else { return }
        engine.runAction(of: id, in: tab)
    }

    /// The given extension's panel, else the open one (closing it), else the last one used, else the first there is.
    func toggleSidePanel(_ id: String?, in window: BrowserWindowState?) {
        guard let window else { return }
        let withPanels = model.enabled.filter { $0.sidePanelPath != nil }
        let wanted = id ?? sidePanels.model.panels[window.id]?.extensionID ?? sidePanels.model.lastUsed
        guard let ext = withPanels.first(where: { $0.id == wanted }) ?? withPanels.first else { return }
        sidePanels.toggle(ext, in: window)
    }

    /// Arc's ⌘E: each press runs the next pinned extension (its popup, usually); nothing pinned: the extensions menu.
    func cyclePinned(in window: BrowserWindowState?) {
        let pinned = model.pinned
        guard !pinned.isEmpty else { return showMenu(in: window) }
        let next = pinned.firstIndex { $0.id == model.lastCycled }.map { (pinned.index(after: $0)) % pinned.count } ?? 0
        model.lastCycled = pinned[next].id
        run(pinned[next].id, in: window)
    }

    /// The browser's own extensions panel (Chrome's menu never shows).
    func showMenu(in window: BrowserWindowState?) {
        window?.toggle(flag: Self.panelFlag)
    }

    func open(_ url: URL, in window: BrowserWindowState?) {
        guard let window else { return }
        context.runtime.openTab(url, in: window)
    }

    // MARK: Managing (what Chrome's extensions page does)

    /// One extension's details in the panel (nil: the list).
    func showDetails(_ id: String?) {
        model.shownDetails = id
        guard let id else { return }
        loadDetails(id)
    }

    func loadDetails(_ id: String) {
        engine?.details(of: id) { [weak self] details in
            guard let self else { return }
            if let details { self.model.details[id] = details } else { self.model.details[id] = nil }
        }
    }

    func setEnabled(_ id: String, _ enabled: Bool) {
        model.details[id]?.isEnabled = enabled
        engine?.setEnabled(id, enabled)
        loadDetails(id)
    }

    func setSiteAccess(_ id: String, _ access: ExtensionDetails.SiteAccess) {
        model.details[id]?.siteAccess = access
        engine?.setSiteAccess(id, access)
        loadDetails(id)
    }

    func setAllowedInPrivate(_ id: String, _ allowed: Bool) {
        model.details[id]?.allowedInPrivate = allowed
        engine?.setAllowedInPrivate(id, allowed)
        loadDetails(id)
    }
}

/// An extension that replaces the new tab page gets new tabs, as in Chrome (the first one, pinned first, if several do).
extension ExtensionsFeature: NewTabPageProvider {
    public func newTabPage(in window: BrowserWindowState) -> URL? {
        guard !window.isPrivate, context.settings.bool("extensions.newTabPage") else { return nil }
        return model.enabled.lazy.compactMap { ext in ext.newTabPagePath.flatMap(ext.page) }.first
    }
}

@Observable
final class ExtensionsModel {
    var extensions: [BrowserExtension] = [] {
        didSet {
            // Decoded once per change, never while the sidebar renders.
            icons = Dictionary(uniqueKeysWithValues: extensions.compactMap { ext in
                (ext.icon.flatMap { icons[ext.id] ?? NSImage(contentsOf: $0) }).map { (ext.id, $0) }
            })
        }
    }
    private(set) var icons: [String: NSImage] = [:]
    /// The pinned extension ⌘E ran last.
    var lastCycled: String?
    /// Badge text by window, then extension id.
    var badges: [UUID: [String: String]] = [:]
    /// The extension whose details the panel shows, and the details read so far.
    var shownDetails: String?
    var details: [String: ExtensionDetails] = [:]
    /// Turned on: these run, and have buttons.
    var enabled: [BrowserExtension] { extensions.filter(\.isEnabled) }
    var pinned: [BrowserExtension] { enabled.filter(\.isPinned) }
}

/// Pinned actions and the extensions menu, next to the navigation buttons; Chrome opens popups beside them.
struct ExtensionButtons: View {
    let model: ExtensionsModel
    let windowID: UUID
    let showPinned: Bool
    let run: (String) -> Void
    let menu: () -> Void

    var body: some View {
        if !model.extensions.isEmpty {
            HStack(spacing: 0) {
                if showPinned {
                    ForEach(model.pinned) { ext in
                        ExtensionIcon(title: ext.name, image: model.icons[ext.id], badge: model.badges[windowID]?[ext.id]) { run(ext.id) }
                    }
                }
                ExtensionIcon(title: "Extensions", image: nil, help: "Extensions (⌘⇧E)", action: menu)
            }
            .glassControl(in: Capsule())
        }
    }
}

struct ExtensionIcon: View {
    let title: String
    let image: NSImage?
    var badge: String?
    var help: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Group {
                if let image {
                    Image(nsImage: image).resizable().interpolation(.high).frame(width: 16, height: 16)
                } else {
                    Image(systemName: "puzzlepiece.extension").font(.system(size: 15, weight: .medium))
                }
            }
            .frame(width: Design.Size.control, height: Design.Size.control)
            .overlay(alignment: .bottomTrailing) {
                if let badge, !badge.isEmpty {
                    Text(badge.prefix(4))
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 3)
                        .frame(minWidth: 12, minHeight: 11)
                        .background(Capsule().fill(Color.red))
                        .offset(x: -1, y: -2)
                        .accessibilityHidden(true)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
        .help(help ?? title)
        .accessibilityLabel(title)
        .accessibilityValue(badge ?? "")
    }
}

/// Every extension: run its action, show it in the sidebar or not, its options and side panel, and its details
/// (turning it off, site access, private windows, permissions, removal: what Chrome's extensions page does); the Web
/// Store adds more.
struct ExtensionsPanel: View {
    struct Management {
        let show: (String?) -> Void
        let setEnabled: (String, Bool) -> Void
        let setSiteAccess: (String, ExtensionDetails.SiteAccess) -> Void
        let setAllowedInPrivate: (String, Bool) -> Void
        let remove: (String) -> Void
    }

    let model: ExtensionsModel
    let window: BrowserWindowState
    let run: (String) -> Void
    let pin: (String, Bool) -> Void
    let open: (URL) -> Void
    let sidePanel: (String) -> Void
    let manage: Management
    let close: () -> Void

    var body: some View {
        if window.flags.contains(ExtensionsFeature.panelFlag) {
            ZStack(alignment: .topLeading) {
                Color.black.opacity(0.001).contentShape(Rectangle()).onTapGesture(perform: close)
                Group {
                    if let id = model.shownDetails, let ext = model.extensions.first(where: { $0.id == id }) {
                        ExtensionDetailsView(ext: ext, icon: model.icons[ext.id], details: model.details[id], manage: manage,
                                             options: ext.optionsPath.flatMap(ext.page).map { url in { close(); open(url) } })
                    } else {
                        list
                    }
                }
                .padding(6)
                .frame(width: 320)
                .glassSurface(in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .padding(.top, 52)
                .padding(.leading, 8)
                .transition(.scale(scale: 0.96, anchor: .topLeading).combined(with: .opacity))
            }
            .onExitCommand { if model.shownDetails != nil { manage.show(nil) } else { close() } }
        }
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Extensions").font(.headline).padding(.horizontal, 10).padding(.top, 6).padding(.bottom, 4)
            if model.extensions.isEmpty {
                Text("No extensions yet").foregroundStyle(.secondary).padding(10)
            }
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(model.extensions) { ext in
                        ExtensionRow(ext: ext, icon: model.icons[ext.id],
                                     run: { close(); run(ext.id) }, pin: { pin(ext.id, !ext.isPinned) },
                                     options: ext.optionsPath.flatMap(ext.page).map { url in { close(); open(url) } },
                                     sidePanel: ext.sidePanelPath == nil ? nil : { close(); sidePanel(ext.id) },
                                     details: { manage.show(ext.id) })
                    }
                }
            }
            .frame(maxHeight: 360)
            Divider().padding(.vertical, 4)
            HStack {
                Spacer()
                Button("Chrome Web Store") { close(); open(ExtensionsFeature.storeURL) }
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 10).padding(.bottom, 6)
        }
    }
}

/// One extension's details: what Chrome's extensions page shows and changes, in the browser's panel.
struct ExtensionDetailsView: View {
    let ext: BrowserExtension
    let icon: NSImage?
    let details: ExtensionDetails?
    let manage: ExtensionsPanel.Management
    let options: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Button { manage.show(nil) } label: { Image(systemName: "chevron.left") }
                    .buttonStyle(.borderless)
                    .help("Extensions")
                    .accessibilityLabel("Back to Extensions")
                Group {
                    if let icon { Image(nsImage: icon).resizable().interpolation(.high) } else { Image(systemName: "puzzlepiece.extension") }
                }
                .frame(width: 20, height: 20)
                VStack(alignment: .leading, spacing: 0) {
                    Text(ext.name).font(.headline).lineLimit(1)
                    if let version = details?.version, !version.isEmpty {
                        Text("Version \(version)").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            if let details {
                if !details.summary.isEmpty {
                    Text(details.summary).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Toggle("On", isOn: Binding(get: { details.isEnabled }, set: { manage.setEnabled(ext.id, $0) }))
                    .disabled(!details.isUserModifiable)
                if let access = details.siteAccess {
                    Picker("Site access", selection: Binding(get: { access }, set: { manage.setSiteAccess(ext.id, $0) })) {
                        Text("When you click it").tag(ExtensionDetails.SiteAccess.onClick)
                        if access == .onSpecificSites { Text("On specific sites").tag(ExtensionDetails.SiteAccess.onSpecificSites) }
                        Text("On all sites").tag(ExtensionDetails.SiteAccess.onAllSites)
                    }
                    .pickerStyle(.menu)
                }
                Toggle("Allow in private windows", isOn: Binding(get: { details.allowedInPrivate }, set: { manage.setAllowedInPrivate(ext.id, $0) }))
                if !details.permissions.isEmpty {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("It can").font(.subheadline.weight(.semibold))
                        ForEach(details.permissions, id: \.self) { Text("• \($0)").font(.callout).foregroundStyle(.secondary) }
                    }
                }
                HStack {
                    if let options { Button("Options", action: options) }
                    Spacer()
                    Button("Remove…", role: .destructive) { manage.remove(ext.id) }
                        .disabled(!details.isUserModifiable)
                }
                .padding(.top, 4)
            } else {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity)
            }
        }
        .padding(10)
    }
}

struct ExtensionRow: View {
    let ext: BrowserExtension
    let icon: NSImage?
    let run: () -> Void
    let pin: () -> Void
    let options: (() -> Void)?
    let sidePanel: (() -> Void)?
    let details: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Button(action: run) {
                HStack(spacing: 8) {
                    Group {
                        if let icon { Image(nsImage: icon).resizable().interpolation(.high) } else { Image(systemName: "puzzlepiece.extension") }
                    }
                    .frame(width: 18, height: 18)
                    Text(ext.name).lineLimit(1)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!ext.isEnabled)
            .opacity(ext.isEnabled ? 1 : 0.5)
            .accessibilityLabel(ext.isEnabled ? ext.name : "\(ext.name), off")
            if let sidePanel, ext.isEnabled {
                Button(action: sidePanel) { Image(systemName: "sidebar.right") }.buttonStyle(.borderless).help("Side Panel")
            }
            if let options, ext.isEnabled {
                Button(action: options) { Image(systemName: "gearshape") }.buttonStyle(.borderless).help("Options")
            }
            Button(action: pin) { Image(systemName: ext.isPinned ? "pin.fill" : "pin") }
                .buttonStyle(.borderless)
                .help(ext.isPinned ? "Hide from the Sidebar" : "Show in the Sidebar")
                .accessibilityLabel(ext.isPinned ? "Hide \(ext.name) from the Sidebar" : "Show \(ext.name) in the Sidebar")
            Button(action: details) { Image(systemName: "info.circle") }
                .buttonStyle(.borderless)
                .help("Details")
                .accessibilityLabel("\(ext.name) Details")
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, 8)
        .frame(height: 30)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(hovering ? Color.primary.opacity(0.08) : .clear))
        .onHover { hovering = $0 }
    }
}
