import AppKit
import BrowserCore
import SwiftUI

public final class AddressBarFeature: BrowserFeature {
    let context: FeatureContext

    public init(context: FeatureContext) { self.context = context }

    public func activate() {
        place()
        context.settings.observe("address-bar.position") { [weak self] _ in self?.place() }
    }

    /// The pill lives in exactly one slot depending on the setting.
    func place() {
        let ui = context.ui
        ui.remove(id: "address-bar.pill")
        let slot: SlotID = context.settings.string("address-bar.position") == "toolbar" ? "toolbar.center" : "sidebar.address"
        let settings = context.settings
        ui.contribute(slot, id: "address-bar.pill") { window in
            AddressPill(window: window, showFullURL: settings.bool("address-bar.showFullURL"))
        }
    }
}

enum AddressFormatter {
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
        let text = AddressFormatter.display(url, full: showFullURL)
        HStack(spacing: 6) {
            if runtime.commands.isHandled("site-controls.show") {
                Button { try? runtime.commands.run("site-controls.show", window: window) } label: {
                    Image(systemName: "slider.horizontal.3").font(.system(size: 11, weight: .semibold))
                        .frame(width: 22, height: 22).contentShape(Rectangle())
                }
                .buttonStyle(.plain).foregroundStyle(.secondary).help("Site Controls")
            }
            if let symbol = live.flatMap({ AddressFormatter.symbol(for: $0.security) }) {
                Image(systemName: symbol).font(.system(size: 10)).foregroundStyle(.orange)
            }
            Text(text.isEmpty ? "Search or enter address" : text)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(text.isEmpty ? .tertiary : .primary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: showFullURL ? .leading : .center)
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
        .padding(.horizontal, 6)
        .frame(height: 32)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.primary.opacity(hovering ? 0.09 : 0.06)))
        .overlay(alignment: .bottom) {
            if let live, live.isLoading {
                GeometryReader { g in
                    Capsule().fill(.tint).frame(width: max(8, g.size.width * live.estimatedProgress), height: 2)
                        .animation(.easeOut(duration: 0.25), value: live.estimatedProgress)
                }
                .frame(height: 2)
                .padding(.horizontal, 8)
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
