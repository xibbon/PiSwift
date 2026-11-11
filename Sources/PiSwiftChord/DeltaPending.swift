import Synchronization

/// The result of draining pending delta operations for one consumer.
public enum PendingTake: Sendable, Equatable {
    /// The operations, in their original order after safe leaf folding.
    case ops([Delta.Op])
    /// The owner must send a root replacement with its current value.
    case replace
}

/// The maximum number of operations held after folding starts.
public let maxPendingOps = 10_000
/// Resource bounds for one received batch and its direct text operations.
public let maxPendingReceivedOps = 100_000
public let maxPendingPathDepth = 4_096
public let maxPendingTextBytes = 16 * 1_024 * 1_024

/// Pending operations for one consumer. A lock makes each call safe across threads.
/// A value type would copy a potentially large queue; one consumer owns this reference.
public final class PendingOps: Sendable {
    private final class Folding {
        var ops: [Delta.Op] = []
        var leaves: [Delta.Path: Int] = [:]
        // Text is joined on take, so repeated small appends do not copy the growing string.
        var suffixes: [Int: [String]] = [:]
        var textBytes = 0
    }

    private enum State {
        case empty
        case batch([Delta.Op])
        case folding(Folding)
        case replace
    }

    private let state = Mutex<State>(.empty)

    /// Creates an empty queue.
    public init() {}

    /// Queues one commit. A leading root replacement discards all older work.
    public func push(_ ops: [Delta.Op]) {
        guard !ops.isEmpty else { return }
        state.withLock { state in
            // A bounded queue can always ask its owner to send the current root.
            if ops.count > maxPendingReceivedOps || ops.contains(where: { $0.path.count > maxPendingPathDepth }) {
                state = .replace
                return
            }
            let incomingTextBytes = ops.reduce(0) { count, op in
                let bytes: Int
                switch op {
                case .append(_, let text), .set(_, .string(let text)): bytes = text.utf8.count
                default: bytes = 0
                }
                return count > maxPendingTextBytes - min(bytes, maxPendingTextBytes) ? maxPendingTextBytes + 1 : count + bytes
            }
            if incomingTextBytes > maxPendingTextBytes {
                state = .replace
                return
            }
            if case .replace = ops[0] {
                state = .batch(ops)
                return
            }
            switch state {
            case .empty:
                state = .batch(ops)
            case .batch(let first):
                let folding = Folding()
                if fold(first, into: folding) && folding.textBytes + incomingTextBytes <= maxPendingTextBytes && fold(ops, into: folding) {
                    state = .folding(folding)
                } else {
                    state = .replace
                }
            case .folding(let folding):
                state = folding.textBytes + incomingTextBytes <= maxPendingTextBytes && fold(ops, into: folding) ? .folding(folding) : .replace
            case .replace:
                break
            }
        }
    }

    /// Number of pending operations; one denotes a pending root replacement.
    public var size: Int {
        state.withLock { state in
            switch state {
            case .empty: 0
            case .replace: 1
            case .batch(let ops): ops.count
            case .folding(let folding): folding.ops.count
            }
        }
    }

    /// Drains the queue and starts a new empty period.
    public func take() -> PendingTake {
        state.withLock { state in
            let old = state
            state = .empty
            switch old {
            case .empty: return .ops([])
            case .replace: return .replace
            case .batch(let ops): return .ops(ops)
            case .folding(let folding):
                for (index, suffix) in folding.suffixes {
                    let joined = suffix.joined()
                    switch folding.ops[index] {
                    case .append(let path, let text): folding.ops[index] = .append(path, text + joined)
                    case .set(let path, .string(let text)): folding.ops[index] = .set(path, .string(text + joined))
                    default: break
                    }
                }
                return .ops(folding.ops)
            }
        }
    }

    /// Folds one batch. False means the owner must replace the root.
    private func fold(_ ops: [Delta.Op], into folding: Folding) -> Bool {
        for op in ops {
            switch op {
            case .replace:
                folding.ops.removeAll()
                folding.leaves.removeAll()
                folding.suffixes.removeAll()
                folding.textBytes = 0
            case .append(let path, let text):
                if mergeLeaf(op, path: path, into: folding) {
                    folding.textBytes += text.utf8.count
                    continue
                }
            case .set(let path, let value):
                if isPrimitive(value) {
                    if mergeLeaf(op, path: path, into: folding) {
                        if case .string(let text) = value { folding.textBytes += text.utf8.count }
                        continue
                    }
                } else if !folding.leaves.isEmpty {
                    folding.leaves.removeAll()
                }
            default:
                if !folding.leaves.isEmpty { folding.leaves.removeAll() }
            }
            folding.ops.append(op)
            switch op {
            case .append(_, let text), .set(_, .string(let text)): folding.textBytes += text.utf8.count
            default: break
            }
            if folding.ops.count > maxPendingOps { return false }
        }
        return true
    }

    private func isPrimitive(_ value: JSONValue) -> Bool {
        switch value { case .array, .object: false; default: true }
    }

    /// Merges a primitive leaf write at its last indexed position.
    private func mergeLeaf(_ op: Delta.Op, path: Delta.Path, into folding: Folding) -> Bool {
        let key = pathKey(path)
        if let at = folding.leaves[key], merge(folding.ops[at], op, at: at, into: folding) {
            return true
        }
        folding.leaves[key] = folding.ops.count
        return false
    }

    /// A Swift path is already an injective, code-unit-aware dictionary key.
    private func pathKey(_ path: Delta.Path) -> Delta.Path { path }

    /// A new set replaces a leaf; an append extends an append or string set.
    private func merge(_ previous: Delta.Op, _ next: Delta.Op, at: Int, into folding: Folding) -> Bool {
        switch next {
        case .set:
            folding.ops[at] = next
            folding.suffixes.removeValue(forKey: at)
            return true
        case .append(_, let text):
            switch previous {
            case .append, .set(_, .string):
                folding.suffixes[at, default: []].append(text)
                return true
            default: return false
            }
        default: return false
        }
    }
}

extension Delta {
    /// The pending queue available through the delta namespace.
    public typealias PendingOps = PiSwiftChord.PendingOps
    /// The result of draining the pending queue.
    public typealias PendingTake = PiSwiftChord.PendingTake
    /// The folded operation limit.
    public static let maxPendingOps = PiSwiftChord.maxPendingOps
}

