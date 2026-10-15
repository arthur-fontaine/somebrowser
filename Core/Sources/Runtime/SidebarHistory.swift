import Foundation

/// Arc's ⌘Z for the sidebar: tabs moved (dragged, nested, pinned, made favorites) or closed, undone and redone in order.
/// Features record the changes they make; the Edit menu's Undo runs these when no text field has the keyboard.
public final class SidebarHistory {
    struct Place: Equatable {
        var container: Container
        var index: Int
        var pinnedURL: URL?
    }

    enum Step {
        case moved(NodeID, from: Place, to: Place)
        /// Closed trees, by root, in closing order: undone by reopening them from the store's recently closed list.
        case closed([NodeID], includingDescendants: Bool)
    }

    weak var runtime: BrowserRuntime?
    private var undoSteps: [Step] = []
    private var redoSteps: [Step] = []
    static let limit = 50

    public var canUndo: Bool { !undoSteps.isEmpty }
    public var canRedo: Bool { !redoSteps.isEmpty }

    /// Runs `change` and records where the node went.
    @discardableResult
    public func move<Result>(_ id: NodeID, _ change: () -> Result) -> Result {
        let before = place(of: id)
        let result = change()
        if let before, let after = place(of: id), before != after { push(.moved(id, from: before, to: after)) }
        return result
    }

    /// Closes the tabs (through the runtime: selection follows), recorded so Undo reopens them.
    public func close(_ ids: [NodeID], includingDescendants: Bool) {
        guard let runtime else { return }
        let closing = ids.filter { runtime.tabs.contains($0) }
        guard !closing.isEmpty else { return }
        for id in closing { runtime.close(id, includingDescendants: includingDescendants) }
        push(.closed(closing, includingDescendants: includingDescendants))
    }

    public func undo(in window: BrowserWindowState?) {
        guard let step = undoSteps.popLast() else { return }
        if apply(step, forward: false, in: window) { redoSteps.append(step) } else { invalidate() }
    }

    public func redo(in window: BrowserWindowState?) {
        guard let step = redoSteps.popLast() else { return }
        if apply(step, forward: true, in: window) { undoSteps.append(step) } else { invalidate() }
    }

    private func push(_ step: Step) {
        undoSteps.append(step)
        if undoSteps.count > Self.limit { undoSteps.removeFirst() }
        redoSteps.removeAll()
    }

    /// The tree changed in a way the steps no longer describe (a reopen in between…): start over.
    private func invalidate() {
        undoSteps.removeAll()
        redoSteps.removeAll()
    }

    private func place(of id: NodeID) -> Place? {
        guard let tabs = runtime?.tabs, let container = tabs.container(of: id),
              let index = tabs.nodes(in: container).firstIndex(of: id) else { return nil }
        return Place(container: container, index: index, pinnedURL: tabs.tab(id)?.pinnedURL)
    }

    private func apply(_ step: Step, forward: Bool, in window: BrowserWindowState?) -> Bool {
        guard let runtime else { return false }
        let tabs = runtime.tabs
        switch step {
        case let .moved(id, from, to):
            let target = forward ? to : from
            guard tabs.contains(id), (try? tabs.move(id, to: target.container, at: target.index)) != nil else { return false }
            tabs.tab(id)?.pinnedURL = target.pinnedURL
            return true
        case let .closed(roots, includingDescendants):
            if forward {
                let open = roots.filter(tabs.contains)
                guard !open.isEmpty else { return false }
                for id in open { runtime.close(id, includingDescendants: includingDescendants) }
                return true
            }
            // Only what these closes put on the list, newest first; anything else means the list moved on.
            for root in roots.reversed() {
                guard tabs.recentlyClosed.last?.root == root, tabs.reopenLastClosed() != nil else { return false }
            }
            if roots.count == 1, let window { runtime.select(roots[0], in: window) }
            return true
        }
    }
}
