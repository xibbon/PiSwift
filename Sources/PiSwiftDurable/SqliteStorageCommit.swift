import PiSwiftChord

struct SqliteDocumentAction {
    var create: DocumentCreate?
    var copy: DocumentCopySource?
    var content: DocumentContent?
    var retire = false
}
extension SqliteStorage {
    public func commit(_ writes: [StorageWrite], context: ChordContext) throws -> Seq {
        try assertOpen()
        let actions = try prepareDocumentActions(writes)
        let candidate = writes.compactMap(sqliteWriteIdentity).reduce(nextId) { max($0, $1.id + 1) }
        let seq = try db.transaction { executor in
            guard let metadata = try executor.get("SELECT next_id, next_seq FROM durable_metadata WHERE singleton = 1"),
                  let persistedId = Int64(try metadata.sqliteText("next_id")) else { throw SqliteStorageFailure.metadataMissing }
            let seq = try Seq(metadata.sqliteInteger("next_seq"))
            try checkGlobalIds(executor, writes: writes)
            try checkDocumentActions(executor, actions: actions)
            for write in writes { try applyTableWrite(executor, write: write, seq: seq) }
            try applyDocumentActions(executor, actions: actions, seq: seq)
            try executor.run("UPDATE durable_metadata SET next_id = ?, next_seq = ? WHERE singleton = 1", [.text(String(max(persistedId, candidate))), .integer(seq.rawValue + 1)])
            return seq
        }
        nextId = max(nextId, candidate)
        return seq
    }
    func checkGlobalIds(_ executor: any SqliteExecutor, writes: [StorageWrite]) throws {
        var claimed: [Int64: String] = [:]
        for write in writes {
            guard let identity = sqliteWriteIdentity(write) else { continue }
            let (id, table) = identity
            let existing = try executor.get("SELECT record_type FROM record_ids WHERE id = ?", [.integer(id)]).map { try $0.sqliteText("record_type") }
            let earlier = claimed[id]
            if table == "conversation" || table == "entry" || table == "document" {
                if let existing { throw DurableStorageError.idAlreadyOwned(id: id, recordType: existing) }
                if earlier != nil { throw DurableStorageError.idWrittenMoreThanOnce(id) }
            } else {
                if let existing, existing != table { throw DurableStorageError.idAlreadyOwned(id: id, recordType: existing) }
                if let earlier, earlier != table { throw DurableStorageError.idWrittenAsTwoRecordTypes(id) }
            }
            claimed[id] = table
        }
    }
    func prepareDocumentActions(_ writes: [StorageWrite]) throws -> [(DocumentID, SqliteDocumentAction)] {
        var ids: [DocumentID] = []
        var actions: [DocumentID: SqliteDocumentAction] = [:]
        for write in writes {
            let id: DocumentID
            switch write {
            case .documentCreate(let record, _, _), .documentCopy(let record, _, _): id = record.id
            case .documentChange(let value, _, _), .documentRetire(let value, _): id = value
            default: continue
            }
            if actions[id] == nil { ids.append(id) }
            var action = actions[id] ?? SqliteDocumentAction()
            switch write {
            case .documentCreate(let record, let content, _):
                guard action.create == nil, action.content == nil, action.copy == nil else { throw DurableStorageError.documentMultipleContentCommands(id) }
                action.create = record; action.content = .base(version: content.version, value: content.value, extensions: content.extensionFields)
            case .documentCopy(let record, let source, _):
                guard action.create == nil, action.content == nil, action.copy == nil else { throw DurableStorageError.documentMultipleContentCommands(id) }
                action.create = record; action.copy = source
            case .documentChange(_, let content, _):
                guard action.content == nil, action.copy == nil else { throw DurableStorageError.documentMultipleContentCommands(id) }
                action.content = content
            case .documentRetire:
                guard !action.retire else { throw DurableStorageError.documentRetiredMoreThanOnce(id) }
                action.retire = true
            default: break
            }
            actions[id] = action
        }
        return ids.map { ($0, actions[$0]!) }
    }
    func checkDocumentActions(_ executor: any SqliteExecutor, actions: [(DocumentID, SqliteDocumentAction)]) throws {
        let changed = Set(actions.map { $0.0 })
        var liveCounts: [MemoryAddressKey: Int] = [:]
        for (id, action) in actions {
            if let source = action.copy, changed.contains(source.id) { throw StorageRejected("Document copy \(id.rawValue) source is changed in the copy batch") }
            let existing: DocumentRecord? = try executor.get("SELECT record FROM documents WHERE id = ?", [.integer(id.rawValue)]).map { try decodeRecord($0) }
            if action.create == nil, existing == nil { throw DurableStorageError.unknownDocument(id) }
            if action.create != nil, existing != nil { throw DurableStorageError.documentAlreadyExists(id) }
            if existing?.retiredAt != nil { throw DurableStorageError.documentRetired(id) }
            if case .delta(let version, _, _) = action.content {
                guard let previous = try executor.get("SELECT version FROM document_revisions WHERE document_id = ? ORDER BY seq DESC LIMIT 1", [.integer(id.rawValue)]) else { throw DurableStorageError.documentDeltaHasNoBase(id) }
                guard try previous.sqliteInteger("version") == Int64(version) else { throw DurableStorageError.documentVersionTransitionRequiresBase(id) }
            }
            let kind = action.create?.kind ?? existing!.kind
            let scope = action.create?.scope ?? existing!.scope
            let keyValue = action.create != nil ? action.create!.key : existing!.key
            let key = MemoryAddressKey(kind: kind, scope: scope, key: keyValue)
            var live: Int
            if let count = liveCounts[key] { live = count }
            else {
                let current = try executor.get("SELECT id FROM documents WHERE kind = ? AND scope_kind = ? AND owner_id = ? AND family = ? AND key_value = ? AND retired_at IS NULL LIMIT 1", addressValues(kind: kind, scope: scope, key: keyValue))
                live = current == nil ? 0 : 1
            }
            if action.retire, existing != nil { live -= 1 }
            if action.create != nil, !action.retire { live += 1 }
            liveCounts[key] = live
        }
        if liveCounts.values.contains(where: { $0 > 1 }) { throw DurableStorageError.documentAddressOccupied }
    }
    func claimId(_ executor: any SqliteExecutor, id: Int64, table: String) throws {
        try executor.run("INSERT OR IGNORE INTO record_ids (id, record_type) VALUES (?, ?)", [.integer(id), .text(table)])
    }
    func applyTableWrite(_ executor: any SqliteExecutor, write: StorageWrite, seq: Seq) throws {
        switch write {
        case .conversation(let value, _):
            try claimId(executor, id: value.id.rawValue, table: "conversation")
            try executor.run("INSERT INTO conversations (id, owner_conversation_id, owner_task_id, record) VALUES (?, ?, ?, ?)", [.integer(value.id.rawValue), value.owner.map { .integer($0.conversationId.rawValue) } ?? .null, value.owner.map { .integer($0.taskId.rawValue) } ?? .null, try sqliteJSON(value)])
        case .entry(let value, _):
            try claimId(executor, id: value.id.rawValue, table: "entry")
            try executor.run("INSERT INTO entries (id, conversation_id, head, commit_seq, record) VALUES (?, ?, ?, ?, ?)", [.integer(value.id.rawValue), .integer(value.conversationId.rawValue), value.head.map { .integer($0.rawValue) } ?? .null, .integer(seq.rawValue), try sqliteJSON(value)])
        case .task(let value, _):
            try claimId(executor, id: value.id.rawValue, table: "task")
            try executor.run("""
                INSERT INTO tasks (id, conversation_id, kind, status, abort_requested, background, record)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET conversation_id = excluded.conversation_id, kind = excluded.kind,
                status = excluded.status, abort_requested = excluded.abort_requested,
                background = excluded.background, record = excluded.record
                """, [.integer(value.id.rawValue), .integer(value.conversationId.rawValue), try indexed(value.kind), .text(value.state.status), .integer(value.abortRequested ? 1 : 0), .integer(value.background ? 1 : 0), try sqliteJSON(value)])
        case .submission(let value, _):
            try claimId(executor, id: value.id.rawValue, table: "submission")
            try executor.run("""
                INSERT INTO submissions (id, conversation_id, request_id, status, record) VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET conversation_id = excluded.conversation_id,
                request_id = excluded.request_id, status = excluded.status, record = excluded.record
                """, [.integer(value.id.rawValue), .integer(value.conversationId.rawValue), try value.requestId.map(indexed) ?? .null, .text(value.status), try sqliteJSON(value)])
        default: break
        }
    }
    func applyDocumentActions(_ executor: any SqliteExecutor, actions: [(DocumentID, SqliteDocumentAction)], seq: Seq) throws {
        for (id, action) in actions {
            var content = action.content
            if let source = action.copy {
                do {
                    guard let stored = try materialize(executor, id: source.id, at: source.at) else { throw DurableStorageError.forkSourceCannotBeRead(source.id) }
                    let create = action.create!
                    guard case .conversation = stored.record.scope, case .conversation = create.scope,
                          MemoryStringKey(stored.record.kind) == MemoryStringKey(create.kind),
                          stored.record.key.map(MemoryStringKey.init) == create.key.map(MemoryStringKey.init),
                          stored.record.history == create.history, stored.record.fork == create.fork else { throw DurableStorageError.forkSourceDoesNotMatch(source.id) }
                    content = .base(version: stored.version, value: stored.value)
                } catch let error as StorageRejected { throw error }
                catch { throw StorageRejected("Document copy \(id.rawValue) was rejected") }
            }
            var record: DocumentRecord
            if let create = action.create {
                record = DocumentRecord(id: id, kind: create.kind, scope: create.scope, createdAt: seq, key: create.key, retiredAt: action.retire ? seq : nil, history: create.history, fork: create.fork, extensionFields: create.extensionFields)
                let parts = try addressValues(kind: record.kind, scope: record.scope, key: record.key)
                try claimId(executor, id: id.rawValue, table: "document")
                try executor.run("""
                    INSERT INTO documents
                    (id, kind, family, key_value, scope_kind, owner_id, created_at, retired_at, record)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """, [.integer(id.rawValue), parts[0], parts[3], parts[4], parts[1], parts[2], .integer(seq.rawValue), action.retire ? .integer(seq.rawValue) : .null, try sqliteJSON(record)])
            } else {
                guard let row = try executor.get("SELECT record FROM documents WHERE id = ?", [.integer(id.rawValue)]) else { throw DurableStorageError.unknownDocument(id) }
                record = try decodeRecord(row)
            }
            if let content {
                let kind: String
                let encoded: SqliteValue
                switch content {
                case .base(_, let value, _):
                    kind = "base"; encoded = try sqliteJSON(value)
                    if record.memoryCurrentOnly { try executor.run("DELETE FROM document_revisions WHERE document_id = ?", [.integer(id.rawValue)]) }
                case .delta(_, let ops, _): kind = "delta"; encoded = try sqliteJSON(ops)
                }
                try executor.run("INSERT INTO document_revisions (document_id, seq, kind, version, content) VALUES (?, ?, ?, ?, ?)", [.integer(id.rawValue), .integer(seq.rawValue), .text(kind), .integer(Int64(content.memoryVersion)), encoded])
            }
            if action.retire {
                if action.create == nil {
                    record = DocumentRecord(id: record.id, kind: record.kind, scope: record.scope, createdAt: record.createdAt, key: record.key, retiredAt: seq, history: record.history, fork: record.fork, extensionFields: record.extensionFields)
                    try executor.run("UPDATE documents SET retired_at = ?, record = ? WHERE id = ?", [.integer(seq.rawValue), try sqliteJSON(record), .integer(id.rawValue)])
                }
                if record.memoryCurrentOnly { try executor.run("DELETE FROM document_revisions WHERE document_id = ?", [.integer(id.rawValue)]) }
            }
        }
    }
}
func sqliteWriteIdentity(_ write: StorageWrite) -> (id: Int64, table: String)? {
    switch write {
    case .conversation(let value, _): (value.id.rawValue, "conversation")
    case .entry(let value, _): (value.id.rawValue, "entry")
    case .task(let value, _): (value.id.rawValue, "task")
    case .submission(let value, _): (value.id.rawValue, "submission")
    case .documentCreate(let record, _, _), .documentCopy(let record, _, _): (record.id.rawValue, "document")
    default: nil
    }
}
