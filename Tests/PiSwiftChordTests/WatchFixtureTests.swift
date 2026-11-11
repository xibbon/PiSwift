import Foundation
import Synchronization
import Testing
@testable import PiSwiftChord

// The oracle controls microtask turns. These gates give Swift the same input boundaries.
private final class WatchFixtureGate: Sendable {
    private struct State {
        var open = false
        var waiters: [CheckedContinuation<Void, Never>] = []
    }
    private let state = Mutex(State())
    func wait() async {
        await withCheckedContinuation { continuation in
            let ready = state.withLock { state in
                if state.open { return true }
                state.waiters.append(continuation)
                return false
            }
            if ready { continuation.resume() }
        }
    }
    func release() {
        let waiters = state.withLock { state in
            state.open = true
            let waiters = state.waiters
            state.waiters = []
            return waiters
        }
        for waiter in waiters { waiter.resume() }
    }
    func hold() { state.withLock { $0.open = false } }
}

private struct WatchFixtureError: Error, Sendable, CustomStringConvertible {
    let description: String
}

private final class WatchFixtureLog: Sendable {
    struct State {
        var calls: [JSONValue] = []
        var detached = 0
        var reports: [JSONValue] = []
        var completed = 0
        var waiters: [(Int, CheckedContinuation<Void, Never>)] = []
    }
    let state = Mutex(State())
    func append(_ call: JSONValue) {
        let ready = state.withLock { state in
            state.calls.append(call)
            let ready = state.waiters.filter { $0.0 <= state.calls.count }
            state.waiters.removeAll { $0.0 <= state.calls.count }
            return ready
        }
        for (_, continuation) in ready { continuation.resume() }
    }
    func waitForCalls(_ count: Int) async {
        await withCheckedContinuation { continuation in
            let ready = state.withLock { state in
                if state.calls.count >= count { return true }
                state.waiters.append((count, continuation))
                return false
            }
            if ready { continuation.resume() }
        }
    }
}

private enum WatchFixtureHandle: Sendable {
    case json(Watch<JSONValue>)
    case native(NativeWatch<JSONValue>)
    var value: JSONValue {
        switch self { case .json(let watch): watch.value; case .native(let watch): watch.value }
    }
    func advance(_ value: JSONValue, ops: [Delta.Op], retired: Bool, context: ChordContext) {
        switch self {
        case .json(let watch): watch.advance(.value(value: value, ops: ops, retired: retired), context: context)
        case .native(let watch): watch.advance(value, context: context)
        }
    }
    func fail(_ message: String, context: ChordContext) {
        switch self {
        case .json(let watch): watch.fail(.message(message), context: context)
        case .native(let watch): watch.fail(.message(message), context: context)
        }
    }
    func start(_ listener: @escaping @Sendable (JSONValue, ChordContext) async throws -> Void) throws {
        switch self {
        case .json(let watch):
            try watch.start { call, context in
                let data: JSONValue
                switch call {
                case .value(let value, let ops, let retired):
                    data = ["kind": "value", "value": value, "ops": .array(ops.map(\.json)), "retired": .bool(retired)]
                case .failed(let failure): data = ["kind": "failed", "error": fixtureFailure(failure)]
                }
                try await listener(data, context)
            }
        case .native(let watch):
            try watch.start { call, context in
                let data: JSONValue
                switch call {
                case .value(let value): data = ["kind": "value", "value": value]
                case .failed(let failure): data = ["kind": "failed", "error": fixtureFailure(failure)]
                }
                try await listener(data, context)
            }
        }
    }
    func stop() async -> WatchEnd {
        switch self { case .json(let watch): await watch.stop(); case .native(let watch): await watch.stop() }
    }
    var closed: WatchEnd {
        get async { switch self { case .json(let watch): await watch.closed; case .native(let watch): await watch.closed } }
    }
    func abort() { switch self { case .json(let watch): watch.abort(); case .native(let watch): watch.abort() } }
    func observeAbort(_ signal: AbortSignal) throws {
        switch self { case .json(let watch): try watch.observeAbort(signal); case .native(let watch): try watch.observeAbort(signal) }
    }
    func end(_ end: WatchEnd) { switch self { case .json(let watch): watch.end(end); case .native(let watch): watch.end(end) } }
    func endAfterDelivery() { switch self { case .json(let watch): watch.endAfterDelivery(); case .native(let watch): watch.endAfterDelivery() } }
    func waitUntilIdle() async {
        switch self { case .json(let watch): await watch.waitUntilIdle(); case .native(let watch): await watch.waitUntilIdle() }
    }
}

private func fixtureFailure(_ failure: WatchFailure) -> JSONValue {
    switch failure { case .message(let message): .string(message); case .value(let value): value }
}
private func fixtureEnd(_ end: WatchEnd) -> JSONValue {
    switch end {
    case .stopped: ["kind": "stopped"]
    case .aborted: ["kind": "aborted"]
    case .ended: ["kind": "ended"]
    case .failed(let error): ["kind": "failed", "error": fixtureFailure(error)]
    case .listenerError(let error): ["kind": "listener_error", "error": .string(error)]
    }
}
private func fixtureError(_ error: any Error) -> String {
    guard let error = error as? WatchError else { return String(describing: error) }
    switch error {
    case .alreadyStarted: return "Watch is already started"
    case .stopped: return "Watch is stopped"
    case .abortAlreadyInstalled: return "Watch abort is already installed"
    }
}

