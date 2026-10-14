import Foundation
import Observation

/// Where a node lives.
public enum Container: Hashable, Codable, Sendable {
    /// Global favorites grid (flat, tabs only).
    case favorites
    /// Root list of a space section.
    case section(UUID, SidebarSection)
    /// Children of a tab (Horse tree) or folder.
    case node(NodeID)
}

/// One visible line of the sidebar tree.
public struct SidebarRow: Identifiable, Equatable, Sendable {
    public let id: NodeID
    public let depth: Int
    public let isFolder: Bool
    public let hasChildren: Bool
    public let isCollapsed: Bool
}

/// A closed subtree kept for ⌘⇧T (Horse restores "the whole Trail with every page inside it").
public struct ClosedItem: Sendable {
    public struct TabData: Codable, Sendable {
        var id: NodeID
        var url: URL?
        var title: String
        var faviconURL: URL?
        var customTitle: String?
        var pinnedURL: URL?
        var restorationData: Data?
    }
    public var tabs: [TabData]
    /// parent → children inside the subtree, in order.
    public var structure: [NodeID: [NodeID]]
    public var root: NodeID
    public var container: Container
    public var index: Int
    public var closedAt: Date
    /// Children that were promoted when the root closed; re-nested on reopen if still in place.
    public var promotedChildren: [NodeID] = []
}

/// The whole sidebar model: spaces, sections, folders, favorites and the tab tree.
/// Structural reads go through `structureVersion` so views re-render only when the tree changes, while
/// each row observes its own `Tab` for title/favicon updates.
@Observable
public final class TabStore {
    public private(set) var spaces: [Space] = []
    public private(set) var favorites: [NodeID] = []
    /// Bumped on any structural change (insert, move, remove, collapse).
    public private(set) var structureVersion = 0
    public private(set) var recentlyClosed: [ClosedItem] = []

    @ObservationIgnored private var tabsByID: [NodeID: Tab] = [:]
    @ObservationIgnored private var foldersByID: [NodeID: Folder] = [:]
    @ObservationIgnored private var childrenOf: [NodeID: [NodeID]] = [:]
    @ObservationIgnored private var containerOf: [NodeID: Container] = [:]
    @ObservationIgnored private var rowCache: [Container: (version: Int, rows: [SidebarRow])] = [:]

    /// Called after tabs leave the model (close, space removal) so the runtime can release engine pages.
    @ObservationIgnored public var onTabsRemoved: (([Tab]) -> Void)?
    /// Called after any structural change (persistence debounce).
    @ObservationIgnored public var onChange: (() -> Void)?

    public static let maxRecentlyClosed = 50

    public init() {}

    // MARK: Lookup

    public func tab(_ id: NodeID) -> Tab? { tabsByID[id] }
    public func folder(_ id: NodeID) -> Folder? { foldersByID[id] }
    public func contains(_ id: NodeID) -> Bool { tabsByID[id] != nil || foldersByID[id] != nil }
    public var allTabs: [Tab] { Array(tabsByID.values) }
    public var tabCount: Int { tabsByID.count }

    public func space(_ id: UUID) -> Space? { spaces.first { $0.id == id } }

    public func children(of id: NodeID) -> [NodeID] {
        _ = structureVersion
        return childrenOf[id] ?? []
    }

    public func container(of id: NodeID) -> Container? { containerOf[id] }

    public func parent(of id: NodeID) -> NodeID? {
        if case .node(let p) = containerOf[id] { return p }
        return nil
    }

    /// Top-level container (favorites or a space section) of any node.
    public func rootContainer(of id: NodeID) -> Container? {
        var current = id
        while case .node(let p)? = containerOf[current] { current = p }
        return containerOf[current]
    }

    public func spaceID(of id: NodeID) -> UUID? {
        if case .section(let s, _)? = rootContainer(of: id) { return s }
        return nil
    }

    public func isFavorite(_ id: NodeID) -> Bool { containerOf[id] == .favorites }
    public func isPinned(_ id: NodeID) -> Bool {
        if case .section(_, .pinned)? = rootContainer(of: id) { return true }
        return false
    }

    public func nodes(in container: Container) -> [NodeID] {
        _ = structureVersion
        switch container {
        case .favorites: return favorites
        case .section(let s, let section): return space(s)?.roots(section) ?? []
        case .node(let id): return childrenOf[id] ?? []
        }
    }

    public func ancestors(of id: NodeID) -> [NodeID] {
        var result: [NodeID] = []
        var current = id
        while let p = parent(of: current) { result.append(p); current = p }
        return result
    }

