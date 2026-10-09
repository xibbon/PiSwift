/// A typed key. Two keys with the same description have separate identities.
public final class ChordContextKey<Value: Sendable>: Sendable {
    public let description: String

    public init(_ description: String) { self.description = description }
}

private final class ContextNode: Sendable {
    let parent: ContextNode?
    let key: (any Sendable)?
    let keyIdentity: ObjectIdentifier?
    let value: (any Sendable)?
    let name: String

    init(name: String) {
        parent = nil
        key = nil
        keyIdentity = nil
        value = nil
        self.name = name
    }

    init<Value>(parent: ContextNode, key: ChordContextKey<Value>, value: Value?) {
        self.parent = parent
        self.key = key // Keep the key alive so its identity cannot be reused.
        keyIdentity = ObjectIdentifier(key)
        self.value = value
        name = ".WithValue(\(key.description))"
    }
}

/// Immutable values and cancellation passed explicitly through an operation.
/// Port of chord `Context`; named `ChordContext` because PiSwiftAI also has a public `Context`.
///
/// | Upstream function or constant | Swift equivalent |
/// | --- | --- |
/// | `BACKGROUND_CONTEXT`, `TODO_CONTEXT` | `ChordContext.background`, `ChordContext.todo` |
/// | `createContextKey` | `ChordContextKey.init(_:)` |
/// | `withContextValue` | `withValue(_:for:)` |
/// | `withAbortSignal` | `withAbortSignal(_:)` |
/// | `withoutAbortSignal` | `withoutAbortSignal()` |
/// | `withCancel` | `withCancel()` |
/// | `awaitWithContext` | `awaitWithContext(_:_:)` |
public struct ChordContext: Sendable, CustomStringConvertible {
    public static let background = ChordContext(node: ContextNode(name: "[Context BACKGROUND_CONTEXT]"))
    public static let todo = ChordContext(node: ContextNode(name: "[Context TODO_CONTEXT]"))
    private static let abortSignalKey = ChordContextKey<AbortSignal>("chord.abortSignal")

    private let node: ContextNode

    private init(node: ContextNode) { self.node = node }

    public func value<Value>(_ key: ChordContextKey<Value>) -> Value? {
        var current: ContextNode? = node
        while let entry = current {
            if entry.keyIdentity == ObjectIdentifier(key) { return entry.value as? Value }
            current = entry.parent
        }
        return nil
    }

    public var abortSignal: AbortSignal? { value(Self.abortSignalKey) }

    /// Adds or replaces a value. A nil value masks the parent's value.
    public func withValue<Value>(_ value: Value?, for key: ChordContextKey<Value>) -> ChordContext {
        ChordContext(node: ContextNode(parent: node, key: key, value: value))
    }

    /// Derives a context cancelled by either signal. The parent does not change.
    public func withAbortSignal(_ signal: AbortSignal) -> ChordContext {
        let combined = abortSignal.map { AbortSignal.any([$0, signal]) } ?? signal
        return withValue(combined, for: Self.abortSignalKey)
    }

    /// Keeps all values and masks cancellation. Intended for mandatory cleanup only.
    public func withoutAbortSignal() -> ChordContext {
        withValue(nil, for: Self.abortSignalKey)
    }

    public func withCancel() -> CancellableChordContext {
        let controller = AbortController()
        return CancellableChordContext(context: withAbortSignal(controller.signal), controller: controller)
    }

    public var description: String {
        var names: [String] = []
        var current: ContextNode? = node
        while let entry = current {
            names.append(entry.name)
            current = entry.parent
        }
        return names.reversed().joined()
    }
}

/// A child context and its independent cancellation control.
public struct CancellableChordContext: Sendable {
    public let context: ChordContext
    private let controller: AbortController

    fileprivate init(context: ChordContext, controller: AbortController) {
        self.context = context
        self.controller = controller
    }

    public func cancel(_ reason: (any Error)? = nil) { controller.abort(reason) }
}
