import PiSwiftChord

struct SqliteDocumentAction {
    var create: DocumentCreate?
    var copy: DocumentCopySource?
    var content: DocumentContent?
    var retire = false
}
extension SqliteStorage {
    /// Stores each batch in order. A refused batch leaves the accepted batches stored.
    public func commit(
        _ batches: [[StorageWrite]],
        receive: @Sendable (Int, Seq) -> Void,
        context: ChordContext
    ) async throws -> CommitResult {
        try assertOpen()
        var seqs: [Seq] = []
        var refused: (any Error & Sendable)?
        var candidate = nextId
        try db.transaction { executor in
            guard let metadata = try executor.get("SELECT next_id, next_seq FROM \(schema.tables.durableMetadata) WHERE singleton = 1"),
                  let persistedId = Int64(try metadata.sqliteText("next_id")) else { throw SqliteStorageFailure.metadataMissing }
            var next = try metadata.sqliteInteger("next_seq")
            var state = try SqliteCommitState.read(executor, tables: schema.tables, batches: batches)
            var pending = SqlitePendingWrites()
            for writes in batches {
                let actions: [(DocumentID, SqliteDocumentAction)]
                // Driver failures must reject the transaction, even if a driver uses a
                // Durable error type. Only checks made before writes can refuse a batch.
                let checked = SqliteCommitChecks(executor)
                do {
                    let prepared = try prepareDocumentActions(writes)
                    try state.check(writes, actions: prepared)
                    if prepared.contains(where: { $0.1.copy != nil }) {
                        // Copy materialization reads the database, so flush earlier batches first.
                        try pending.flush(checked, tables: schema.tables)
                    }
                    actions = try resolveDocumentCopies(checked, actions: prepared)
                } catch {
                    if checked.failed { throw error }
                    if (error as? DurableStorageError)?.isCommitRefusal == true || error is DocumentCopyFailure {
                        refused = error
                        break
                    }
                    throw error
                }
                let seq = try Seq(next)
                state.apply(writes, actions: actions, seq: seq)
                try pending.add(writes, actions: actions, seq: seq, state: state)
                seqs.append(seq)
                next += 1
                candidate = writes.compactMap(sqliteWriteIdentity).reduce(candidate) { max($0, $1.id + 1) }
            }
            try pending.flush(executor, tables: schema.tables)
            if !seqs.isEmpty {
                try executor.run("UPDATE \(schema.tables.durableMetadata) SET next_id = ?, next_seq = ? WHERE singleton = 1", [.text(String(max(persistedId, candidate))), .integer(next)])
            }
        }
        nextId = max(nextId, candidate)
        for (index, seq) in seqs.enumerated() { receive(index, seq) }
        return CommitResult(stored: seqs.count, refused: refused)
    }

    /// Resolves copies before any write in the batch can change their source.
    func resolveDocumentCopies(
        _ executor: any SqliteExecutor,
        actions: [(DocumentID, SqliteDocumentAction)]
    ) throws -> [(DocumentID, SqliteDocumentAction)] {
        let changed = Set(actions.map { $0.0 })
        return try actions.map { id, original in
            var action = original
            guard let source = action.copy else { return (id, action) }
            do {
                guard !changed.contains(source.id) else { throw DurableStorageError.forkSourceChangedInCopyBatch(source.id) }
                guard let stored = try materialize(executor, id: source.id, at: source.at) else { throw DurableStorageError.forkSourceCannotBeRead(source.id) }
                let create = action.create!
                guard case .conversation = stored.record.scope, case .conversation = create.scope,
                      MemoryStringKey(stored.record.kind) == MemoryStringKey(create.kind),
                      stored.record.key.map(MemoryStringKey.init) == create.key.map(MemoryStringKey.init),
                      stored.record.history == create.history, stored.record.fork == create.fork else { throw DurableStorageError.forkSourceDoesNotMatch(source.id) }
                action.content = .base(version: stored.version, value: stored.value)
                action.copy = nil
                return (id, action)
            } catch {
                throw DocumentCopyFailure(message: "Document copy \(id.rawValue) was rejected", cause: error)
            }
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