    public func descendants(of id: NodeID) -> [NodeID] {
        var result: [NodeID] = []
        func walk(_ n: NodeID) { for c in childrenOf[n] ?? [] { result.append(c); walk(c) } }
        walk(id)
        return result
    }

    public func depth(of id: NodeID) -> Int { ancestors(of: id).count }

    public func isCollapsed(_ id: NodeID) -> Bool { tabsByID[id]?.isCollapsed ?? foldersByID[id]?.isCollapsed ?? false }

    /// Tabs whose URL matches (Horse dedup), optionally limited to one space.
    public func tabs(matching url: URL, in space: UUID? = nil) -> [Tab] {
        let key = URLNormalizer.key(for: url)
        return tabsByID.values.filter { t in
            guard let u = t.url, URLNormalizer.key(for: u) == key else { return false }
            return space == nil || spaceID(of: t.id) == space || isFavorite(t.id)
        }
    }

    // MARK: Rows

    /// Visible rows of a container, depth-first, skipping collapsed subtrees. Cached per structure version.
    public func rows(in container: Container) -> [SidebarRow] {
        let version = structureVersion
        if let cached = rowCache[container], cached.version == version { return cached.rows }
        var rows: [SidebarRow] = []
        func walk(_ ids: [NodeID], depth: Int) {
            for id in ids {
                let kids = childrenOf[id] ?? []
                let collapsed = isCollapsed(id)
                rows.append(SidebarRow(id: id, depth: depth, isFolder: foldersByID[id] != nil, hasChildren: !kids.isEmpty, isCollapsed: collapsed))
                if !collapsed { walk(kids, depth: depth + 1) }
            }
        }
        walk(nodes(in: container), depth: 0)
        rowCache[container] = (version, rows)
        return rows
    }

    /// Every tab of a space in visual order (pinned first), regardless of collapse — keyboard ⌘1…9, Ctrl-Tab.
    public func orderedTabs(in space: UUID, includeFavorites: Bool = false) -> [Tab] {
        var ids: [NodeID] = includeFavorites ? favorites : []
        for section in SidebarSection.allCases {
            for root in nodes(in: .section(space, section)) { ids.append(root); ids += descendants(of: root) }
        }
        return ids.compactMap { tabsByID[$0] }
    }

    // MARK: Spaces

    @discardableResult
    public func addSpace(name: String, icon: String = "circle.fill", theme: SpaceTheme? = nil, at index: Int? = nil) -> Space {
        let s = Space(name: name, icon: icon, theme: theme ?? SpaceTheme.defaults[spaces.count % SpaceTheme.defaults.count])
        spaces.insert(s, at: min(index ?? spaces.count, spaces.count))
        changed()
        return s
    }

    public func removeSpace(_ id: UUID) {
        guard let s = space(id), spaces.count > 1 else { return }
        var removed: [Tab] = []
        for root in s.pinned + s.today { removed += detachSubtree(root) }
        spaces.removeAll { $0.id == id }
        changed()
        onTabsRemoved?(removed)
    }

    public func moveSpace(_ id: UUID, to index: Int) {
        guard let i = spaces.firstIndex(where: { $0.id == id }) else { return }
        let s = spaces.remove(at: i)
        spaces.insert(s, at: max(0, min(index, spaces.count)))
        changed()
    }

    // MARK: Insertion

    /// Inserts a new tab. `index` nil appends (children) or prepends (Today: newest on top, like Arc/Horse).
    @discardableResult
    public func insert(_ tab: Tab, into container: Container, at index: Int? = nil) -> Tab {
        tabsByID[tab.id] = tab
        place(tab.id, into: container, at: index)
        changed()
        return tab
    }

    @discardableResult
    public func insertFolder(_ folder: Folder, into container: Container, at index: Int? = nil) -> Folder {
        precondition(container != .favorites, "favorites hold tabs only")
        foldersByID[folder.id] = folder
        place(folder.id, into: container, at: index)
        changed()
        return folder
    }

    /// Opens `tab` as a child of `parent` (Horse: links become children). Appended after existing children.
    @discardableResult
    public func insertChild(_ tab: Tab, of parent: NodeID) -> Tab {
        guard contains(parent), containerOf[parent] != .favorites else {
            // Favorites are flat: children of a favorite go to the top of the favorite's space today list.
            return insert(tab, into: defaultTodayContainer(), at: 0)
        }
        return insert(tab, into: .node(parent), at: nil)
    }

