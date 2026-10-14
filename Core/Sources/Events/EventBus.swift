import Foundation

/// Marker for events published on the bus. Events are plain structs declared by whoever owns them
/// (Core for tab/window events, a feature for its own).
public protocol BrowserEvent {}

/// Keeps a subscription alive; cancel it or drop it.
public final class EventSubscription {
    private var cancelAction: (() -> Void)?
    init(_ cancel: @escaping () -> Void) { cancelAction = cancel }
    public func cancel() { cancelAction?(); cancelAction = nil }
}

/// Typed, synchronous, main-thread event bus. Features use it to react to each other without imports.
public final class EventBus {
    private struct Handler {
        let id: Int
        let call: (Any) -> Void
    }

    private var handlers: [ObjectIdentifier: [Handler]] = [:]
    private var nextID = 0

    public init() {}

    public func publish<E: BrowserEvent>(_ event: E) {
        for h in handlers[ObjectIdentifier(E.self)] ?? [] { h.call(event) }
    }

    /// The subscription lives as long as the bus unless cancelled; keep the token only if you need to cancel.
    @discardableResult
    public func subscribe<E: BrowserEvent>(_ type: E.Type, _ handler: @escaping (E) -> Void) -> EventSubscription {
        let key = ObjectIdentifier(E.self)
        nextID += 1
        let id = nextID
        handlers[key, default: []].append(Handler(id: id) { if let e = $0 as? E { handler(e) } })
        return EventSubscription { [weak self] in self?.handlers[key]?.removeAll { $0.id == id } }
    }
}

/// Features expose services to each other through capability protocols declared in Core (or in a
/// shared protocol module). Resolution returns nil when the providing feature is disabled.
public final class CapabilityRegistry {
    private var services: [ObjectIdentifier: Any] = [:]

    public init() {}

    public func provide<T>(_ type: T.Type, _ instance: T) {
        services[ObjectIdentifier(type)] = instance
    }

    public func resolve<T>(_ type: T.Type) -> T? {
        services[ObjectIdentifier(type)] as? T
    }

    private var collections: [ObjectIdentifier: [Any]] = [:]

    /// Adds one member to a many-providers capability (e.g. `OmniboxProvider`).
    public func contribute<T>(_ type: T.Type, _ instance: T) {
        collections[ObjectIdentifier(type), default: []].append(instance)
    }

    public func all<T>(_ type: T.Type) -> [T] {
        (collections[ObjectIdentifier(type)] ?? []).compactMap { $0 as? T }
    }
}
