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

    /// Controls other features put in the field's trailing end, right to left by descending order.
    static let trailingSlot: SlotID = "address-bar.trailing"
    /// What this field last published (the docked and the floating sidebar each have one).
    @State private var published: CGRect = .zero

    var body: some View {
        let runtime = env.runtime
        let tab = runtime.selectedTab(in: window)
        let live = tab?.live
        let url = live?.url ?? tab?.url
        let developer = AddressFormatter.developerMode(url, store: runtime.siteSettings)
        let text = developer && !showFullURL ? url.map(AddressFormatter.developerDisplay) ?? "" : AddressFormatter.display(url, full: showFullURL)
        let warning = live.flatMap { AddressFormatter.symbol(for: $0.security) }
        // On the sidebar's grid: the leading symbol in the rows' icon column, the address on their title column.
        HStack(spacing: Design.Grid.iconToText) {
            Button { try? runtime.commands.run("site-controls.show", window: window) } label: {
                // A blank tab has no site to control: the magnifier, as the editor that opens from here shows.
                Image(systemName: url == nil ? "magnifyingglass" : developer ? "hammer.fill" : warning ?? "slider.horizontal.3")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(warning != nil && !developer ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                    .frame(width: Design.Size.favicon, height: Design.Size.control)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!runtime.commands.isHandled("site-controls.show") || url.map { SiteSettingsStore.site(for: $0) == nil } == true)
            .help(developer ? "Developer mode (⌃D)" : "Site Controls")
            Text(text.isEmpty ? "Search or enter address" : text)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(text.isEmpty ? .tertiary : .primary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            // Its trailing end: extensions, then reload (Navigation), as Safari puts them in its address field.
            HStack(spacing: 0) { SlotHost(Self.trailingSlot, window: window) }
        }
        .padding(.leading, Design.Grid.iconInset)
        .padding(.trailing, Design.AddressField.trailingInset)
        .frame(height: Design.Size.control)
        .glassControl(in: Capsule())
        // Edited in place by an editor drawn over it (the command bar's inline style), which grows from this frame.
        .opacity(window.isEditingAddress ? 0 : 1)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
            published = frame
            if window.addressFieldFrame != frame { window.addressFieldFrame = frame }
        }
        .onDisappear { if window.addressFieldFrame == published { window.addressFieldFrame = .zero } }
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
        .onTapGesture {
            if runtime.commands.isHandled("command-bar.edit-url") { try? runtime.commands.run("command-bar.edit-url", window: window) }
        }
        .help(url?.absoluteString ?? "")
    }
}