    /// Inserts right after `sibling` in the same container (Horse sidetrail / Arc "open below").
    @discardableResult
    public func insert(_ tab: Tab, after sibling: NodeID) -> Tab {
        guard let c = containerOf[sibling], let i = nodes(in: c).firstIndex(of: sibling) else {
            return insert(tab, into: defaultTodayContainer(), at: 0)
        }
        return insert(tab, into: c, at: i + 1)
    }

    private func defaultTodayContainer() -> Container {
        if spaces.isEmpty { addSpace(name: "Personal") }
        return .section(spaces[0].id, .today)
    }

    private func place(_ id: NodeID, into container: Container, at index: Int?) {
        var list = rawList(container)
        let defaultIndex: Int
        if case .section(_, .today) = container { defaultIndex = 0 } else { defaultIndex = list.count }
        list.insert(id, at: max(0, min(index ?? defaultIndex, list.count)))
        setRawList(container, list)
        containerOf[id] = container
    }

    private func rawList(_ c: Container) -> [NodeID] {
        switch c {
        case .favorites: return favorites
        case .section(let s, let section): return space(s)?.roots(section) ?? []
        case .node(let id): return childrenOf[id] ?? []
        }
    }

    private func setRawList(_ c: Container, _ list: [NodeID]) {
        switch c {
        case .favorites: favorites = list
        case .section(let s, let section):
            guard let sp = space(s) else { return }
            if section == .pinned { sp.pinned = list } else { sp.today = list }
        case .node(let id): childrenOf[id] = list.isEmpty ? nil : list
        }
    }

    private func unplace(_ id: NodeID) -> (Container, Int)? {
        guard let c = containerOf[id] else { return nil }
        var list = rawList(c)
        guard let i = list.firstIndex(of: id) else { return nil }
        list.remove(at: i)
        setRawList(c, list)
        containerOf[id] = nil
        return (c, i)
    }

    // MARK: Moving

    public enum MoveError: Error { case unknownNode, cycle, invalidTarget }

    /// Moves a node (with its subtree) into `container` at `index` (nil = end).
    public func move(_ id: NodeID, to container: Container, at index: Int? = nil) throws {
        guard contains(id), containerOf[id] != nil else { throw MoveError.unknownNode }
        if case .node(let target) = container {
            if target == id || descendants(of: id).contains(target) { throw MoveError.cycle }
            guard contains(target) else { throw MoveError.invalidTarget }
        }
        if container == .favorites {
            guard tabsByID[id] != nil else { throw MoveError.invalidTarget }
            promoteChildren(of: id)
        }
        var targetIndex = index
        if let (old, oldIndex) = unplace(id), old == container, let t = targetIndex, t > oldIndex { targetIndex = t - 1 }
        var list = rawList(container)
        list.insert(id, at: max(0, min(targetIndex ?? list.count, list.count)))
        setRawList(container, list)
        containerOf[id] = container
        changed()
    }

    /// Makes the node the last child of its previous sibling (⌘⌥⇧→).
    public func indent(_ id: NodeID) {
        guard let c = containerOf[id], c != .favorites else { return }
        let list = rawList(c)
        guard let i = list.firstIndex(of: id), i > 0 else { return }
        try? move(id, to: .node(list[i - 1]))
    }

    /// Moves the node right after its parent (⌘⌥⇧←).
    public func outdent(_ id: NodeID) {
        guard let p = parent(of: id), let pc = containerOf[p], let pi = rawList(pc).firstIndex(of: p) else { return }
        try? move(id, to: pc, at: pi + 1)
    }

    /// Swaps with the previous (-1) or next (+1) sibling (⌘⌥⇧↑/↓).
    public func shift(_ id: NodeID, by delta: Int) {
        guard let c = containerOf[id] else { return }
        let list = rawList(c)
        guard let i = list.firstIndex(of: id) else { return }
        let j = i + delta
        guard j >= 0, j < list.count else { return }
        try? move(id, to: c, at: delta > 0 ? j + 1 : j)
    }

    public func setCollapsed(_ id: NodeID, _ collapsed: Bool) {
        if let t = tabsByID[id] { t.isCollapsed = collapsed } else if let f = foldersByID[id] { f.isCollapsed = collapsed } else { return }
        changed()
    }

    /// Collapses every node except the ancestors of `id` (Horse ⌥L).
    public func collapseAll(except id: NodeID?) {
        let keep = Set(id.map { ancestors(of: $0) } ?? [])
        for (nid, kids) in childrenOf where !kids.isEmpty {
            let c = !keep.contains(nid)
            if let t = tabsByID[nid] { t.isCollapsed = c } else { foldersByID[nid]?.isCollapsed = c }
        }
        changed()
    }

