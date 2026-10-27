import Synchronization
import Testing
import PiSwiftChord
import PiSwiftTelemetry

private struct ContextSpanRecord: Sendable {
    let id: Int
    let parentID: Int?
    let options: SpanOptions
    var events: [String] = []
    var links: [ObjectIdentifier] = []
    var attributes: SpanAttributes = [:]
    var status: SpanStatus = .ok
}

private final class ContextSpanStore: Sendable {
    private let records = Mutex<[ContextSpanRecord]>([])

    func create(parentID: Int?, options: SpanOptions) -> Int {
        records.withLock { records in
            let id = records.count
            records.append(ContextSpanRecord(id: id, parentID: parentID, options: options))
            return id
        }
    }

    func update(_ id: Int?, _ body: (inout ContextSpanRecord) -> Void) {
        guard let id else { return }
        records.withLock { body(&$0[id]) }
    }

    func snapshot() -> [ContextSpanRecord] { records.withLock { $0 } }
}

/// This test adapter records explicit parent IDs. It has no ambient current span.
private final class ContextRecordingSpan: TelemetrySpan {
    let id: Int?
    let store: ContextSpanStore
    let metrics: (any TelemetryMetrics)? = noopTelemetryMetrics
    let propagation: (any TelemetryPropagation)? = noopTelemetryPropagation

    init(store: ContextSpanStore = ContextSpanStore(), id: Int? = nil) {
        self.store = store
        self.id = id
    }

    func startSpan<Result>(
        _ options: SpanOptions,
        body: (any TelemetrySpan) throws -> Result
    ) rethrows -> Result {
        let child = ContextRecordingSpan(store: store, id: store.create(parentID: id, options: options))
        return try body(child)
    }

    func startSpan<Result: Sendable>(
        _ options: SpanOptions,
        body: @Sendable (any TelemetrySpan) async throws -> Result
    ) async rethrows -> Result {
        let child = ContextRecordingSpan(store: store, id: store.create(parentID: id, options: options))
        return try await body(child)
    }

    func addLink(_ link: SpanLink) {
        store.update(id) { $0.links.append(ObjectIdentifier(link.context)) }
    }

    func addEvent(_ name: String, attributes: SpanAttributes?) {
        store.update(id) { $0.events.append(name) }
    }

    func setAttributes(_ attributes: SpanAttributes) {
        store.update(id) { $0.attributes.merge(attributes, uniquingKeysWith: { _, new in new }) }
    }

    func setStatus(_ status: SpanStatus) { store.update(id) { $0.status = status } }
}

private final class ContextTelemetryError: Error { let reason = "same error" }
private final class ContextTelemetryValue: Sendable {}

private actor ContextTelemetryGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        let pending = waiters
        waiters = []
        for waiter in pending { waiter.resume() }
    }
}

@Suite("Context telemetry")
struct TelemetryContextTests {
    @Test("Distinct empty roots share the default span")
    func roots() {
        #expect(ChordContext.background.description != ChordContext.todo.description)
        #expect(ChordContext.background.telemetry === noopTelemetryContext)
        #expect(ChordContext.todo.telemetry === noopTelemetryContext)
        #expect(ChordContext.background.abortSignal == nil)
        #expect(ChordContext.todo.abortSignal == nil)
    }

    @Test("Telemetry derivation preserves values and cancellation")
    func independentLayers() {
        let root = ContextRecordingSpan()
        let other = ContextRecordingSpan()
        root.startSpan(SpanOptions(name: "caller")) { parent in
            other.startSpan(SpanOptions(name: "other")) { otherSpan in
                let key = ChordContextKey<String>("principal")
                let controller = AbortController()
                let base = ChordContext.background.withAbortSignal(controller.signal).withValue("owner", for: key)
                let context = base.withTelemetry(parent)
                let replaced = context.withTelemetry(otherSpan)
                #expect(base.telemetry === noopTelemetryContext)
                #expect(context.telemetry === parent)
                #expect(replaced.telemetry === otherSpan)
                #expect(replaced.value(key) == "owner")
                #expect(replaced.abortSignal === base.abortSignal)
                #expect(context.withoutAbortSignal().telemetry === parent)
                #expect(context.withCancel().context.telemetry === parent)
                #expect(context.withValue("changed", for: key).telemetry === parent)
                #expect(context.telemetry.metrics === noopTelemetryMetrics)
                #expect(context.telemetry.propagation === noopTelemetryPropagation)

                let result = traceIn(context, SpanOptions(name: "outer")) { child in
                    #expect(child.value(key) == "owner")
                    #expect(child.abortSignal === context.abortSignal)
                    child.telemetry.addEvent("started")
                    child.telemetry.setAttributes(["complete": .boolean(true)])
                    child.telemetry.setStatus(.ok)
                    return child.traceIn(SpanOptions(name: "inner")) { nested in
                        nested.telemetry.addLink(SpanLink(context: child.telemetry))
                        return 42
                    }
                }
                #expect(result == 42)
                let spans = root.store.snapshot()
                #expect(spans.map { $0.options.name } == ["caller", "outer", "inner"])
                guard spans.count == 3 else { return }
                #expect(spans[1].parentID == spans[0].id)
                #expect(spans[2].parentID == spans[1].id)
                #expect(spans[1].events == ["started"])
                #expect(spans[1].attributes["complete"] == .boolean(true))
                #expect(spans[2].links.count == 1)
                #expect(context.telemetry === parent)
                controller.abort()
                #expect(context.abortSignal?.aborted == true)
                #expect(context.withoutAbortSignal().abortSignal == nil)
            }
        }
    }

