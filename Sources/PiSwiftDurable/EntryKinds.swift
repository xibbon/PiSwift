/// An open entry-kind token. Data is a compile-time marker; the stored kind remains a string.
public struct EntryKind<Data>: Sendable, Equatable {
    /// The stored record or document kind.
    public let kind: String
    /// Rejects an empty kind, as upstream `defineEntry` does.
    public init(_ kind: String) throws {
        guard !kind.isEmpty else { throw DurableValueError.emptyEntryKind }
        self.kind = kind
    }
    private init(checked kind: String) { self.kind = kind }
    /// Orders values by their numeric record identifier.
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.kind.utf16.elementsEqual(rhs.kind.utf16)
    }
    /// Tests the exact code-unit kind of an optional record.
    public func matches(_ entry: EntryRecord?) -> Bool {
        guard let entry else { return false }
        return entry.kind.utf16.elementsEqual(kind.utf16)
    }
    fileprivate static func builtin(_ kind: String) -> Self { Self(checked: kind) }
}

/// User input. Its model contains user messages.
public let userEntry = EntryKind<Never>.builtin("pi.user")
/// Provider result. Its model contains assistant messages.
public let assistantEntry = EntryKind<Never>.builtin("pi.assistant")
/// Prompt and tool change. Its model contains system messages.
public let systemEntry = EntryKind<Never>.builtin("pi.system")
/// Context reset. A plain reset has no model; a handoff can have a user message.
public let resetEntry = EntryKind<Never>.builtin("pi.reset")