    // MARK: Pin / favorite

    public func pin(_ id: NodeID, in spaceID: UUID) {
        guard let t = tabsByID[id] else { return }
        t.pinnedURL = t.pinnedURL ?? t.url
        try? move(id, to: .section(spaceID, .pinned))
    }

    public func unpin(_ id: NodeID, in spaceID: UUID) {
        tabsByID[id]?.pinnedURL = nil
        try? move(id, to: .section(spaceID, .today), at: 0)
    }

    public func favorite(_ id: NodeID) {
        guard let t = tabsByID[id] else { return }
        t.pinnedURL = t.pinnedURL ?? t.url
        try? move(id, to: .favorites)
    }

    // MARK: Closing

    /// Removes a node. Children are promoted into its place (Horse ⌘W) unless `includingDescendants`
    /// (Horse ⌘⇧W) or the node is a collapsed tab (Horse follows the visible hierarchy). Returns closed tabs.
    @discardableResult
    public func close(_ id: NodeID, includingDescendants: Bool = false) -> [Tab] {
        guard contains(id), let (c, i) = position(of: id) else { return [] }
        let subtree = includingDescendants || isCollapsed(id) || foldersByID[id] != nil
        let promoted = subtree ? [] : (childrenOf[id] ?? [])
        if !subtree { promoteChildren(of: id) }
        record(root: id, container: c, index: i, promoted: promoted)
        let removed = detachSubtree(id)
        changed()
        onTabsRemoved?(removed)
        return removed
    }

