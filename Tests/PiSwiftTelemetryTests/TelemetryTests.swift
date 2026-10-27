import Testing
import PiSwiftTelemetry

private final class TelemetryTestValue: Sendable {}
private final class TelemetryTestError: Error { let message = "test failure" }

private final class TelemetryTestContext: TelemetryContext {
    func startSpan<Result>(
        _ options: SpanOptions,
        body: (any TelemetrySpan) throws -> Result
    ) rethrows -> Result {
        try body(noopTelemetryContext)
    }

    func startSpan<Result: Sendable>(
        _ options: SpanOptions,
        body: @Sendable (any TelemetrySpan) async throws -> Result
    ) async rethrows -> Result {
        try await body(noopTelemetryContext)
    }
}

private actor TelemetryTestGate {
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

@Suite("Telemetry contract")
struct TelemetryTests {
    @Test("The root and every child use the same default span")
    func identity() {
        let result = noopTelemetryContext.startSpan(SpanOptions(name: "first")) { span in
            #expect(span === noopTelemetryContext)
            #expect(span.metrics === noopTelemetryMetrics)
            #expect(span.propagation === noopTelemetryPropagation)
            return span.startSpan(SpanOptions(name: "child")) { child in
                #expect(child === span)
                return 42
            }
        }
        #expect(result == 42)
    }

    @Test("Synchronous callbacks run before return and preserve result and error identity")
    func synchronousPassThrough() {
        let value = TelemetryTestValue()
        var admitted = false
        let result = noopTelemetryContext.startSpan(SpanOptions(name: "result")) { _ in
            admitted = true
            return value
        }
        #expect(admitted)
        #expect(result === value)
        let failure = TelemetryTestError()
        do {
            let _: Int = try noopTelemetryContext.startSpan(SpanOptions(name: "error")) { _ in
                throw failure
            }
            Issue.record("The callback must throw.")
        } catch {
            #expect(error as? TelemetryTestError === failure)
        }
    }

    @Test("Asynchronous callbacks preserve results and errors")
    func asynchronousPassThrough() async {
        let value = TelemetryTestValue()
        let result = await noopTelemetryContext.startSpan(SpanOptions(name: "result")) { span in
            await Task.yield()
            #expect(span === noopTelemetryContext)
            return value
        }
        #expect(result === value)
        let failure = TelemetryTestError()
        do {
            let _: Int = try await noopTelemetryContext.startSpan(SpanOptions(name: "error")) { _ in
                await Task.yield()
                throw failure
            }
            Issue.record("The callback must throw.")
        } catch {
            #expect(error as? TelemetryTestError === failure)
        }
    }

    @Test("Task cancellation remains visible to the callback")
    func cancellation() async {
        let ready = TelemetryTestGate()
        let gate = TelemetryTestGate()
        let task = Task {
            await noopTelemetryContext.startSpan(SpanOptions(name: "cancelled")) { _ in
                await ready.open()
                await gate.wait()
                #expect(Task.isCancelled)
                return 7
            }
        }
        await ready.wait()
        task.cancel()
        await gate.open()
        #expect(await task.value == 7)

        let checked = Task {
            try await noopTelemetryContext.startSpan(SpanOptions(name: "check")) { _ in
                await Task.yield()
                withUnsafeCurrentTask { $0?.cancel() }
                try Task.checkCancellation()
            }
        }
        do {
            try await checked.value
            Issue.record("The callback must report cancellation.")
        } catch {
            #expect(error is CancellationError)
        }
    }

    @Test("Typed recording payloads have no effect on the default span")
    func typedPayloads() {
        let attributes: SpanAttributes = [
            "string": .string("test"), "number": .number(2), "boolean": .boolean(true),
            "strings": .strings(["one", "two"]), "numbers": .numbers([1, 2]),
            "booleans": .booleans([true, false]),
        ]
        let link = SpanLink(context: noopTelemetryContext, attributes: attributes)
        let result = noopTelemetryContext.startSpan(
            SpanOptions(name: "operation", attributes: attributes, links: [link])
        ) { span in
            span.addEvent("event", attributes: attributes)
            span.addEvent("empty")
            span.setAttributes(attributes)
            span.setStatus(.error(SpanError(name: "Expected", message: "test")))
            span.setStatus(.error())
            span.setStatus(.ok)
            span.addLink(link)
            return 42
        }
        #expect(result == 42)
        #expect(attributes["numbers"] == .numbers([1, 2]))
    }

    @Test("Metrics reuse inert instruments and propagation returns the shared root")
    func capabilities() {
        let counter = noopTelemetryMetrics.counter(name: "count", options: InstrumentOptions(unit: "items"))
        let upDown = noopTelemetryMetrics.upDownCounter(name: "active")
        let histogram = noopTelemetryMetrics.histogram(
            name: "time", options: HistogramOptions(description: "Time", unit: "s", boundaries: [1, 2])
        )
        #expect(counter === noopTelemetryMetrics.counter(name: "other"))
        #expect(upDown === noopTelemetryMetrics.upDownCounter(name: "other"))
        #expect(histogram === noopTelemetryMetrics.histogram(name: "other"))
        counter.add(2, attributes: ["kind": .string("test")])
        counter.add(1)
        upDown.add(-1, attributes: ["active": .boolean(false)])
        upDown.add(1)
        histogram.record(2, attributes: ["kind": .string("test")], context: noopTelemetryContext)
        histogram.record(1)
        histogram.record(1, context: noopTelemetryContext)
        #expect(noopTelemetryPropagation.inject(noopTelemetryContext) == nil)
        let extracted = noopTelemetryPropagation.extract(["opaque": "value"])
        #expect(extracted === noopTelemetryContext)
        #expect(noopTelemetryPropagation.extract(nil) === noopTelemetryContext)
        #expect(extracted.metrics === noopTelemetryMetrics)
        #expect(extracted.propagation === noopTelemetryPropagation)
    }

    @Test("Default recording and propagation do not retain context inputs")
    func retention() {
        weak var released: TelemetryTestContext?
        do {
            let context = TelemetryTestContext()
            released = context
            noopTelemetryContext.addLink(SpanLink(context: context))
            noopTelemetryMetrics.histogram(name: "value").record(1, context: context)
            #expect(noopTelemetryPropagation.inject(context) == nil)
            #expect(context.metrics == nil)
            #expect(context.propagation == nil)
        }
        #expect(released == nil)
    }
}
