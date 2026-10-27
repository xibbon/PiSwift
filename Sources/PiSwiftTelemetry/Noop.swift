/// The shared default context. The root and every child are the same inert span.
public let noopTelemetryContext: any TelemetrySpan = NoopTelemetrySpan()

/// Shared instruments that do not inspect or retain their inputs.
public let noopTelemetryMetrics: any TelemetryMetrics = NoopTelemetryMetrics()

/// Shared propagation that injects no data and extracts the shared default context.
public let noopTelemetryPropagation: any TelemetryPropagation = NoopTelemetryPropagation()

private final class NoopTelemetrySpan: TelemetrySpan {
    var metrics: (any TelemetryMetrics)? { noopTelemetryMetrics }
    var propagation: (any TelemetryPropagation)? { noopTelemetryPropagation }

    func startSpan<Result>(
        _ options: SpanOptions,
        body: (any TelemetrySpan) throws -> Result
    ) rethrows -> Result {
        try body(self)
    }

    func startSpan<Result: Sendable>(
        _ options: SpanOptions,
        body: @Sendable (any TelemetrySpan) async throws -> Result
    ) async rethrows -> Result {
        try await body(self)
    }

    func addLink(_ link: SpanLink) {}
    func addEvent(_ name: String, attributes: SpanAttributes?) {}
    func setAttributes(_ attributes: SpanAttributes) {}
    func setStatus(_ status: SpanStatus) {}
}

private final class NoopCounter: TelemetryCounter {
    func add(_ value: Double, attributes: SpanAttributes?) {}
}

private final class NoopUpDownCounter: TelemetryUpDownCounter {
    func add(_ value: Double, attributes: SpanAttributes?) {}
}

private final class NoopHistogram: TelemetryHistogram {
    func record(_ value: Double, attributes: SpanAttributes?, context: (any TelemetryContext)?) {}
}

private final class NoopTelemetryMetrics: TelemetryMetrics {
    private let sharedCounter = NoopCounter()
    private let sharedUpDownCounter = NoopUpDownCounter()
    private let sharedHistogram = NoopHistogram()

    func counter(name: String, options: InstrumentOptions?) -> any TelemetryCounter { sharedCounter }
    func upDownCounter(name: String, options: InstrumentOptions?) -> any TelemetryUpDownCounter {
        sharedUpDownCounter
    }
    func histogram(name: String, options: HistogramOptions?) -> any TelemetryHistogram { sharedHistogram }
}

private final class NoopTelemetryPropagation: TelemetryPropagation {
    func inject(_ context: any TelemetryContext) -> TelemetryCarrier? { nil }
    func extract(_ carrier: TelemetryCarrier?) -> any TelemetryContext { noopTelemetryContext }
}
