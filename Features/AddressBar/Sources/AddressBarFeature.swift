import AppKit
import BrowserCore
import SwiftUI

public final class AddressBarFeature: BrowserFeature {
    let context: FeatureContext

    public init(context: FeatureContext) { self.context = context }

    public func activate() {
        let settings = context.settings
        context.ui.contribute("sidebar.address", id: "address-bar.pill") { window in
            AddressPill(window: window, showFullURL: settings.bool("address-bar.showFullURL"))
        }
        context.commands.handle("address-bar.developer-mode", isEnabled: { [weak self] inv in self?.site(in: inv.window) != nil }) { [weak self] inv in
            self?.toggleDeveloperMode(in: inv.window)
        }
    }

    func site(in window: BrowserWindowState?) -> (site: String, url: URL)? {
        guard let window, let url = context.runtime.selectedTab(in: window)?.url, ["http", "https"].contains(url.scheme),
              let site = SiteSettingsStore.site(for: url) else { return nil }
        return (site, url)
    }

    /// Developer mode (Arc, ⌃D) for the current site: where you really are (port, path, query) in the address.
    func toggleDeveloperMode(in window: BrowserWindowState?) {
        guard let (site, url) = site(in: window) else { return }
        let on = !AddressFormatter.developerMode(url, store: context.siteSettings)
        context.siteSettings.set(AddressFormatter.developerKey, .bool(on), for: site)
        context.notify(on ? "Developer mode on for \(site)" : "Developer mode off for \(site)", systemImage: "hammer", window: window)
    }
}

enum AddressFormatter {
    static let developerKey = "address-bar.developer"

    /// Local development servers, where developer mode is on unless turned off.
    static func isLocal(_ url: URL?) -> Bool {
        guard let host = url?.host()?.lowercased() else { return false }
        return ["localhost", "127.0.0.1", "::1"].contains(host) || [".localhost", ".test", ".local"].contains { host.hasSuffix($0) }
    }

    static func developerMode(_ url: URL?, store: SiteSettingsStore) -> Bool {
        guard let url, ["http", "https"].contains(url.scheme), let site = SiteSettingsStore.site(for: url) else { return false }
        return store.bool(developerKey, for: site) ?? isLocal(url)
    }

    /// Developer mode's address: host, port, path and query.
    static func developerDisplay(_ url: URL) -> String {
        var text = url.host() ?? ""
        if let port = url.port { text += ":\(port)" }
        if url.path() != "/" { text += url.path() }
        if let query = url.query() { text += "?" + query }
        return text
    }

    /// What the pill shows: the host without `www.` (Arc), or the full URL.
    static func display(_ url: URL?, full: Bool) -> String {
        guard let url else { return "" }
        if full { return url.absoluteString }
        switch url.scheme {
        case "http", "https":
            var host = url.host() ?? url.absoluteString
            if host.hasPrefix("www.") { host.removeFirst(4) }
            return host
        case "file": return url.lastPathComponent
        default: return url.absoluteString
        }
    }

    static func symbol(for security: SecurityLevel) -> String? {
        switch security {
        case .insecure: return "exclamationmark.triangle.fill"
        case .local: return "desktopcomputer"
        default: return nil
        }
    }
}

struct AddressPill: View {
    @Environment(BrowserEnvironment.self) private var env
    let window: BrowserWindowState
    let showFullURL: Bool
    @State private var hovering = false

    var body: some View {
        let runtime = env.runtime
        let tab = runtime.selectedTab(in: window)
        let live = tab?.live
        let url = live?.url ?? tab?.url
        let developer = AddressFormatter.developerMode(url, store: runtime.siteSettings)
        let text = developer && !showFullURL ? url.map(AddressFormatter.developerDisplay) ?? "" : AddressFormatter.display(url, full: showFullURL)
        HStack(spacing: 6) {
            if runtime.commands.isHandled("site-controls.show") {
                Button { try? runtime.commands.run("site-controls.show", window: window) } label: {
                    Image(systemName: "slider.horizontal.3").font(.system(size: 11, weight: .semibold))
                        .frame(width: 22, height: 22).contentShape(Rectangle())
                }
                .buttonStyle(.plain).foregroundStyle(.secondary).help("Site Controls")
            }
            if developer {
                Image(systemName: "hammer.fill").font(.system(size: 10)).foregroundStyle(.secondary).help("Developer mode (⌃D)")
            } else if let symbol = live.flatMap({ AddressFormatter.symbol(for: $0.security) }) {
                Image(systemName: symbol).font(.system(size: 10)).foregroundStyle(.orange)
            }
            Text(text.isEmpty ? "Search or enter address" : text)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(text.isEmpty ? .tertiary : .primary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: showFullURL || developer ? .leading : .center)
            if hovering, let url {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(url.absoluteString, forType: .string)
                    if runtime.commands.isHandled("navigation.copy-url") { try? runtime.commands.run("navigation.copy-url", window: window) }
                } label: {
                    Image(systemName: "link").font(.system(size: 11, weight: .semibold)).frame(width: 22, height: 22)
                }
                .buttonStyle(.plain).foregroundStyle(.secondary).help("Copy URL (⌘⇧C)")
                .transition(.opacity)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 36)
        .glassControl(in: Capsule())
        .overlay(alignment: .bottom) {
            if let live, live.isLoading {
                GeometryReader { g in
                    Capsule().fill(.tint).frame(width: max(8, g.size.width * live.estimatedProgress), height: 2)
                        .animation(.easeOut(duration: 0.25), value: live.estimatedProgress)
                }
                .frame(height: 2)
                .padding(.horizontal, 16)
                .padding(.bottom, 1)
                .transition(.opacity)
            }
        }
        .contentShape(Rectangle())
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hovering = h } }
        .onTapGesture {
            if runtime.commands.isHandled("command-bar.edit-url") { try? runtime.commands.run("command-bar.edit-url", window: window) }
        }
        .help(url?.absoluteString ?? "")
    }
}
