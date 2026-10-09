import PiSwiftChord

/// A record kind for the one global durable ID namespace.
public protocol DurableIDKind: Sendable {}
public enum ConversationIDKind: DurableIDKind {}
public enum EntryIDKind: DurableIDKind {}
public enum TaskIDKind: DurableIDKind {}
public enum SubmissionIDKind: DurableIDKind {}
public enum DocumentIDKind: DurableIDKind {}

/// A numeric ID with a record kind that exists only in the Swift type system.
/// JSON contains the number alone. All kinds share one allocation namespace.
public struct DurableID<Kind: DurableIDKind>: Sendable, Equatable, Hashable, Comparable, Codable {
    public static var maximumRawValue: Int64 { 9_007_199_254_740_991 }
    public let rawValue: Int64

    /// Checks the positive JavaScript safe-integer range.
    public init(_ rawValue: Int64) throws {
        guard (1...Self.maximumRawValue).contains(rawValue) else {
            throw DurableValueError.invalidID(String(rawValue))
        }
        self.rawValue = rawValue
    }
    fileprivate init(checked rawValue: Int64) { self.rawValue = rawValue }
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    public init(from decoder: any Decoder) throws {
        let value = try JSONValue(from: decoder)
        guard let number = value.numberValue else { throw DurableValueError.invalidID(value.description) }
        self = try idFromNumber(number)
    }
    public func encode(to encoder: any Encoder) throws {
        try JSONValue.number(Double(rawValue)).encode(to: encoder)
    }
}

public typealias ConversationID = DurableID<ConversationIDKind>
public typealias EntryID = DurableID<EntryIDKind>
/// Upstream `TaskId<R>` has a result phantom. Swift omits it; task kinds supply typed results in the harness.
public typealias TaskID = DurableID<TaskIDKind>
public typealias SubmissionID = DurableID<SubmissionIDKind>
public typealias DocumentID = DurableID<DocumentIDKind>

/// The reserved ID of the root conversation.
public let rootConversationID = ConversationID(checked: 1)

/// Applies an ID kind at a numeric boundary after range validation.
/// Upstream `ids.ts` only casts; Swift also checks the storage ID invariant.
public func idFromNumber<Kind: DurableIDKind>(_ value: Double) throws -> DurableID<Kind> {
    guard value.isFinite, let integer = Int64(exactly: value),
          (1...DurableID<Kind>.maximumRawValue).contains(integer) else {
        throw DurableValueError.invalidID(JSONValue.number(value).description)
    }
    return DurableID(checked: integer)
}

/// A positive safe-integer commit sequence. Sequences strictly increase; gaps are permitted.
public struct Seq: Sendable, Equatable, Hashable, Comparable, Codable {
    public static let maximumRawValue: Int64 = 9_007_199_254_740_991
    public let rawValue: Int64
    public init(_ rawValue: Int64) throws {
        guard (1...Self.maximumRawValue).contains(rawValue) else {
            throw DurableValueError.invalidSequence(String(rawValue))
        }
        self.rawValue = rawValue
    }
    fileprivate init(checked rawValue: Int64) { self.rawValue = rawValue }
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    public init(from decoder: any Decoder) throws {
        let value = try JSONValue(from: decoder)
        guard let number = value.numberValue else { throw DurableValueError.invalidSequence(value.description) }
        self = try seqFromNumber(number)
    }
    public func encode(to encoder: any Encoder) throws {
        try JSONValue.number(Double(rawValue)).encode(to: encoder)
    }
}

/// Applies the sequence type at a numeric boundary after range validation.
/// Upstream `ids.ts` only casts; Swift also checks the safe positive range.
public func seqFromNumber(_ value: Double) throws -> Seq {
    guard value.isFinite, let integer = Int64(exactly: value),
          (1...Seq.maximumRawValue).contains(integer) else {
        throw DurableValueError.invalidSequence(JSONValue.number(value).description)
    }
    return Seq(checked: integer)
}

/// Swift boundary validation errors. Upstream erased brands have no runtime validation errors.
public enum DurableValueError: Error, Sendable, Equatable, CustomStringConvertible {
    case invalidID(String)
    case invalidSequence(String)
    case emptyEntryKind
    public var description: String {
        switch self {
        case .invalidID(let value): "Invalid durable ID: \(value); expected an integer from 1 through 9007199254740991"
        case .invalidSequence(let value): "Invalid durable sequence: \(value); expected an integer from 1 through 9007199254740991"
        case .emptyEntryKind: "Entry kind must be a non-empty string"
        }
    }
}
