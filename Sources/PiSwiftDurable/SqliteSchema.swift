import PiSwiftChord

/// Immutable names shared by migrations and storage queries.
/// Keep historical names when a later migration adds a new identifier.
internal struct SqliteSchema: Sendable {
    let tables: Tables
    let indexes: Indexes

    static let `default` = SqliteSchema(validatedPrefix: "")

    init(prefix: String?) throws {
        if let prefix {
            let bytes = prefix.utf8
            func isLetter(_ byte: UInt8) -> Bool { (65...90).contains(byte) || (97...122).contains(byte) }
            guard let first = bytes.first, isLetter(first) || first == 95,
                  bytes.allSatisfy({ isLetter($0) || (48...57).contains($0) || $0 == 95 }) else {
                throw SqliteSchemaPrefixError.invalid(try JSONValue.string(prefix).jsonText())
            }
            guard !prefix.lowercased().hasPrefix("sqlite_") else {
                throw SqliteSchemaPrefixError.reserved(try JSONValue.string(prefix).jsonText())
            }
        }
        self.init(validatedPrefix: prefix ?? "")
    }

    private init(validatedPrefix prefix: String) {
        tables = Tables(prefix: prefix)
        indexes = Indexes(prefix: prefix)
    }

    struct Tables: Sendable {
        let durableSchema: String
        let durableMetadata: String
        let recordIds: String
        let conversations: String
        let entries: String
        let tasks: String
        let submissions: String
        let documents: String
        let documentRevisions: String

        fileprivate init(prefix: String) {
            durableSchema = prefix + "durable_schema"
            durableMetadata = prefix + "durable_metadata"
            recordIds = prefix + "record_ids"
            conversations = prefix + "conversations"
            entries = prefix + "entries"
            tasks = prefix + "tasks"
            submissions = prefix + "submissions"
            documents = prefix + "documents"
            documentRevisions = prefix + "document_revisions"
        }
    }

    struct Indexes: Sendable {
        let conversationsByOwnerConversation: String
        let conversationsByOwnerTask: String
        let entriesByConversation: String
        let entryHeadsByConversation: String
        let tasksByStatus: String
        let tasksByConversation: String
        let tasksByKind: String
        let tasksByAbortRequested: String
        let tasksByBackground: String
        let submissionsByRequest: String
        let submissionsByConversation: String
        let submissionsByStatus: String
        let documentsByAddress: String
        let documentsByScope: String
        let documentsByScopeKind: String
        let documentRevisionsByKind: String

        fileprivate init(prefix: String) {
            conversationsByOwnerConversation = prefix + "conversations_by_owner_conversation"
            conversationsByOwnerTask = prefix + "conversations_by_owner_task"
            entriesByConversation = prefix + "entries_by_conversation"
            entryHeadsByConversation = prefix + "entry_heads_by_conversation"
            tasksByStatus = prefix + "tasks_by_status"
            tasksByConversation = prefix + "tasks_by_conversation"
            tasksByKind = prefix + "tasks_by_kind"
            tasksByAbortRequested = prefix + "tasks_by_abort_requested"
            tasksByBackground = prefix + "tasks_by_background"
            submissionsByRequest = prefix + "submissions_by_request"
            submissionsByConversation = prefix + "submissions_by_conversation"
            submissionsByStatus = prefix + "submissions_by_status"
            documentsByAddress = prefix + "documents_by_address"
            documentsByScope = prefix + "documents_by_scope"
            documentsByScopeKind = prefix + "documents_by_scope_kind"
            documentRevisionsByKind = prefix + "document_revisions_by_kind"
        }
    }
}

internal enum SqliteSchemaPrefixError: Error, CustomStringConvertible {
    case invalid(String)
    case reserved(String)

    var description: String {
        switch self {
        case .invalid(let json): "Invalid SQLite schema prefix \(json)"
        case .reserved(let json): "SQLite schema prefix \(json) is reserved"
        }
    }
}
