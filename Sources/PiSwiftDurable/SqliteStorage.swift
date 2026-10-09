import PiSwiftChord

/// SQLite storage with the upstream schema. Each operation runs without suspension.
/// The actor owns the database and closes it when `close(context:)` is called.
public actor SqliteStorage: DurableStorage {
    let db: any SqliteExecutor
    var nextId: Int64
    var closed = false
    var closeError: (any Error)?

    /// Opens a file, or `:memory:`, and applies pending schema migrations.
    public static func open(path: String) async throws -> SqliteStorage {
        try SqliteStorage(executor: AppleSqliteDatabase(path: path))
    }

    static func open(executor: sending any SqliteExecutor) async throws -> SqliteStorage {
        try SqliteStorage(executor: executor)
    }

    /// Transfers ownership of a synchronous executor. Used for fault injection in tests.
    init(executor: sending any SqliteExecutor) throws {
        do {
            try applySqliteMigrations(executor)
            guard let row = try executor.get("SELECT next_id, next_seq FROM durable_metadata WHERE singleton = 1"),
                  let value = Int64(try row.sqliteText("next_id")) else { throw SqliteStorageFailure.metadataMissing }
            db = executor; nextId = value
        } catch {
            try? executor.close()
            throw error
        }
    }

    public func mintId<Kind: DurableIDKind>() throws -> DurableID<Kind> {
        try assertOpen()
        guard nextId <= DurableID<Kind>.maximumRawValue else { throw DurableStorageError.idSpaceExhausted }
        let result = try DurableID<Kind>(nextId); nextId += 1; return result
    }

    public func conversation(_ id: ConversationID, context: Context) throws -> ConversationRecord? {
        try assertOpen(); return try readRecord("conversations", id: id.rawValue)
    }
    public func task(_ id: TaskID, context: Context) throws -> TaskRecord? {
        try assertOpen(); return try readRecord("tasks", id: id.rawValue)
    }
    public func submission(_ id: SubmissionID, context: Context) throws -> SubmissionRecord? {
        try assertOpen(); return try readRecord("submissions", id: id.rawValue)
    }
    public func submissionByRequest(_ conversationId: ConversationID, requestId: String, context: Context) throws -> SubmissionRecord? {
        try assertOpen()
        return try db.get("SELECT record FROM submissions WHERE conversation_id = ? AND request_id = ?", [.integer(conversationId.rawValue), try indexed(requestId)]).map { try decodeRecord($0) }
    }
    public func scanConversations(_ query: ConversationQuery, limit: Int, cursor: Cursor?, context: Context) throws -> Page<ConversationRecord, Cursor> {
        try assertOpen()
        let start = try scanStart(requested: query.order, cursor: cursor, fallback: .ascending)
        var scan = SqliteScan(start)
        scan.add("owner_conversation_id", query.ownerConversationId.map { .integer($0.rawValue) })
        scan.add("owner_task_id", query.ownerTaskId.map { .integer($0.rawValue) })
        return try scanRecords("conversations", scan: scan, limit: limit, id: { $0.id.rawValue })
    }
    public func scanTasks(_ query: TaskQuery, limit: Int, cursor: Cursor?, context: Context) throws -> Page<TaskRecord, Cursor> {
        try assertOpen()
        var scan = SqliteScan(try scanStart(requested: query.order, cursor: cursor, fallback: .ascending))
        scan.add("conversation_id", query.conversationId.map { .integer($0.rawValue) })
        scan.add("kind", try query.kind.map(indexed))
        scan.add("status", query.status.map { .text($0.rawValue) })
        scan.add("abort_requested", query.abortRequested.map { .integer($0 ? 1 : 0) })
        scan.add("background", query.background.map { .integer($0 ? 1 : 0) })
        return try scanRecords("tasks", scan: scan, limit: limit, id: { $0.id.rawValue })
    }
    public func scanSubmissions(_ query: SubmissionQuery, limit: Int, cursor: Cursor?, context: Context) throws -> Page<SubmissionRecord, Cursor> {
        try assertOpen()
        var scan = SqliteScan(try scanStart(requested: query.order, cursor: cursor, fallback: .ascending))
        scan.add("conversation_id", query.conversationId.map { .integer($0.rawValue) })
        scan.add("status", query.status.map { .text($0.rawValue) })
        return try scanRecords("submissions", scan: scan, limit: limit, id: { $0.id.rawValue })
    }
    public func entry(_ id: EntryID, context: Context) throws -> EntryLookup? {
        try assertOpen(); return try readEntry(id)
    }
    public func entry(_ conversationId: ConversationID, id: EntryID, context: Context) throws -> EntryLookup? {
        try assertOpen()
        var conversation = try requireConversation(conversationId)
        guard let lookup = try readEntry(id) else { return nil }
        var upper = Seq.maximumRawValue
        while conversation.id != lookup.entry.conversationId {
            guard let parent = conversation.parent else { return nil }
            upper = min(upper, parent.at.rawValue)
            conversation = try requireConversation(parent.conversationId)
        }
        return id.rawValue <= upper ? lookup : nil
    }
    public func findLatestHeadMarker(_ conversationId: ConversationID, atOrBeforeEntryId: EntryID?, context: Context) throws -> EntryRecord? {
        try assertOpen()
        var conversation = try requireConversation(conversationId)
        var upper = atOrBeforeEntryId?.rawValue ?? Seq.maximumRawValue
        while true {
            if let row = try db.get("SELECT record FROM entries WHERE conversation_id = ? AND head IS NOT NULL AND id <= ? ORDER BY id DESC LIMIT 1", [.integer(conversation.id.rawValue), .integer(upper)]) { return try decodeRecord(row) }
            guard let parent = conversation.parent else { return nil }
            upper = min(upper, parent.at.rawValue); conversation = try requireConversation(parent.conversationId)
        }
    }
    public func scanEntries(_ query: EntryQuery, limit: Int, cursor: Cursor?, context: Context) throws -> Page<EntryRecord, Cursor> {
        try assertOpen()
        let start = try scanStart(requested: query.order, cursor: cursor, fallback: .descending)
        var upper = query.maxEntryId?.rawValue
        var conversation = try requireConversation(query.conversationId)
        var values: [EntryRecord] = []
        if start.order == .descending {
            if let after = start.after { upper = min(upper ?? Seq.maximumRawValue, after - 1) }
            while true {
                values += try entrySegment(conversation.id, lower: query.minEntryId?.rawValue, upper: upper, order: .descending, count: limit + 1 - values.count)
                if values.count > limit { break }
                guard let parent = conversation.parent else { break }
                upper = min(upper ?? parent.at.rawValue, parent.at.rawValue)
                if let minimum = query.minEntryId, upper! < minimum.rawValue { break }
                conversation = try requireConversation(parent.conversationId)
            }
        } else {
            var segments: [(ConversationID, Int64?)] = []
            while true {
                segments.append((conversation.id, upper))
                guard let parent = conversation.parent else { break }
                upper = min(upper ?? parent.at.rawValue, parent.at.rawValue)
                if let minimum = query.minEntryId, upper! < minimum.rawValue { break }
                conversation = try requireConversation(parent.conversationId)
            }
            var lower = query.minEntryId?.rawValue
            if let after = start.after { lower = max(lower ?? after + 1, after + 1) }
            for (id, cap) in segments.reversed() {
                values += try entrySegment(id, lower: lower, upper: cap, order: .ascending, count: limit + 1 - values.count)
                if values.count > limit { break }
            }
        }
        return sqlitePage(values, limit: limit, order: start.order, id: { $0.id.rawValue })
    }
    func entrySegment(_ id: ConversationID, lower: Int64?, upper: Int64?, order: ScanOrder, count: Int) throws -> [EntryRecord] {
        var clauses = ["conversation_id = ?"]
        var params: [SqliteValue] = [.integer(id.rawValue)]
        if let lower { clauses.append("id >= ?"); params.append(.integer(lower)) }
        if let upper { clauses.append("id <= ?"); params.append(.integer(upper)) }
        params.append(.integer(Int64(max(0, count))))
        return try db.all("SELECT record FROM entries WHERE \(clauses.joined(separator: " AND ")) ORDER BY id \(order == .ascending ? "ASC" : "DESC") LIMIT ?", params).map { try decodeRecord($0) }
    }

    public func findDocument(_ address: DocumentAddress, at: DocumentPoint, context: Context) throws -> DocumentRecord? {
        try assertOpen()
        var params = try addressValues(kind: address.kind, scope: address.scope, key: address.key)
        let lifetime = appendLifetime(at, params: &params)
        return try db.get("SELECT record FROM documents WHERE kind = ? AND scope_kind = ? AND owner_id = ? AND family = ? AND key_value = ? AND \(lifetime) ORDER BY created_at DESC LIMIT 1", params).map { try decodeRecord($0) }
    }
    public func document(_ id: DocumentID, at: DocumentPoint, context: Context) throws -> StoredDocument? {
        try assertOpen()
        return try db.transaction { try materialize($0, id: id, at: at) }
    }
    public func scanDocuments(_ query: DocumentQuery, limit: Int, cursor: Cursor?, context: Context) throws -> Page<DocumentRecord, Cursor> {
        try assertOpen()
        let after: Int64
        if let value = cursor?["after"] {
            guard let number = value.numberValue, let integer = Int64(exactly: number), integer >= -Seq.maximumRawValue, integer <= Seq.maximumRawValue else { throw DurableStorageError.invalidCursor }
            after = integer
        } else { after = -1 }
        var params = scopeValues(query.scope) + [.integer(after)]
        var clauses = ["scope_kind = ?", "owner_id = ?", "id > ?"]
        if let kind = query.kind { clauses.append("kind = ?"); params.append(try indexed(kind)) }
        clauses.append(appendLifetime(query.at, params: &params)); params.append(.integer(Int64(max(0, limit + 1))))
        let rows = try db.all("SELECT record FROM documents WHERE \(clauses.joined(separator: " AND ")) ORDER BY id LIMIT ?", params)
        let values: [DocumentRecord] = try rows.map { try decodeRecord($0) }
        return sqlitePage(values, limit: limit, order: .ascending, id: { $0.id.rawValue })
    }
    public func close(context: Context) throws {
        if closed {
            if let closeError { throw closeError }
            return
        }
        closed = true
        do { try db.close() }
        catch { closeError = error; throw error }
    }
    func assertOpen() throws { if closed { throw DurableStorageError.closed(backend: "SqliteStorage") } }
    func readRecord<T: Decodable>(_ table: String, id: Int64) throws -> T? {
        try db.get("SELECT record FROM \(table) WHERE id = ?", [.integer(id)]).map { try decodeRecord($0) }
    }
    func requireConversation(_ id: ConversationID) throws -> ConversationRecord {
        guard let record: ConversationRecord = try readRecord("conversations", id: id.rawValue) else { throw DurableStorageError.unknownConversation(id) }
        return record
    }
    func readEntry(_ id: EntryID) throws -> EntryLookup? {
        try db.get("SELECT record, commit_seq FROM entries WHERE id = ?", [.integer(id.rawValue)]).map { EntryLookup(entry: try decodeRecord($0), commitSeq: try Seq($0.sqliteInteger("commit_seq"))) }
    }
    func scanRecords<T: Sendable & Equatable & Codable>(_ table: String, scan: SqliteScan, limit: Int, id: (T) -> Int64) throws -> Page<T, Cursor> {
        let rows = try db.all("SELECT record FROM \(table) WHERE \(scan.clauses.joined(separator: " AND ")) ORDER BY id \(scan.order == .ascending ? "ASC" : "DESC") LIMIT ?", scan.params + [.integer(Int64(max(0, limit + 1)))])
        return sqlitePage(try rows.map { try decodeRecord($0) }, limit: limit, order: scan.order, id: id)
    }
    func materialize(_ executor: any SqliteExecutor, id: DocumentID, at: DocumentPoint) throws -> StoredDocument? {
        guard let row = try executor.get("SELECT record FROM documents WHERE id = ?", [.integer(id.rawValue)]) else { return nil }
        let record: DocumentRecord = try decodeRecord(row)
        if case .sequence = at, record.memoryCurrentOnly { throw DurableStorageError.documentDoesNotRetainHistory(id) }
        guard record.memoryAlive(at) else { return nil }
        let upper: Int64 = if case .sequence(let seq) = at { seq.rawValue } else { Seq.maximumRawValue }
        guard let base = try executor.get("SELECT seq, kind, version, content FROM document_revisions WHERE document_id = ? AND kind = 'base' AND seq <= ? ORDER BY seq DESC LIMIT 1", [.integer(id.rawValue), .integer(upper)]) else { throw DurableStorageError.documentMissingBase(id) }
        let version = try base.sqliteInteger("version")
        let tail = try executor.all("SELECT seq, kind, version, content FROM document_revisions WHERE document_id = ? AND seq > ? AND seq <= ? ORDER BY seq", [.integer(id.rawValue), .integer(try base.sqliteInteger("seq")), .integer(upper)])
        let batches: [[Delta.Op]] = try tail.map {
            guard try $0.sqliteText("kind") == "delta", try $0.sqliteInteger("version") == version else { throw DurableStorageError.documentVersionBoundaryWithoutBase(id) }
            return try JSONValue(jsonText: $0.sqliteText("content")).decode([Delta.Op].self)
        }
        let baseValue = try JSONValue(jsonText: base.sqliteText("content"))
        let replayed = try Delta.applyImmutableBatches(baseValue, batches)
        return StoredDocument(record: record, version: Int(version), value: try (replayed ?? .null).decode(JSONObject.self), deltasSinceBase: tail.count)
    }
}

