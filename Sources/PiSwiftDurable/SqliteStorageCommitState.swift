import PiSwiftChord

/// Stored check state for all batches, advanced only after a batch passes its checks.
struct SqliteCommitState {
    var recordIds: [Int64: String] = [:]
    var documents: [DocumentID: DocumentRecord] = [:]
    var versions: [DocumentID: Int64] = [:]
    var current: [MemoryAddressKey: DocumentID] = [:]

    static func read(_ executor: any SqliteExecutor, tables: SqliteSchema.Tables, batches: [[StorageWrite]]) throws -> Self {
        var state = Self()
        var ids: Set<Int64> = [], documentIds: Set<Int64> = [], deltaIds: Set<Int64> = []
        var addresses: [MemoryAddressKey: [SqliteValue]] = [:]
        for writes in batches {
            for write in writes {
                if let claim = sqliteWriteIdentity(write) { ids.insert(claim.id) }
                switch write {
                case .documentCreate(let record, _, _), .documentCopy(let record, _, _):
                    documentIds.insert(record.id.rawValue)
                    addresses[MemoryAddressKey(kind: record.kind, scope: record.scope, key: record.key)] = try addressValues(kind: record.kind, scope: record.scope, key: record.key)
                case .documentChange(let id, let content, _):
                    documentIds.insert(id.rawValue)
                    if case .delta = content { deltaIds.insert(id.rawValue) }
                case .documentRetire(let id, _): documentIds.insert(id.rawValue)
                default: break
                }
            }
        }
        func numbers(_ ids: Set<Int64>) -> [JSONValue] { ids.sorted().map { .number(Double($0)) } }
        for row in try sqliteReadRows(executor, sql: "SELECT id, record_type FROM \(tables.recordIds) WHERE id IN (SELECT value FROM json_each(?))", values: numbers(ids)) {
            state.recordIds[try row.sqliteInteger("id")] = try row.sqliteText("record_type")
        }
        for row in try sqliteReadRows(executor, sql: "SELECT record FROM \(tables.documents) WHERE id IN (SELECT value FROM json_each(?))", values: numbers(documentIds)) {
            let record: DocumentRecord = try decodeRecord(row)
            state.documents[record.id] = record
        }
        for row in try sqliteReadRows(executor, sql: "SELECT requested.value AS document_id, (SELECT version FROM \(tables.documentRevisions) WHERE document_id = requested.value ORDER BY seq DESC LIMIT 1) AS version FROM json_each(?) AS requested", values: numbers(deltaIds)) {
            if let version = row["version"]?.integerValue { state.versions[try DocumentID(row.sqliteInteger("document_id"))] = version }
        }
        let sql = """
            SELECT document.record FROM json_each(?) AS address JOIN \(tables.documents) AS document
            ON document.kind = json_extract(address.value, '$[0]') AND document.scope_kind = json_extract(address.value, '$[1]')
            AND document.owner_id = json_extract(address.value, '$[2]') AND document.family = json_extract(address.value, '$[3]')
            AND document.key_value = json_extract(address.value, '$[4]') WHERE document.retired_at IS NULL
            """
        for row in try sqliteReadRows(executor, sql: sql, values: addresses.values.map { .array($0.map(sqliteCellJSON)) }) {
            let record: DocumentRecord = try decodeRecord(row)
            state.current[MemoryAddressKey(kind: record.kind, scope: record.scope, key: record.key)] = record.id
        }
        return state
    }

    func check(_ writes: [StorageWrite], actions: [(DocumentID, SqliteDocumentAction)]) throws {
        var claimed: [Int64: String] = [:]
        for write in writes {
            guard let (id, table) = sqliteWriteIdentity(write) else { continue }
            let existing = recordIds[id], earlier = claimed[id]
            if table == "conversation" || table == "entry" || table == "document" {
                if let existing { throw DurableStorageError.idAlreadyOwned(id: id, recordType: existing) }
                if earlier != nil { throw DurableStorageError.idWrittenMoreThanOnce(id) }
            } else {
                if let existing, existing != table { throw DurableStorageError.idAlreadyOwned(id: id, recordType: existing) }
                if let earlier, earlier != table { throw DurableStorageError.idWrittenAsTwoRecordTypes(id) }
            }
            claimed[id] = table
        }
        let changed = Set(actions.map { $0.0 })
        var liveCounts: [MemoryAddressKey: Int] = [:]
        for (id, action) in actions {
            if let copy = action.copy, changed.contains(copy.id) {
                throw DocumentCopyFailure(message: "Document copy \(id.rawValue) source is changed in the copy batch", cause: DurableStorageError.forkSourceChangedInCopyBatch(copy.id))
            }
            let existing = documents[id]
            if action.create == nil, existing == nil { throw DurableStorageError.unknownDocument(id) }
            if action.create != nil, existing != nil { throw DurableStorageError.documentAlreadyExists(id) }
            if existing?.retiredAt != nil { throw DurableStorageError.documentRetired(id) }
            if case .delta(let version, _, _) = action.content {
                guard let previous = versions[id] else { throw DurableStorageError.documentDeltaHasNoBase(id) }
                guard previous == Int64(version) else { throw DurableStorageError.documentVersionTransitionRequiresBase(id) }
            }
            if action.create == nil, !action.retire { continue }
            let kind = action.create?.kind ?? existing!.kind
            let scope = action.create?.scope ?? existing!.scope
            let key = action.create != nil ? action.create!.key : existing!.key
            let address = MemoryAddressKey(kind: kind, scope: scope, key: key)
            var live = liveCounts[address] ?? (current[address] == nil ? 0 : 1)
            if action.retire, existing != nil { live -= 1 }
            if action.create != nil, !action.retire { live += 1 }
            liveCounts[address] = live
        }
        if liveCounts.values.contains(where: { $0 > 1 }) { throw DurableStorageError.documentAddressOccupied }
    }

    mutating func apply(_ writes: [StorageWrite], actions: [(DocumentID, SqliteDocumentAction)], seq: Seq) {
        for write in writes { if let claim = sqliteWriteIdentity(write) { recordIds[claim.id] = claim.table } }
        for (id, action) in actions {
            if let create = action.create {
                let record = DocumentRecord(id: id, kind: create.kind, scope: create.scope, createdAt: seq, key: create.key, retiredAt: action.retire ? seq : nil, history: create.history, fork: create.fork, extensionFields: create.extensionFields)
                documents[id] = record
                if !action.retire { current[MemoryAddressKey(kind: record.kind, scope: record.scope, key: record.key)] = id }
            } else if action.retire {
                let old = documents[id]!
                let record = DocumentRecord(id: old.id, kind: old.kind, scope: old.scope, createdAt: old.createdAt, key: old.key, retiredAt: seq, history: old.history, fork: old.fork, extensionFields: old.extensionFields)
                documents[id] = record
                let key = MemoryAddressKey(kind: record.kind, scope: record.scope, key: record.key)
                if current[key] == id { current[key] = nil }
            }
            if let content = action.content { versions[id] = Int64(content.memoryVersion) }
        }
    }
}