@Suite struct WatchFixtureTests {
    @Test(.timeLimit(.minutes(1)))
    func taggedScenariosMatchEveryObservation() async throws {
        let url = try #require(Bundle.module.url(forResource: "watch-v152-fixtures", withExtension: "json", subdirectory: "Fixtures"))
        let root = try JSONValue(jsonData: Data(contentsOf: url))
        #expect(root["upstream"] == "pi-mono v1.5.2")
        let scenarios = try #require(root["cases"]?.arrayValue)
        #expect(scenarios.count == 327)
        for scenario in scenarios { try await replay(scenario) }
    }

    private func replay(_ scenario: JSONValue) async throws {
        let name = try #require(scenario["name"]?.stringValue)
        let initial = try #require(scenario["initial"])
        let steps = try #require(scenario["steps"]?.arrayValue)
        let events = try #require(scenario["events"]?.arrayValue)
        #expect(steps.count == events.count)
        let log = WatchFixtureLog()
        let delivery = WatchFixtureGate()
        let listenerGate = WatchFixtureGate()
        let controller = AbortController()
        let key = ChordContextKey<String>("watch.fixture.context")
        let detach: @Sendable () -> Void = { log.state.withLock { $0.detached += 1 } }
        let report: @Sendable (any Error) -> Void = { error in log.state.withLock { $0.reports.append(.string(String(describing: error))) } }
        let watch: WatchFixtureHandle
        if scenario["kind"] == "json" {
            watch = .json(Watch(value: initial, replacement: { $0 }, detach: detach, report: report, deliveryReady: { await delivery.wait() }))
        } else {
            let replacement = scenario["replacement"]
            let replace: (@Sendable () -> JSONValue)? = replacement.map { value in { @Sendable in value } }
            watch = .native(NativeWatch(value: initial, detach: detach, report: report, replace: replace, deliveryReady: { await delivery.wait() }))
        }
        var blocked = false
        var releasePending = false
        var expectedCallCount = 0
        var callOffset = 0
        var observedEnd: JSONValue?
        for (index, step) in steps.enumerated() {
            let event = events[index]
            let op = try #require(step["op"]?.stringValue)
            var errorText: String?
            let context = ChordContext.background.withAbortSignal(controller.signal).withValue(step["context"]?.stringValue ?? "frame", for: key)
            do {
                switch op {
                case "advance":
                    let ops = try (step["ops"]?.arrayValue ?? []).map { try Delta.Op(json: $0) }
                    watch.advance(try #require(step["value"]), ops: ops, retired: step["retired"] == true, context: context)
                case "burst":
                    let count = try #require(step["count"]?.intValue)
                    let from = try #require(step["from"]?.intValue)
                    for offset in 0..<count {
                        let value: JSONValue = ["n": .number(Double(from + offset))]
                        let ops: [Delta.Op] = step["increment"] == true ? [.trim(["n"], 1)] : [.set(["n"], .number(Double(from + offset)))]
                        watch.advance(value, ops: ops, retired: step["retiredAt"]?.intValue == offset, context: context)
                    }
                case "fail": watch.fail(try #require(step["error"]?.stringValue), context: context)
                case "start":
                    let block = step["block"] == true
                    let thrown = step["throw"]?.stringValue
                    let first = Mutex(true)
                    try watch.start { call, context in
                        log.append(["call": call, "context": .string(context.value(key) ?? ""), "abortRemoved": .bool(context.abortSignal == nil)])
                        let isFirst = first.withLock { state in let value = state; state = false; return value }
                        if block && isFirst { await listenerGate.wait() }
                        defer { log.state.withLock { $0.completed += 1 } }
                        if let thrown { throw WatchFixtureError(description: thrown) }
                    }
                    if block { blocked = true }
                case "release": releasePending = true
                case "flush":
                    if releasePending { listenerGate.release(); blocked = false; releasePending = false }
                    delivery.release()
                    expectedCallCount += event["calls"]?.arrayValue?.count ?? 0
                    if blocked { await log.waitForCalls(expectedCallCount) }
                    else { await watch.waitUntilIdle() }
                    delivery.hold()
                    if log.state.withLock({ $0.detached > 0 }) { observedEnd = fixtureEnd(await watch.closed) }
                case "stop": observedEnd = fixtureEnd(await watch.stop())
                case "abort": watch.abort()
                case "observeAbort":
                    if step["aborted"] == true { controller.abort() }
                    try watch.observeAbort(controller.signal)
                case "cancel": controller.abort()
                case "endAfterDelivery": watch.endAfterDelivery()
                case "end":
                    switch step["kind"]?.stringValue {
                    case "failed": watch.end(.failed(.message(try #require(step["error"]?.stringValue))))
                    case "listener_error": watch.end(.listenerError(try #require(step["error"]?.stringValue)))
                    case "stopped": watch.end(.stopped)
                    case "aborted": watch.end(.aborted)
                    default: watch.end(.ended)
                    }
                default: Issue.record("Unknown fixture operation: \(op)")
                }
            } catch { errorText = fixtureError(error) }
            let observed = log.state.withLock { state -> (calls: [JSONValue], detached: Int, reports: [JSONValue]) in
                (Array(state.calls.dropFirst(callOffset)), state.detached, state.reports)
            }
            callOffset += observed.calls.count
            let label = "\(name) step \(index) \(op)"
            #expect(watch.value == event["value"], Comment(rawValue: label))
            #expect(observed.calls == (event["calls"]?.arrayValue ?? []), Comment(rawValue: label))
            #expect(observed.detached == (event["detached"]?.intValue ?? 0), Comment(rawValue: label))
            #expect(observed.reports == (event["reports"]?.arrayValue ?? []), Comment(rawValue: label))
            #expect(observedEnd == event["closed"], Comment(rawValue: label))
            #expect(errorText == event["error"]?.stringValue, Comment(rawValue: label))
        }
        listenerGate.release()
        delivery.release()
        _ = await watch.stop()
    }
}