struct SqliteScan {
    var clauses: [String]
    var params: [SqliteValue]
    let order: ScanOrder
    init(_ start: ScanStart) {
        order = start.order
        clauses = [order == .ascending ? "id > ?" : "id < ?"]
        params = [.integer(start.after ?? (order == .ascending ? -1 : Seq.maximumRawValue))]
    }
    mutating func add(_ column: String, _ value: SqliteValue?) {
        if let value { clauses.append("\(column) = ?"); params.append(value) }
    }
}
func sqlitePage<T: Sendable & Equatable & Codable>(_ values: [T], limit: Int, order: ScanOrder, id: (T) -> Int64) -> Page<T, Cursor> {
    let items = Array(values.prefix(max(0, limit)))
    return Page(items: items, next: values.count > limit && !items.isEmpty ? ["after": .number(Double(id(items.last!))), "order": .string(order.rawValue)] : nil)
}
func indexed(_ value: String) throws -> SqliteValue { .text(try JSONValue.string(value).jsonText()) }
func sqliteJSON<T: Encodable>(_ value: T) throws -> SqliteValue { .text(try JSONValue(encoding: value).jsonText()) }
func decodeRecord<T: Decodable>(_ row: SqliteRow) throws -> T { try JSONValue(jsonText: row.sqliteText("record")).decode(T.self) }
func scopeValues(_ scope: DocumentScope) -> [SqliteValue] {
    switch scope {
    case .session: [.text("session"), .integer(0)]
    case .conversation(let id, _): [.text("conversation"), .integer(id.rawValue)]
    case .task(let id, _): [.text("task"), .integer(id.rawValue)]
    }
}
func addressValues(kind: String, scope: DocumentScope, key: String?) throws -> [SqliteValue] {
    [try indexed(kind)] + scopeValues(scope) + [.integer(key == nil ? 0 : 1), try indexed(key ?? "")]
}
func appendLifetime(_ at: DocumentPoint, params: inout [SqliteValue]) -> String {
    switch at {
    case .current: return "retired_at IS NULL"
    case .sequence(let seq): params += [.integer(seq.rawValue), .integer(seq.rawValue)]; return "created_at <= ? AND (retired_at IS NULL OR retired_at > ?)"
    }
}
enum SqliteStorageFailure: Error, CustomStringConvertible {
    case metadataMissing
    case invalidColumn(String)
    var description: String { switch self { case .metadataMissing: "Durable SQLite metadata is missing"; case .invalidColumn(let name): "Invalid SQLite column: \(name)" } }
}
extension SqliteRow {
    func sqliteText(_ key: String) throws -> String {
        guard case .text(let value) = self[key] else { throw SqliteStorageFailure.invalidColumn(key) }; return value
    }
    func sqliteInteger(_ key: String) throws -> Int64 {
        guard case .integer(let value) = self[key] else { throw SqliteStorageFailure.invalidColumn(key) }; return value
    }
}
