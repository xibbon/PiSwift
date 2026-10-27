/// Optional instrument metadata.
public struct InstrumentOptions: Sendable, Equatable {
    public var description: String?
    public var unit: String?

    public init(description: String? = nil, unit: String? = nil) {
        self.description = description
        self.unit = unit
    }
}

/// Optional histogram metadata and bucket hints.
public struct HistogramOptions: Sendable, Equatable {
    public var description: String?
    public var unit: String?
    /// Callers supply finite values in strictly increasing order.
    public var boundaries: [Double]?

    public init(description: String? = nil, unit: String? = nil, boundaries: [Double]? = nil) {
        self.description = description
        self.unit = unit
        self.boundaries = boundaries
    }
}

public protocol TelemetryCounter: AnyObject, Sendable {
    /// Callers supply finite, nonnegative increments.
    func add(_ value: Double, attributes: SpanAttributes?)
}

public protocol TelemetryUpDownCounter: AnyObject, Sendable {
    /// Callers supply finite increments, which can be positive or negative.
    func add(_ value: Double, attributes: SpanAttributes?)
}

public protocol TelemetryHistogram: AnyObject, Sendable {
    func record(_ value: Double, attributes: SpanAttributes?, context: (any TelemetryContext)?)
}

/// Optional synchronous metric factories and recording methods.
/// Adapters trust valid typed inputs; malformed input behavior is unspecified.
public protocol TelemetryMetrics: AnyObject, Sendable {
    func counter(name: String, options: InstrumentOptions?) -> any TelemetryCounter
    func upDownCounter(name: String, options: InstrumentOptions?) -> any TelemetryUpDownCounter
    func histogram(name: String, options: HistogramOptions?) -> any TelemetryHistogram
}

extension TelemetryCounter {
    public func add(_ value: Double) { add(value, attributes: nil) }
}

extension TelemetryUpDownCounter {
    public func add(_ value: Double) { add(value, attributes: nil) }
}

extension TelemetryHistogram {
    public func record(_ value: Double, attributes: SpanAttributes? = nil) {
        record(value, attributes: attributes, context: nil)
    }

    public func record(_ value: Double, context: any TelemetryContext) {
        record(value, attributes: nil, context: context)
    }
}

extension TelemetryMetrics {
    public func counter(name: String) -> any TelemetryCounter { counter(name: name, options: nil) }
    public func upDownCounter(name: String) -> any TelemetryUpDownCounter {
        upDownCounter(name: name, options: nil)
    }
    public func histogram(name: String) -> any TelemetryHistogram { histogram(name: name, options: nil) }
}
