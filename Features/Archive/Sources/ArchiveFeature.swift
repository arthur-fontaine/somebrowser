import AppKit
import BrowserCore
import SwiftUI

public final class ArchiveFeature: BrowserFeature {
    let context: FeatureContext
    let store: ArchiveStore
    private var timer: Timer?
    static let panelFlag = "archive.panel"

    public init(context: FeatureContext) {
        self.context = context
        store = ArchiveStore(url: context.dataDirectory.appendingPathComponent("archive.json"))
    }

    public func activate() {
        context.commands.handle("archive.show") { inv in inv.window?.toggle(flag: Self.panelFlag) }
        context.commands.handle("archive.run-now") { [weak self] inv in
            guard let self else { return }
            let n = self.archiveIdleTabs(now: Date(), force: true)
            self.context.notify(n == 0 ? "Nothing to archive" : "Archived \(n) tab\(n == 1 ? "" : "s")", systemImage: "archivebox", window: inv.window)
        }
        context.capabilities.contribute(OmniboxProvider.self, ArchiveOmnibox(feature: self))
        let store = self.store
        let runtime = context.runtime
        context.ui.contribute("sidebar.top", id: "archive.row", order: 0) { window in ArchiveRow(window: window, store: store) }
        context.ui.contribute(.overlay, id: "archive.panel", order: 70) { window in ArchivePanel(window: window, store: store, runtime: runtime) }
        context.ui.contribute("start-page.extras", id: "archive.recent", order: 2) { [weak self] window in
            RecentlyArchived(window: window, store: store, runtime: runtime) { self?.restore($0, in: window) }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { _ = self?.archiveIdleTabs(now: Date()) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in _ = self?.archiveIdleTabs(now: Date()) }
    }

    public func deactivate() { timer?.invalidate() }

    var threshold: TimeInterval? {
        switch context.settings.string("archive.after") {
        case "1h": 3600
        case "6h": 6 * 3600
        case "12h": 12 * 3600
        case "24h": 24 * 3600
        case "7d": 7 * 86_400
        default: nil
        }
    }

    /// Archives Today branches whose every tab has been idle longer than the threshold (Arc). A branch
    /// is kept if any tab in it is shown in a window, playing audio, or capturing.
    @discardableResult
    func archiveIdleTabs(now: Date, force: Bool = false) -> Int {
        guard let threshold = force ? (threshold ?? 0) : threshold else { return 0 }
        let tabs = context.tabs
        let visible = Set(context.windows.compactMap(\.selectedTabID))
        var archived = 0
        for space in tabs.spaces {
            for root in space.today {
                let ids = [root] + tabs.descendants(of: root)
                let branch = ids.compactMap { tabs.tab($0) }
                guard !branch.isEmpty, branch.count == ids.count else { continue }  // folders are never archived
                let busy = branch.contains { t in
                    visible.contains(t.id) || context.runtime.isHeldAwake(t.id) || now.timeIntervalSince(t.lastActiveAt) < threshold
                        || t.live?.isPlayingAudio == true || t.live?.isCapturingCamera == true || t.live?.isCapturingMicrophone == true
                }
                guard !busy else { continue }
                store.add(branch.map { ArchivedTab(tab: $0, spaceID: space.id, at: now) })
                context.runtime.close(root, includingDescendants: true)
                archived += branch.count
            }
        }
        store.prune(keepDays: max(1, context.settings.int("archive.keepDays")), now: now)
        return archived
    }

    func restore(_ item: ArchivedTab, in window: BrowserWindowState) {
        store.remove(item.id)
        let space = context.tabs.space(item.spaceID) != nil ? item.spaceID : window.spaceID
        let tab = BrowserTab(url: item.url, title: item.title, faviconURL: item.faviconURL)
        context.tabs.insert(tab, into: .section(space, .today), at: 0)
        context.runtime.select(tab.id, in: window)
    }
}

struct ArchivedTab: Codable, Identifiable, Equatable {
    var id: UUID
    var url: URL?
    var title: String
    var faviconURL: URL?
    var spaceID: UUID
    var archivedAt: Date

    @MainActor
    init(tab: BrowserTab, spaceID: UUID, at date: Date) {
        id = tab.id
        url = tab.live?.url ?? tab.url
        title = tab.displayTitle
        faviconURL = tab.live?.faviconURL ?? tab.faviconURL
        self.spaceID = spaceID
        archivedAt = date
    }
}

@Observable
final class ArchiveStore {
    private(set) var items: [ArchivedTab] = []
    @ObservationIgnored let url: URL