    /// Reopens the most recently closed subtree at its old position (clamped). Returns the restored root tab.
    @discardableResult
    public func reopenLastClosed() -> Tab? {
        while let item = recentlyClosed.popLast() {
            var container = item.container
            switch container {
            case .node(let p) where !contains(p): container = defaultTodayContainer()
            case .section(let s, _) where space(s) == nil: container = defaultTodayContainer()
            default: break
            }
            let byID = Dictionary(item.tabs.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            func make(_ id: NodeID) -> Tab? {
                guard let d = byID[id], !contains(id) else { return nil }
                let t = Tab(id: id, url: d.url, title: d.title, faviconURL: d.faviconURL)
                t.customTitle = d.customTitle
                t.pinnedURL = d.pinnedURL
                t.restorationData = d.restorationData
                return t
            }
            guard let root = make(item.root) else { continue }
            tabsByID[root.id] = root
            place(root.id, into: container, at: item.index)
            func restoreChildren(_ parent: NodeID) {
                for c in item.structure[parent] ?? [] {
                    guard let t = make(c) else { continue }
                    tabsByID[t.id] = t
                    place(t.id, into: .node(parent), at: nil)
                    restoreChildren(c)
                }
            }
            restoreChildren(root.id)
            for child in item.promotedChildren where containerOf[child] == container {
                _ = unplace(child)
                place(child, into: .node(root.id), at: nil)
            }
            changed()
            return root
        }
        return nil
    }

    private func position(of id: NodeID) -> (Container, Int)? {
        guard let c = containerOf[id], let i = rawList(c).firstIndex(of: id) else { return nil }
        return (c, i)
    }

    private func promoteChildren(of id: NodeID) {
        guard let kids = childrenOf[id], !kids.isEmpty, let (c, i) = position(of: id) else { return }
        childrenOf[id] = nil
        var list = rawList(c)
        list.insert(contentsOf: kids, at: i + 1)
        setRawList(c, list)
        for k in kids { containerOf[k] = c }
    }

    private func record(root: NodeID, container: Container, index: Int, promoted: [NodeID] = []) {
        guard tabsByID[root] != nil else { return }
        let ids = [root] + descendants(of: root)
        let tabs = ids.compactMap { id -> ClosedItem.TabData? in
            guard let t = tabsByID[id] else { return nil }
            return .init(id: t.id, url: t.url, title: t.title, faviconURL: t.faviconURL, customTitle: t.customTitle,
                         pinnedURL: t.pinnedURL, restorationData: t.engineTab?.restorationData() ?? t.restorationData)
        }
        var structure: [NodeID: [NodeID]] = [:]
        for id in ids { if let k = childrenOf[id] { structure[id] = k } }
        recentlyClosed.append(ClosedItem(tabs: tabs, structure: structure, root: root, container: container, index: index,
                                         closedAt: Date(), promotedChildren: promoted))
        if recentlyClosed.count > Self.maxRecentlyClosed { recentlyClosed.removeFirst() }
    }

    /// Removes a node and its descendants from every index; returns the removed tabs.
    private func detachSubtree(_ id: NodeID) -> [Tab] {
        let ids = [id] + descendants(of: id)
        _ = unplace(id)
        var removed: [Tab] = []
        for n in ids {
            if let t = tabsByID.removeValue(forKey: n) { removed.append(t) }
            foldersByID.removeValue(forKey: n)
            childrenOf.removeValue(forKey: n)
            containerOf.removeValue(forKey: n)
        }
        return removed
    }

    private func changed() {
        structureVersion &+= 1
        onChange?()
    }

    // MARK: Persistence

    public struct Snapshot: Codable, Sendable {
        public struct SpaceRecord: Codable, Sendable {
            var id: UUID, name: String, icon: String, theme: SpaceTheme, pinned: [NodeID], today: [NodeID]
        }
        public struct TabRecord: Codable, Sendable {
            var id: NodeID, url: URL?, title: String, faviconURL: URL?, customTitle: String?, pinnedURL: URL?
            var createdAt: Date, lastActiveAt: Date, isCollapsed: Bool, opensLinksInPlace: Bool, restorationData: Data?
        }
        public struct FolderRecord: Codable, Sendable {
            var id: NodeID, name: String, icon: String?, isCollapsed: Bool
        }
        public var version = 1
        public var spaces: [SpaceRecord]
        public var favorites: [NodeID]
        public var tabs: [TabRecord]
        public var folders: [FolderRecord]
        public var children: [NodeID: [NodeID]]
    }

    public func snapshot() -> Snapshot {
        Snapshot(
            spaces: spaces.map { .init(id: $0.id, name: $0.name, icon: $0.icon, theme: $0.theme, pinned: $0.pinned, today: $0.today) },
            favorites: favorites,
            tabs: tabsByID.values.filter { !$0.isPrivate }.map {
                .init(id: $0.id, url: $0.url, title: $0.title, faviconURL: $0.faviconURL, customTitle: $0.customTitle,
                      pinnedURL: $0.pinnedURL, createdAt: $0.createdAt, lastActiveAt: $0.lastActiveAt, isCollapsed: $0.isCollapsed,
                      opensLinksInPlace: $0.opensLinksInPlace, restorationData: $0.engineTab?.restorationData() ?? $0.restorationData)
            },
            folders: foldersByID.values.map { .init(id: $0.id, name: $0.name, icon: $0.icon, isCollapsed: $0.isCollapsed) },
            children: childrenOf
        )
    }

    public func restore(_ s: Snapshot) {
        tabsByID = [:]; foldersByID = [:]; childrenOf = [:]; containerOf = [:]
        for t in s.tabs {
            let tab = Tab(id: t.id, url: t.url, title: t.title, faviconURL: t.faviconURL, createdAt: t.createdAt)
            tab.customTitle = t.customTitle
            tab.pinnedURL = t.pinnedURL
            tab.lastActiveAt = t.lastActiveAt
            tab.isCollapsed = t.isCollapsed
            tab.opensLinksInPlace = t.opensLinksInPlace
            tab.restorationData = t.restorationData
            tabsByID[t.id] = tab
        }
        for f in s.folders { foldersByID[f.id] = Folder(id: f.id, name: f.name, icon: f.icon, isCollapsed: f.isCollapsed) }
        let known = { (id: NodeID) in self.tabsByID[id] != nil || self.foldersByID[id] != nil }
        spaces = s.spaces.map { r in
            Space(id: r.id, name: r.name, icon: r.icon, theme: r.theme, pinned: r.pinned.filter(known), today: r.today.filter(known))
        }
        favorites = s.favorites.filter { tabsByID[$0] != nil }
        for sp in spaces {
            for id in sp.pinned { containerOf[id] = .section(sp.id, .pinned) }
            for id in sp.today { containerOf[id] = .section(sp.id, .today) }
        }
        for id in favorites { containerOf[id] = .favorites }
        for (p, kids) in s.children where known(p) {
            let valid = kids.filter(known)
            if !valid.isEmpty { childrenOf[p] = valid }
            for k in valid { containerOf[k] = .node(p) }
        }
        // Drop orphans (corrupt snapshot) rather than crash.
        for id in Array(tabsByID.keys) where containerOf[id] == nil { tabsByID.removeValue(forKey: id) }
        for id in Array(foldersByID.keys) where containerOf[id] == nil { foldersByID.removeValue(forKey: id) }
        if spaces.isEmpty { addSpace(name: "Personal") }
        changed()
    }
}
