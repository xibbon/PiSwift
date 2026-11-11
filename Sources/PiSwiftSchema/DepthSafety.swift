// Swift-only depth guards for untrusted schema and JSON values.
import Foundation
import Synchronization

// A JSON container adds one level. Limits are inclusive.
let schemaMaximumValueDepth = 512
let schemaMaximumSchemaDepth = 128
// Debug 512 KB probes fail first at schema depth 60 and coercion depth 84.
// Twenty-four keeps over twice the measured margin before a worker is used.
let schemaLargeStackThreshold = 24
let schemaLargeStackBytes = 32 * 1024 * 1024

let schemaValueTooDeepIssue = SchemaIssue(path: "", keyword: "schema", message: "value is nested too deeply")

private enum SchemaStackWorkers {
    // Bound reserved stack space when several deep calls arrive together.
    static let permits = DispatchSemaphore(value: 4)
}

// This bounded fast path leaves the ordinary scalar and shallow check without
// a heap allocation. It never recurses more than 17 calls.
private func shallowDepth(_ value: SchemaValue, _ depth: Int) -> Int {
    if depth > schemaLargeStackThreshold { return depth }
    var maximum = depth
    switch value {
    case .array(let items):
        for item in items {
            maximum = max(maximum, shallowDepth(item, depth + 1))
            if maximum > schemaLargeStackThreshold { return maximum }
        }
    case .object(let object):
        for (_, item) in object {
            maximum = max(maximum, shallowDepth(item, depth + 1))
            if maximum > schemaLargeStackThreshold { return maximum }
        }
    default: break
    }
    return maximum
}

// The unbounded part of depth measuring is iterative. `stoppingAt` avoids
// traversing an over-limit tree after its result is known.
func schemaNestingDepth(_ value: SchemaValue, stoppingAt: Int) -> Int {
    let shallow = shallowDepth(value, 0)
    if shallow <= schemaLargeStackThreshold { return shallow }
    var pending: [(SchemaValue, Int)] = [(value, 0)]
    var maximum = 0
    while let (next, depth) = pending.popLast() {
        maximum = max(maximum, depth)
        if maximum > stoppingAt { return maximum }
        switch next {
        case .array(let items):
            for item in items { pending.append((item, depth + 1)) }
        case .object(let object):
            for (_, item) in object { pending.append((item, depth + 1)) }
        default: break
        }
    }
    return maximum
}

// The library has synchronous APIs only. This helper is used only after a
// depth scan finds a permitted value/schema beyond the worker-stack threshold.
func schemaOnLargeStack<T: Sendable>(_ body: @escaping @Sendable () -> T) -> T? {
    SchemaStackWorkers.permits.wait()
    defer { SchemaStackWorkers.permits.signal() }
    let result = Mutex<T?>(nil)
    let done = DispatchSemaphore(value: 0)
    let thread = Thread {
        let value = body()
        result.withLock { $0 = value }
        done.signal()
    }
    thread.stackSize = schemaLargeStackBytes
    thread.start()
    done.wait()
    return result.withLock { $0 }
}
