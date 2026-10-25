import PiSwiftAI

public enum ToolNameCollisionPolicy: String, Sendable, Codable {
    case overwrite
    case reject
}

public enum CodemodeFailureKind: String, Sendable {
    case script, timeout, aborted, sandbox
}

public struct CodemodeFailure: Sendable {
    public var kind: CodemodeFailureKind
    public var name: String?
    public var message: String
    public var stack: String?

    public init(kind: CodemodeFailureKind, message: String, name: String? = nil, stack: String? = nil) {
        self.kind = kind
        self.name = name
        self.message = message
        self.stack = stack
    }
}

/// Output from a script, before the result layout is applied.
public enum CodemodeOutputItem: Sendable {
    case text(String, console: Bool = false)
    case image(ImageContent)

    /// Create ordinary text output from an existing text content block.
    public static func text(_ value: TextContent) -> Self { .text(value.text, console: false) }
}

public struct CodemodeExecutionResult: Sendable {
    public var output: [CodemodeOutputItem]
    public var returnedValue: AnyCodable?
    public var failure: CodemodeFailure?

    public init(output: [CodemodeOutputItem], returnedValue: AnyCodable? = nil, failure: CodemodeFailure? = nil) {
        self.output = output
        self.returnedValue = returnedValue
        self.failure = failure
    }
}
