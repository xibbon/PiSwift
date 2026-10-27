/// One scalar or array value in telemetry attributes.
/// Numbers use Double, as in the upstream JavaScript contract.
public enum AttributeValue: Sendable, Equatable {
    case string(String)
    case number(Double)
    case boolean(Bool)
    case strings([String])
    case numbers([Double])
    case booleans([Bool])
}

/// Attributes supplied to a span, event, link, or metric.
/// An absent dictionary entry is the Swift form of an undefined upstream value.
public typealias SpanAttributes = [String: AttributeValue]

/// Opaque propagation data owned by the application adapter.
public typealias TelemetryCarrier = [String: String]

/// An optional adapter capability for transport across process boundaries.
public protocol TelemetryPropagation: AnyObject, Sendable {
    func inject(_ context: any TelemetryContext) -> TelemetryCarrier?
    /// Absent or unknown carriers return the adapter root.
    func extract(_ carrier: TelemetryCarrier?) -> any TelemetryContext
}

/// A link to a span or an extracted remote parent.
public struct SpanLink: Sendable {
    public var context: any TelemetryContext
    public var attributes: SpanAttributes?

    public init(context: any TelemetryContext, attributes: SpanAttributes? = nil) {
        self.context = context
        self.attributes = attributes
    }
}

/// The name, initial attributes, and links of a new span.
public struct SpanOptions: Sendable {
    public var name: String
    public var attributes: SpanAttributes?
    public var links: [SpanLink]?

    public init(name: String, attributes: SpanAttributes? = nil, links: [SpanLink]? = nil) {
        self.name = name
        self.attributes = attributes
        self.links = links
    }
}

/// Error data that can be sent to a telemetry adapter.
public struct SpanError: Sendable, Equatable {
    public var name: String
    public var message: String

    public init(name: String, message: String) {
        self.name = name
        self.message = message
    }
}

/// The status of a span. An error can omit its details.
public enum SpanStatus: Sendable, Equatable {
    case ok
    case error(SpanError? = nil)
}

/// An explicit telemetry parent. Adapters trust valid typed input.
/// Capabilities must remain available on child spans and extracted parents.
public protocol TelemetryContext: AnyObject, Sendable {
    var metrics: (any TelemetryMetrics)? { get }
    var propagation: (any TelemetryPropagation)? { get }

    /// Runs a callback with a child span and passes its result or error through.
    func startSpan<Result>(
        _ options: SpanOptions,
        body: (any TelemetrySpan) throws -> Result
    ) rethrows -> Result

    /// Runs asynchronous work without changing its task cancellation behavior.
    func startSpan<Result: Sendable>(
        _ options: SpanOptions,
        body: @Sendable (any TelemetrySpan) async throws -> Result
    ) async rethrows -> Result
}

extension TelemetryContext {
    /// Adapters can omit metrics and propagation support.
    public var metrics: (any TelemetryMetrics)? { nil }
    public var propagation: (any TelemetryPropagation)? { nil }
}

/// A span that can record data and serve as the parent of another span.
public protocol TelemetrySpan: TelemetryContext {
    func addLink(_ link: SpanLink)
    func addEvent(_ name: String, attributes: SpanAttributes?)
    func setAttributes(_ attributes: SpanAttributes)
    func setStatus(_ status: SpanStatus)
}

extension TelemetrySpan {
    public func addEvent(_ name: String) { addEvent(name, attributes: nil) }
}
