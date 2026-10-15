import BrowserCore
import SwiftUI

struct SecurityCorePanel: View {
    let window: BrowserWindowState
    let outbound: OutboundConnections
    let permissions: PermissionsService?
    let close: () -> Void
    @State private var tab = Tab.connections
    @State private var purpose: String?

    enum Tab: String, CaseIterable { case connections = "Connections", permissions = "Permissions" }

    var body: some View {
        if window.flags.contains(SecurityCoreFeature.panelFlag) {
            ZStack {
                Color.black.opacity(0.15).contentShape(Rectangle()).onTapGesture(perform: close)
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Label("Security Core", systemImage: "lock.shield").font(.title3.bold())
                        Spacer()
                        Picker("", selection: $tab) { ForEach(Tab.allCases, id: \.self) { Text($0.rawValue) } }
                            .pickerStyle(.segmented).labelsHidden().frame(width: 240)
                    }
                    switch tab {
                    case .connections: connections
                    case .permissions: permissionLog
                    }
                    HStack {
                        Spacer()
                        Button("Done", action: close).keyboardShortcut(.cancelAction)
                    }
                }
                .padding(20)
                .frame(width: 640, height: 520)
                .overlayKeyboardFocus("security-core", in: window)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .shadow(color: .black.opacity(0.25), radius: 24, y: 10)
                .transition(.scale(scale: 0.96).combined(with: .opacity))
            }
        }
    }

    private var connections: some View {
        let hosts = HostActivity.group(outbound.entries, purpose: purpose)
        let purposes = Array(Set(outbound.entries.map(\.purpose))).sorted()
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(summary(hosts)).foregroundStyle(.secondary)
                Spacer()
                Picker("Purpose", selection: $purpose) {
                    Text("All purposes").tag(String?.none)
                    ForEach(purposes, id: \.self) { Text($0).tag(String?.some($0)) }
                }
                .frame(width: 210)
                Button("Clear") { outbound.clear() }.disabled(outbound.entries.isEmpty)
            }
            .font(.callout)
            List(hosts) { host in
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(host.host.isEmpty ? "—" : host.host).fontWeight(.medium)
                        Text(host.purposes.joined(separator: " · ") + "  (" + host.sources.joined(separator: ", ") + ")")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if host.failures > 0 {
                        Text("\(host.failures) failed").font(.caption).foregroundStyle(.orange)
                    }
                    Text("×\(host.count)").monospacedDigit().foregroundStyle(.secondary)
                    Text(host.last, style: .relative).font(.caption).foregroundStyle(.tertiary).frame(width: 90, alignment: .trailing)
                }
            }
            .listStyle(.inset)
            .overlay { if hosts.isEmpty { Text("The browser hasn't contacted anyone by itself.").foregroundStyle(.secondary) } }
            Label {
                Text("Not listed: pages and extensions, and Chromium's own requests — update checks to the Chrome Web Store for "
                     + "extensions installed from it. With none installed, an idle browser contacts nobody (tested).")
            } icon: { Image(systemName: "info.circle") }
            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var permissionLog: some View {
        let log = permissions?.log ?? []
        return List(log) { entry in
            HStack {
                Image(systemName: entry.granted ? "checkmark.circle.fill" : "xmark.circle.fill").foregroundStyle(entry.granted ? .green : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.site).fontWeight(.medium)
                    Text(entry.kinds.joined(separator: ", ") + " · " + entry.source).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text(entry.date, style: .relative).font(.caption).foregroundStyle(.tertiary)
            }
        }
        .listStyle(.inset)
        .overlay {
            if permissions == nil { Text("No permission broker in this build.").foregroundStyle(.secondary) }
            else if log.isEmpty { Text("No site has asked for a permission yet.").foregroundStyle(.secondary) }
        }
    }

    private func summary(_ hosts: [HostActivity]) -> String {
        let requests = hosts.reduce(0) { $0 + $1.count }
        return "\(requests) request\(requests == 1 ? "" : "s") to \(hosts.count) host\(hosts.count == 1 ? "" : "s")"
    }
}
