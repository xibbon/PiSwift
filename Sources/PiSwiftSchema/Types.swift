// Ported from packages/schema/src/types.ts, pi-mono v1.5.2.
import Foundation

/// The JSON Schema draft used by the validator.
public enum SchemaDraft: Sendable { case draft2020_12, draft7 }
/// How compilation handles references that do not resolve.
public enum UnresolvedRefs: Sendable { case `throw`, reject }
/// A function that checks a string format.
public typealias FormatCheck = @Sendable (String) -> Bool

/// Options for compiling a schema.
public struct CompileOptions: Sendable {
    public var draft: SchemaDraft
    public var formats: [String: FormatCheck]?
    public var schemas: [String: SchemaValue]
    public var coerce: Bool
    public var unresolvedRefs: UnresolvedRefs

    /// Creates compile options.
    public init(draft: SchemaDraft = .draft2020_12, formats: [String: FormatCheck]? = nil,
                schemas: [String: SchemaValue] = [:], coerce: Bool = false,
                unresolvedRefs: UnresolvedRefs = .throw) {
        self.draft = draft
        self.formats = formats
        self.schemas = schemas
        self.coerce = coerce
        self.unresolvedRefs = unresolvedRefs
    }
}

/// A failure to compile a schema.
public enum SchemaCompileError: Error, Sendable, CustomStringConvertible {
    case malformedSchema(String)
    case unresolvedReference(String)
    case invalidPattern(String)

    public var description: String {
        switch self {
        case .malformedSchema(let message), .unresolvedReference(let message), .invalidPattern(let message): return message
        }
    }
}

/// One failed schema keyword at a JSON Pointer path.
public struct SchemaIssue: Sendable, Equatable {
    /// The JSON Pointer to the failed value.
    public let path: String
    /// The failed schema keyword.
    public let keyword: String
    /// The explanation shown for the failure.
    public let message: String

    /// Creates a schema issue.
    public init(path: String, keyword: String, message: String) {
        self.path = path
        self.keyword = keyword
        self.message = message
    }
}

/// The original value when valid, or its ordered schema issues.
public enum SchemaParseResult: Sendable {
    /// The original value passed validation.
    case ok(SchemaValue)
    /// The value failed with these ordered issues.
    case failed([SchemaIssue])
}
