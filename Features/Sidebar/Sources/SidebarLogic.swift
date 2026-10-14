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

    enum DropZone: Equatable { case before, inside, after }

    /// Top quarter → before, bottom quarter → after, middle → nest (Horse: drop onto a node = child).
    static func zone(atY y: CGFloat, rowHeight: CGFloat, canNest: Bool) -> DropZone {
        if !canNest { return y < rowHeight / 2 ? .before : .after }
        if y < rowHeight * 0.25 { return .before }
        if y > rowHeight * 0.75 { return .after }
        return .inside
    }

    /// Moves `dragged` relative to `target`. Returns false if the move is impossible (cycle, same node).
    @discardableResult
    static func drop(_ dragged: NodeID, on target: NodeID, zone: DropZone, store: TabStore) -> Bool {
        guard dragged != target, store.contains(dragged), store.contains(target) else { return false }
        if store.descendants(of: dragged).contains(target) { return false }
        switch zone {
        case .inside:
            guard (try? store.move(dragged, to: .node(target))) != nil else { return false }
            store.setCollapsed(target, false)
        case .before, .after:
            guard let container = store.container(of: target),
                  let i = store.nodes(in: container).firstIndex(of: target) else { return false }
            // Index in the list as it is now; `move` compensates when the node leaves the same list.
            guard (try? store.move(dragged, to: container, at: zone == .before ? i : i + 1)) != nil else { return false }
        }
        return true
    }

    /// Drop on a section's empty area: append to that section (pinned/today) or favorites.
    @discardableResult
    static func drop(_ dragged: NodeID, into container: Container, store: TabStore) -> Bool {
        if container == .favorites {
            guard store.tab(dragged) != nil else { return false }
            store.favorite(dragged)
            return true
        }
        if case .section(let space, .pinned) = container, let t = store.tab(dragged) {
            t.pinnedURL = t.pinnedURL ?? t.url
            _ = space
        }
        return (try? store.move(dragged, to: container)) != nil
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

    /// Focus mode (Horse ⌘⇧B): only the selected tab's branch (its root and everything below).
    static func focusRows(_ rows: [SidebarRow], selected: NodeID?, store: TabStore) -> [SidebarRow] {
        guard let selected, store.contains(selected) else { return rows }
        let root = store.ancestors(of: selected).last ?? selected
        let keep = Set([root] + store.descendants(of: root))
        return rows.filter { keep.contains($0.id) }
    }
}
