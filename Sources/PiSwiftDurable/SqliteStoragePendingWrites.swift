import PiSwiftChord

/// Net changes from accepted batches, grouped by table until a flush is required.
struct SqlitePendingWrites {
    var recordIds: [Int64: String] = [:]
    var conversations: [[SqliteValue]] = []
    var entries: [[SqliteValue]] = []
    var tasks: [Int64: [SqliteValue]] = [:]
    var submissions: [Int64: [SqliteValue]] = [:]
    var documents: [DocumentID: DocumentRecord] = [:]
    var cleared: Set<DocumentID> = []
    var revisions: [DocumentID: [[SqliteValue]]] = [:]

    mutating func add(_ writes: [StorageWrite], actions: [(DocumentID, SqliteDocumentAction)], seq: Seq, state: SqliteCommitState) throws {
        for write in writes {
            if let claim = sqliteWriteIdentity(write) { recordIds[claim.id] = claim.table }
            switch write {
            case .conversation(let value, _):
                conversations.append([.integer(value.id.rawValue), value.owner.map { .integer($0.conversationId.rawValue) } ?? .null, value.owner.map { .integer($0.taskId.rawValue) } ?? .null, try sqliteJSON(value)])
            case .entry(let value, _):
                entries.append([.integer(value.id.rawValue), .integer(value.conversationId.rawValue), value.head.map { .integer($0.rawValue) } ?? .null, .integer(seq.rawValue), try sqliteJSON(value)])
            case .task(let value, _):
                tasks[value.id.rawValue] = [.integer(value.id.rawValue), .integer(value.conversationId.rawValue), try indexed(value.kind), .text(value.state.status), .integer(value.abortRequested ? 1 : 0), .integer(value.background ? 1 : 0), try sqliteJSON(value)]
            case .submission(let value, _):
                submissions[value.id.rawValue] = [.integer(value.id.rawValue), .integer(value.conversationId.rawValue), try value.requestId.map(indexed) ?? .null, .text(value.status), try sqliteJSON(value)]
            default: break
            }
        }
        for (id, action) in actions {
            let record = state.documents[id]!
            if action.create != nil || action.retire { documents[id] = record }
            if let content = action.content {
                let kind: String, encoded: SqliteValue
                switch content {
                case .base(_, let value, _):
                    if record.memoryCurrentOnly { clear(id) }
                    kind = "base"; encoded = try sqliteJSON(value)
                case .delta(_, let ops, _): kind = "delta"; encoded = try sqliteJSON(ops)
                }
                revisions[id, default: []].append([.integer(id.rawValue), .integer(seq.rawValue), .text(kind), .integer(Int64(content.memoryVersion)), encoded])
            }
            if action.retire, record.memoryCurrentOnly { clear(id) }
        }
    }
    mutating func clear(_ id: DocumentID) { cleared.insert(id); revisions[id] = nil }

    mutating func flush(_ executor: any SqliteExecutor, tables: SqliteSchema.Tables) throws {
        try sqliteInsertRows(executor, table: tables.recordIds, columns: ["id", "record_type"], rows: recordIds.sorted { $0.key < $1.key }.map { [.integer($0.key), .text($0.value)] }, conflict: "ON CONFLICT(id) DO NOTHING")
        try sqliteInsertRows(executor, table: tables.conversations, columns: ["id", "owner_conversation_id", "owner_task_id", "record"], rows: conversations)
        try sqliteInsertRows(executor, table: tables.entries, columns: ["id", "conversation_id", "head", "commit_seq", "record"], rows: entries)
        try sqliteInsertRows(executor, table: tables.tasks, columns: ["id", "conversation_id", "kind", "status", "abort_requested", "background", "record"], rows: tasks.sorted { $0.key < $1.key }.map(\.value), conflict: "ON CONFLICT(id) DO UPDATE SET conversation_id = excluded.conversation_id, kind = excluded.kind, status = excluded.status, abort_requested = excluded.abort_requested, background = excluded.background, record = excluded.record")
        try sqliteInsertRows(executor, table: tables.submissions, columns: ["id", "conversation_id", "request_id", "status", "record"], rows: submissions.sorted { $0.key < $1.key }.map(\.value), conflict: "ON CONFLICT(id) DO UPDATE SET conversation_id = excluded.conversation_id, request_id = excluded.request_id, status = excluded.status, record = excluded.record")
        let rows: [[SqliteValue]] = try documents.sorted { $0.key < $1.key }.map { id, record in
            let parts = try addressValues(kind: record.kind, scope: record.scope, key: record.key)
            return [.integer(id.rawValue), parts[0], parts[3], parts[4], parts[1], parts[2], .integer(record.createdAt.rawValue), record.retiredAt.map { .integer($0.rawValue) } ?? .null, try sqliteJSON(record)]
        }
        try sqliteInsertRows(executor, table: tables.documents, columns: ["id", "kind", "family", "key_value", "scope_kind", "owner_id", "created_at", "retired_at", "record"], rows: rows, conflict: "ON CONFLICT(id) DO UPDATE SET retired_at = excluded.retired_at, record = excluded.record")
        try sqliteRunForEach(executor, sql: "DELETE FROM \(tables.documentRevisions) WHERE document_id IN (SELECT value FROM json_each(?))", values: cleared.sorted().map { .number(Double($0.rawValue)) })
        try sqliteInsertRows(executor, table: tables.documentRevisions, columns: ["document_id", "seq", "kind", "version", "content"], rows: revisions.sorted { $0.key < $1.key }.flatMap(\.value))
        self = Self()
    }
}