    @Test("Concurrent branches use their own explicit parents")
    func concurrentBranches() async {
        let root = ContextRecordingSpan()
        await root.startSpan(SpanOptions(name: "caller")) { parent in
            let context = ChordContext.background.withTelemetry(parent)
            let gate = ContextTelemetryGate()
            async let first = traceIn(context, SpanOptions(name: "first")) { child in
                await gate.wait()
                return child.traceIn(SpanOptions(name: "first.child")) { _ in "first" }
            }
            async let second = context.traceIn(SpanOptions(name: "second")) { child in
                let result = child.traceIn(SpanOptions(name: "second.child")) { _ in "second" }
                await gate.open()
                return result
            }
            let results = await (first, second)
            #expect(results.0 == "first")
            #expect(results.1 == "second")
            #expect(context.telemetry === parent)
            let spans = root.store.snapshot()
            let callerID = (parent as? ContextRecordingSpan)?.id
            for name in ["first", "second"] {
                let branch = spans.first { $0.options.name == name }
                let child = spans.first { $0.options.name == "\(name).child" }
                #expect(branch != nil)
                #expect(child != nil)
                #expect(branch?.parentID == callerID)
                #expect(child?.parentID == branch?.id)
            }
        }
    }

    @Test("Synchronous and asynchronous results and errors pass through")
    func resultsAndErrors() async {
        let root = ContextRecordingSpan()
        let context = ChordContext.background.withTelemetry(root)
        let value = ContextTelemetryValue()
        let syncResult = context.traceIn(SpanOptions(name: "sync")) { _ in value }
        #expect(syncResult === value)
        let asyncResult = await traceIn(context, SpanOptions(name: "async")) { _ in
            await Task.yield()
            return value
        }
        #expect(asyncResult === value)
        let failure = ContextTelemetryError()
        do {
            let _: Int = try context.traceIn(SpanOptions(name: "throw")) { _ in throw failure }
            Issue.record("The callback must throw.")
        } catch { #expect(error as? ContextTelemetryError === failure) }
        do {
            let _: Int = try await context.traceIn(SpanOptions(name: "reject")) { _ in
                await Task.yield()
                throw failure
            }
            Issue.record("The callback must throw.")
        } catch { #expect(error as? ContextTelemetryError === failure) }
        let noopResult = ChordContext.background.traceIn(SpanOptions(name: "noop")) { child in
            #expect(child.telemetry === noopTelemetryContext)
            child.telemetry.addLink(SpanLink(context: root))
            return 42
        }
        #expect(noopResult == 42)
    }

    @Test("Tracing keeps both cancellation mechanisms under caller control")
    func cancellation() async {
        let root = ContextRecordingSpan()
        let controller = AbortController()
        let context = ChordContext.background.withTelemetry(root).withAbortSignal(controller.signal)
        let ready = ContextTelemetryGate()
        let gate = ContextTelemetryGate()
        let failure = ContextTelemetryError()
        let task = Task {
            await context.traceIn(SpanOptions(name: "cancelled")) { child in
                await ready.open()
                await gate.wait()
                #expect(Task.isCancelled)
                #expect(child.abortSignal === context.abortSignal)
                #expect(child.abortSignal?.aborted == true)
                #expect(child.abortSignal?.reason as? ContextTelemetryError === failure)
                return 17
            }
        }
        await ready.wait()
        task.cancel()
        controller.abort(failure)
        await gate.open()
        #expect(await task.value == 17)
        #expect(context.telemetry === root)
    }
}
