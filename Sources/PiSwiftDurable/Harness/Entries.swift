import PiSwiftChord

/// Structured tool remarks. The tool task also appends their text to model content.
public struct ToolResultEntryData: Sendable, Equatable, Codable {
    /// The diagnostics reported by this tool call.
    public let diagnostics: [ToolDiagnostic]
    /// Stores the diagnostics attached to a tool result entry.
    public init(diagnostics: [ToolDiagnostic]) { self.diagnostics = diagnostics }
}

/// Reason for a compaction summary entry.
public struct CompactionEntryData: Sendable, Equatable, Codable {
    /// The saved cause of cancellation, unanswered input, or compaction.
    public let reason: CompactionReason
    /// Stores the trigger attached to a compaction summary entry.
    public init(reason: CompactionReason) { self.reason = reason }
}

/// The names are constants. Their construction cannot fail.
public let toolResultEntry: EntryKind<ToolResultEntryData> = {
    do { return try EntryKind("pi.tool-result") }
    catch { preconditionFailure("Invalid built-in entry kind") }
}()
/// The typed token for compaction entries stored by the harness.
public let compactionEntry: EntryKind<CompactionEntryData> = {
    do { return try EntryKind("pi.compaction") }
    catch { preconditionFailure("Invalid built-in entry kind") }
}()

extension EntryKind where Data: Decodable {
    /// Reads typed data only when the entry kind matches this token.
    public func data(from entry: EntryRecord) throws -> Data? {
        guard matches(entry) else { return nil }
        return try entry.data?.decode(Data.self)
    }
}
