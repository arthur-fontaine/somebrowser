import BrowserCore
import SwiftUI

/// Security Core (Radian, "verify where your data goes"): the connections the browser makes by itself — logged by Core's
/// `OutboundConnections`, which every feature and engine must use — and the permission broker's decisions, in one panel.
public final class SecurityCoreFeature: BrowserFeature {
    let context: FeatureContext
    static let panelFlag = "security-core.panel"

    public init(context: FeatureContext) {
        self.context = context
    }

    public func activate() {
        context.commands.handle("security-core.show") { inv in
            guard let window = inv.window else { return }
            if window.flags.contains(Self.panelFlag) { window.flags.remove(Self.panelFlag) } else { window.flags.insert(Self.panelFlag) }
        }
        let runtime = context.runtime
        context.ui.contribute(.overlay, id: "security-core.panel", order: 89) { window in
            SecurityCorePanel(window: window, outbound: runtime.outbound, permissions: runtime.capabilities.resolve(PermissionsService.self),
                              close: { window.flags.remove(Self.panelFlag) })
        }
    }
}

/// One host the browser contacted, with what for.
struct HostActivity: Identifiable, Equatable {
    var host: String
    var count: Int
    var failures: Int
    var purposes: [String]
    var sources: [String]
    var last: Date
    var id: String { host }

    /// Newest first; `purpose` keeps only that purpose's requests.
    static func group(_ entries: [OutboundConnections.Entry], purpose: String? = nil) -> [HostActivity] {
        var byHost: [String: HostActivity] = [:]
        for e in entries where purpose == nil || e.purpose == purpose {
            var a = byHost[e.host] ?? HostActivity(host: e.host, count: 0, failures: 0, purposes: [], sources: [], last: e.date)
            a.count += 1
            if e.failure != nil || (e.status ?? 200) >= 400 { a.failures += 1 }
            if !a.purposes.contains(e.purpose) { a.purposes.append(e.purpose) }
            if !a.sources.contains(e.source) { a.sources.append(e.source) }
            a.last = max(a.last, e.date)
            byHost[e.host] = a
        }
        return byHost.values.sorted { $0.last > $1.last }
    }
}
