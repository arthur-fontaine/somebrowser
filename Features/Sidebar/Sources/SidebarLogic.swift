import BrowserCore
import CoreGraphics
import Foundation

/// Layout math and tree edits behind the sidebar, kept free of SwiftUI so it is unit-tested.
enum SidebarLogic {
    /// Radian's "instant hitbox": the hovered row comes from the pointer and the *target* layout,
    /// so the highlight is right immediately even while rows are still springing into place.
    static func row(at y: CGFloat, rows: [SidebarRow], rowHeight: CGFloat, spacing: CGFloat) -> SidebarRow? {
        guard y >= 0 else { return nil }
        let pitch = rowHeight + spacing
        let index = Int(y / pitch)
        guard index < rows.count, y - CGFloat(index) * pitch <= rowHeight else { return nil }
        return rows[index]
    }

    /// A child's icon sits under its parent's title.
    static let indent = Design.Size.favicon + Design.Grid.iconToText

    /// Where a dragged node would land.
    struct DropPlacement: Equatable {
        enum Mark: Equatable {
            /// A line in the gap above row `gap` (`rows.count`: below the last), starting at `depth`'s icon.
            case line(gap: Int, depth: Int)
            /// The row is outlined: the node becomes its last child.
            case into(NodeID)
        }
        let mark: Mark
        let container: Container
        /// Nil: at the end.
        let index: Int?
    }

    /// The middle half of a row nests into it (Horse: drop onto a node = child); elsewhere the nearest gap, at the
    /// depth the pointer is over (Finder's outlines): under the end of a branch, moving left lands after an ancestor.
    /// Nil where the nodes can't go (into one of them) or wouldn't move.
    static func placement(at point: CGPoint, rows: [SidebarRow], in list: Container, dragged: [NodeID],
                          rowHeight: CGFloat, spacing: CGFloat, store: TabStore) -> DropPlacement? {
        guard !rows.isEmpty else { return DropPlacement(mark: .line(gap: 0, depth: 0), container: list, index: 0) }
        let excluded = Set(dragged + dragged.flatMap(store.descendants))
        let pitch = rowHeight + spacing
        let r = max(0, min(rows.count - 1, Int((point.y / pitch).rounded(.down))))
        let y = point.y - CGFloat(r) * pitch
        if y > rowHeight * 0.25, y < rowHeight * 0.75, !excluded.contains(rows[r].id) {
            return DropPlacement(mark: .into(rows[r].id), container: .node(rows[r].id), index: nil)
        }
        let gap = y < rowHeight / 2 ? r : r + 1
        let above = gap > 0 ? rows[gap - 1] : nil
        let below = gap < rows.count ? rows[gap] : nil
        let depth: Int
        let container: Container
        let index: Int
        if let above, let below, below.depth > above.depth {
            // Between a parent and its first child: only as that first child.
            (depth, container, index) = (below.depth, .node(above.id), 0)
        } else if let above {
            let pointed = Int(((point.x - Design.Grid.iconInset) / indent).rounded(.down))
            depth = max(below?.depth ?? 0, min(above.depth, pointed))
            // After the ancestor at that depth (the row above itself at its own).
            var sibling = above.id
            for _ in depth..<above.depth { sibling = store.parent(of: sibling) ?? sibling }
            guard let c = store.container(of: sibling), let i = store.nodes(in: c).firstIndex(of: sibling) else { return nil }
            (container, index) = (c, i + 1)
        } else {
            (depth, container, index) = (0, list, 0)
        }
        if case .node(let parent) = container, excluded.contains(parent) { return nil }
        // Already together there, beside the gap.
        let moving = roots(dragged, store: store), nodes = store.nodes(in: container)
        if let first = moving.first, let i = nodes.firstIndex(of: first), nodes[i...].starts(with: moving),
           (i...i + moving.count).contains(index) { return nil }
        return DropPlacement(mark: .line(gap: gap, depth: depth), container: container, index: index)
    }

    /// Over the New Tab row: with nothing pinned its top half pins (where the section would begin); otherwise it begins
    /// Today (pinned tabs end at the divider above it).
    static func newTabPlacement(atY y: CGFloat, rowHeight: CGFloat, space: UUID, dragged: [NodeID], store: TabStore) -> DropPlacement? {
        let pinned = Container.section(space, .pinned), today = Container.section(space, .today)
        if y < rowHeight / 2, store.nodes(in: pinned).isEmpty {
            return DropPlacement(mark: .line(gap: 0, depth: 0), container: pinned, index: nil)
        }
        if store.nodes(in: today).starts(with: roots(dragged, store: store)) { return nil }
        return DropPlacement(mark: .line(gap: 1, depth: 0), container: today, index: 0)
    }

