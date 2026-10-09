/// A typed key. Two keys with the same description have separate identities.
public final class ContextKey<Value: Sendable>: Sendable {
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

    init<Value>(parent: ContextNode, key: ContextKey<Value>, value: Value?) {
        self.parent = parent
        self.key = key // Keep the key alive so its identity cannot be reused.
        keyIdentity = ObjectIdentifier(key)
        self.value = value
        name = ".WithValue(\(key.description))"
    }
}

/// Immutable values and cancellation passed explicitly through an operation.
///
/// | Upstream function or constant | Swift equivalent |
/// | --- | --- |
/// | `BACKGROUND_CONTEXT`, `TODO_CONTEXT` | `Context.background`, `Context.todo` |
/// | `createContextKey` | `ContextKey.init(_:)` |
/// | `withContextValue` | `withValue(_:for:)` |
/// | `withAbortSignal` | `withAbortSignal(_:)` |
/// | `withoutAbortSignal` | `withoutAbortSignal()` |
/// | `withCancel` | `withCancel()` |
/// | `awaitWithContext` | `awaitWithContext(_:_:)` |
public struct Context: Sendable, CustomStringConvertible {
    public static let background = Context(node: ContextNode(name: "[Context BACKGROUND_CONTEXT]"))
    public static let todo = Context(node: ContextNode(name: "[Context TODO_CONTEXT]"))
    private static let abortSignalKey = ContextKey<AbortSignal>("chord.abortSignal")

    private let node: ContextNode

    private init(node: ContextNode) { self.node = node }

    public func value<Value>(_ key: ContextKey<Value>) -> Value? {
        var current: ContextNode? = node
        while let entry = current {
            if entry.keyIdentity == ObjectIdentifier(key) { return entry.value as? Value }
            current = entry.parent
        }
        return nil
    }

    public var abortSignal: AbortSignal? { value(Self.abortSignalKey) }

    /// Adds or replaces a value. A nil value masks the parent's value.
    public func withValue<Value>(_ value: Value?, for key: ContextKey<Value>) -> Context {
        Context(node: ContextNode(parent: node, key: key, value: value))
    }

    /// Derives a context cancelled by either signal. The parent does not change.
    public func withAbortSignal(_ signal: AbortSignal) -> Context {
        let combined = abortSignal.map { AbortSignal.any([$0, signal]) } ?? signal
        return withValue(combined, for: Self.abortSignalKey)
    }

    /// Keeps all values and masks cancellation. Intended for mandatory cleanup only.
    public func withoutAbortSignal() -> Context {
        withValue(nil, for: Self.abortSignalKey)
    }

    public func withCancel() -> CancellableContext {
        let controller = AbortController()
        return CancellableContext(context: withAbortSignal(controller.signal), controller: controller)
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
public struct CancellableContext: Sendable {
    public let context: Context
    private let controller: AbortController

    fileprivate init(context: Context, controller: AbortController) {
        self.context = context
        self.controller = controller
    }

    public func cancel(_ reason: (any Error)? = nil) { controller.abort(reason) }
}