    init(url: URL) {
        self.url = url
        if let data = try? Data(contentsOf: url), let list = try? JSONDecoder().decode([ArchivedTab].self, from: data) { items = list }
    }

    func add(_ list: [ArchivedTab]) {
        items.insert(contentsOf: list, at: 0)
        save()
    }

    func remove(_ id: UUID) {
        items.removeAll { $0.id == id }
        save()
    }

    func clear() {
        items = []
        save()
    }

    func prune(keepDays: Int, now: Date) {
        let before = items.count
        items.removeAll { now.timeIntervalSince($0.archivedAt) > Double(keepDays) * 86_400 }
        if items.count != before { save() }
    }

    private func save() { try? JSONEncoder().encode(items).write(to: url, options: .atomic) }
}

final class ArchiveOmnibox: OmniboxProvider {
    weak var feature: ArchiveFeature?
    init(feature: ArchiveFeature) { self.feature = feature }

    func items(for query: String, in window: BrowserWindowState) -> [OmniboxItem] {
        guard let feature, query.count >= 2 else { return [] }
        return feature.store.items.compactMap { item in
            let score = max(FuzzyMatch.score(query, in: item.title), FuzzyMatch.score(query, in: item.url?.host() ?? ""))
            guard score > 0.5 else { return nil }
            return OmniboxItem(id: "archive:\(item.id)", title: item.title, subtitle: item.url?.host(), icon: .favicon(item.url),
                               kind: "Archived", score: score * 0.6) { [weak feature] w in feature?.restore(item, in: w) }
        }.prefix(3).map { $0 }
    }
}

struct ArchiveRow: View {
    let window: BrowserWindowState
    let store: ArchiveStore
    @State private var hovering = false

    var body: some View {
        if !store.items.isEmpty {
            Button { window.toggle(flag: ArchiveFeature.panelFlag) } label: {
                HStack(spacing: 8) {
                    Image(systemName: "archivebox.fill").font(.system(size: 12)).foregroundStyle(.blue).frame(width: 16)
                    Text("Archive").font(.system(size: 13))
                    Spacer()
                    Text("\(store.items.count)").font(.system(size: 11, design: .rounded)).foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 8)
                .frame(height: 30)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(hovering ? Color.primary.opacity(0.06) : .clear))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
        }
    }
}

struct ArchivePanel: View {
    let window: BrowserWindowState
    let store: ArchiveStore
    let runtime: BrowserRuntime
    @State private var query = ""

    var body: some View {
        if window.flags.contains(ArchiveFeature.panelFlag) {
            ZStack {
                Color.black.opacity(0.12).contentShape(Rectangle()).onTapGesture { window.flags.remove(ArchiveFeature.panelFlag) }
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Archive").font(.title3.bold())
                        Spacer()
                        Button("Clear") { store.clear() }.buttonStyle(.borderless).disabled(store.items.isEmpty)
                        Button { window.flags.remove(ArchiveFeature.panelFlag) } label: { Image(systemName: "xmark") }.buttonStyle(.borderless)
                    }
                    TextField("Search archived tabs", text: $query).textFieldStyle(.roundedBorder)
                    List(store.items.filter { query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) || ($0.url?.absoluteString.localizedCaseInsensitiveContains(query) ?? false) }) { item in
                        HStack {
                            Text(item.title).lineLimit(1)
                            Spacer()
                            Text(item.archivedAt, style: .relative).foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            runtime.feature(ArchiveFeature.self)?.restore(item, in: window)
                            window.flags.remove(ArchiveFeature.panelFlag)
                        }
                    }
                    .listStyle(.inset)
                }
                .padding(20)
                .frame(width: 560, height: 460)
                .overlayKeyboardFocus("archive", in: window)
                .glassSurface(in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .shadow(color: .black.opacity(0.25), radius: 24, y: 10)
            }
        }
    }
}

/// The start page's latest archived tabs (Arc archives idle ones), a click away from coming back.
struct RecentlyArchived: View {
    let window: BrowserWindowState
    let store: ArchiveStore
    let runtime: BrowserRuntime
    let restore: (ArchivedTab) -> Void

    var body: some View {
        let items = store.items.filter { $0.url != nil }.sorted { $0.archivedAt > $1.archivedAt }.prefix(5)
        if !items.isEmpty, !window.isPrivate {
            PageSection("Recently Archived") {
                VStack(spacing: 2) {
                    ForEach(items) { item in
                        PageRow(icon: runtime.favicons.image(for: item.url), title: item.title,
                                detail: item.archivedAt.formatted(.relative(presentation: .named))) { restore(item) }
                    }
                }
                .padding(.horizontal, -10)  // the rows' text on the column's edge, their wash past it
            }
        }
    }
}