    /// Below a list's last row: its end, at the top level.
    static func endPlacement(rows: [SidebarRow], in list: Container, dragged: [NodeID], store: TabStore) -> DropPlacement? {
        if store.nodes(in: list).reversed().starts(with: roots(dragged, store: store).reversed()) { return nil }
        return DropPlacement(mark: .line(gap: rows.count, depth: 0), container: list, index: nil)
    }

    /// Wraps one node's move, for Undo to record it (`SidebarHistory.move`).
    typealias Record = (NodeID, () -> Bool) -> Bool

    /// Moves the dragged nodes where `placement` says, one after the other in the order given (picked children go
    /// along in their parent's branch). False if none can go there.
    @discardableResult
    static func drop(_ dragged: [NodeID], at placement: DropPlacement, store: TabStore, record: Record = { $1() }) -> Bool {
        var previous: NodeID?
        for id in roots(dragged, store: store) {
            // Each right after the one before: an index into the list would shift as earlier ones leave it.
            var (container, index) = (placement.container, placement.index)
            if let previous, let c = store.container(of: previous), let i = store.nodes(in: c).firstIndex(of: previous) { (container, index) = (c, i + 1) }
            guard record(id, { (try? store.move(id, to: container, at: index)) != nil }) else { continue }
            settlePin(id, store: store)
            previous = id
        }
        if previous != nil, case .into(let target) = placement.mark { store.setCollapsed(target, false) }
        return previous != nil
    }

    /// Drop on a section's empty area: append to that section (pinned/today) or favorites (every tab dragged, as the
    /// row menu adds them).
    @discardableResult
    static func drop(_ dragged: [NodeID], into container: Container, store: TabStore, record: Record = { $1() }) -> Bool {
        if container == .favorites {
            let tabs = dragged.filter { store.tab($0) != nil }
            for id in tabs { _ = record(id) { store.favorite(id); return true } }
            return !tabs.isEmpty
        }
        var moved = false
        for id in roots(dragged, store: store) where record(id, { (try? store.move(id, to: container)) != nil }) {
            settlePin(id, store: store)
            moved = true
        }
        return moved
    }

    /// A tab kept in pinned or favorites remembers the page it was kept at (Arc's reset); one moved to Today forgets it,
    /// as unpinning does.
    private static func settlePin(_ id: NodeID, store: TabStore) {
        guard let t = store.tab(id) else { return }
        t.pinnedURL = store.isPinned(id) || store.isFavorite(id) ? t.pinnedURL ?? t.url : nil
    }

    /// Horse: a branch exported as a nested Markdown list of links.
    static func markdown(for root: NodeID, store: TabStore) -> String {
        var lines: [String] = []
        func walk(_ id: NodeID, depth: Int) {
            let indent = String(repeating: "  ", count: depth)
            if let t = store.tab(id) {
                let title = t.displayTitle.replacingOccurrences(of: "]", with: "\\]")
                if let url = t.live?.url ?? t.url { lines.append("\(indent)- [\(title)](\(url.absoluteString))") }
                else { lines.append("\(indent)- \(title)") }
            } else if let f = store.folder(id) {
                lines.append("\(indent)- **\(f.name)**")
            }
            for c in store.children(of: id) { walk(c, depth: depth + 1) }
        }
        walk(root, depth: 0)
        return lines.joined(separator: "\n")
    }

    /// ⇧-click (Finder): the tabs from the one shown to the clicked one, both included, in the order shown. Folders
    /// are left out.
    static func range(from anchor: NodeID?, to id: NodeID, in rows: [SidebarRow], store: TabStore) -> [NodeID] {
        let ids = rows.map(\.id)
        guard let j = ids.firstIndex(of: id) else { return [] }
        let i = anchor.flatMap { ids.firstIndex(of: $0) } ?? j
        return ids[min(i, j)...max(i, j)].filter { store.tab($0) != nil }
    }

    /// The tabs not inside another picked one's branch: moving a branch takes its picked children along.
    static func roots(_ ids: [NodeID], store: TabStore) -> [NodeID] {
        let picked = Set(ids)
        return ids.filter { !store.ancestors(of: $0).contains(where: picked.contains) }
    }

    /// Focus mode (Horse ⌘⇧B): only the selected tab's branch (its root and everything below).
    static func focusRows(_ rows: [SidebarRow], selected: NodeID?, store: TabStore) -> [SidebarRow] {
        guard let selected, store.contains(selected) else { return rows }
        let root = store.ancestors(of: selected).last ?? selected
        let keep = Set([root] + store.descendants(of: root))
        return rows.filter { keep.contains($0.id) }
    }
}
