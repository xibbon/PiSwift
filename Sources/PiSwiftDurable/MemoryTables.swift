import PiSwiftChord

/// Exact UTF-16 identity for storage indexes. Swift canonical equivalence does not apply.
struct MemoryStringKey: Hashable, Sendable {
    let units: [UInt16]
    init(_ value: String) { units = Array(value.utf16) }
}

struct MemoryScopeKey: Hashable, Sendable {
    let kind: Int
    let id: Int64?
    init(_ scope: DocumentScope) {
        switch scope {
        case .session: kind = 0; id = nil
        case .conversation(let value, _): kind = 1; id = value.rawValue
        case .task(let value, _): kind = 2; id = value.rawValue
        }
    }
}

struct MemoryAddressKey: Hashable, Sendable {
    let kind: MemoryStringKey
    let scope: MemoryScopeKey
    let key: MemoryStringKey?
    init(kind: String, scope: DocumentScope, key: String?) {
        self.kind = MemoryStringKey(kind); self.scope = MemoryScopeKey(scope)
        self.key = key.map(MemoryStringKey.init)
    }
    init(_ record: DocumentCreate) { self.init(kind: record.kind, scope: record.scope, key: record.key) }
    init(_ record: DocumentRecord) { self.init(kind: record.kind, scope: record.scope, key: record.key) }
    init(_ address: DocumentAddress) { self.init(kind: address.kind, scope: address.scope, key: address.key) }
}

struct MemoryRevision: Sendable {
    let content: DocumentContent
    let seq: Seq
}
struct MemoryDocument: Sendable {
    var record: DocumentRecord
    var revisions: [MemoryRevision]
}
struct MemoryDocumentAction: Sendable {
    var create: DocumentCreate?
    var content: DocumentContent?
    var retire = false
}
struct MemoryAddressIndex: Sendable {
    var ids: [DocumentID] = []
    var currentId: DocumentID?
}
struct MemoryCommitPlan: Sendable {
    let seq: Seq
    let writes: [StorageWrite]
    // Preserve the first command's order, as the upstream Map does.
    let actions: [(DocumentID, MemoryDocumentAction)]
}

/// Shared value storage for memory and persistence wrappers. Preparation has no side effects.
struct MemoryTables: Sendable {
    var recordTypes: [Int64: String] = [:]
    var conversations: [ConversationID: ConversationRecord] = [:]
    var conversationIds: [ConversationID] = []
    var conversationIdsByOwnerConversation: [ConversationID: [ConversationID]] = [:]
    var conversationIdsByOwnerTask: [TaskID: [ConversationID]] = [:]
    var entries: [EntryID: EntryRecord] = [:]
    var entryIds: [ConversationID: [EntryID]] = [:]
    var headEntryIds: [ConversationID: [EntryID]] = [:]
    var entryCommitSeqs: [EntryID: Seq] = [:]
    var tasks: [TaskID: TaskRecord] = [:]
    var taskIds: [TaskID] = []
    var taskIdsByStatus: [String: [TaskID]] = [:]
    var submissions: [SubmissionID: SubmissionRecord] = [:]
    var submissionIds: [SubmissionID] = []
    var submissionIdsByStatus: [String: [SubmissionID]] = [:]
    var submissionIdsByRequest: [ConversationID: [MemoryStringKey: SubmissionID]] = [:]
    var documents: [DocumentID: MemoryDocument] = [:]
    var documentAddresses: [MemoryAddressKey: MemoryAddressIndex] = [:]
    var documentIdsByScope: [MemoryScopeKey: [DocumentID]] = [:]
    var nextId: Int64 = 2
    var nextSeq: Int64 = 1

    func prepare(_ writes: [StorageWrite], seq: Seq) throws -> MemoryCommitPlan {
        guard seq.rawValue >= nextSeq else {
            throw DurableStorageError.commitSequenceDoesNotIncrease(seq.rawValue)
        }
        let resolved = try resolveCopies(writes)
        try checkGlobalIds(resolved)
        let actions = try documentActions(resolved)
        try checkDocumentActions(actions)
        return MemoryCommitPlan(seq: seq, writes: resolved, actions: actions)
    }

    private func resolveCopies(_ writes: [StorageWrite]) throws -> [StorageWrite] {
        var changed: Set<DocumentID> = []
        for write in writes {
            switch write {
            case .documentCreate(let record, _, _), .documentCopy(let record, _, _): changed.insert(record.id)
            case .documentChange(let id, _, _), .documentRetire(let id, _): changed.insert(id)
            default: break
            }
        }
        return try writes.map { write in
            guard case .documentCopy(let record, let source, _) = write else { return write }
            do {
                if changed.contains(source.id) { throw DurableStorageError.forkSourceChangedInCopyBatch(source.id) }
                guard let stored = try materialize(source.id, at: source.at) else {
                    throw DurableStorageError.forkSourceCannotBeRead(source.id)
                }
                guard case .conversation = stored.record.scope, case .conversation = record.scope,
                      MemoryStringKey(stored.record.kind) == MemoryStringKey(record.kind),
                      stored.record.key.map(MemoryStringKey.init) == record.key.map(MemoryStringKey.init),
                      stored.record.history == record.history, stored.record.fork == record.fork else {
                    throw DurableStorageError.forkSourceDoesNotMatch(source.id)
                }
                // Upstream builds a new command. Copy-command extension fields are not retained.
                return .documentCreate(record: record, content: DocumentBaseContent(version: stored.version, value: stored.value))
            } catch {
                throw StorageRejected("Document copy \(record.id.rawValue) was rejected")
            }
        }
    }

    private func checkGlobalIds(_ writes: [StorageWrite]) throws {
        var claimed: [Int64: String] = [:]
        for write in writes {
            let id: Int64
            let table: String
            switch write {
            case .conversation(let value, _): id = value.id.rawValue; table = "conversation"
            case .entry(let value, _): id = value.id.rawValue; table = "entry"
            case .task(let value, _): id = value.id.rawValue; table = "task"
            case .submission(let value, _): id = value.id.rawValue; table = "submission"
            case .documentCreate(let record, _, _), .documentCopy(let record, _, _): id = record.id.rawValue; table = "document"
            default: continue
            }
            let existing = recordTypes[id]
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

    private func documentActions(_ writes: [StorageWrite]) throws -> [(DocumentID, MemoryDocumentAction)] {
        var actions: [DocumentID: MemoryDocumentAction] = [:]
        var ids: [DocumentID] = []
        for write in writes {
            let id: DocumentID
            switch write {
            case .documentCreate(let record, _, _): id = record.id
            case .documentChange(let value, _, _), .documentRetire(let value, _): id = value
            default: continue
            }
            if actions[id] == nil { ids.append(id) }
            var action = actions[id] ?? MemoryDocumentAction()
            switch write {
            case .documentCreate(let record, let content, _):
                guard action.create == nil, action.content == nil else { throw DurableStorageError.documentMultipleContentCommands(id) }
                action.create = record
                action.content = .base(version: content.version, value: content.value, extensions: content.extensionFields)
            case .documentChange(_, let content, _):
                guard action.content == nil else { throw DurableStorageError.documentMultipleContentCommands(id) }
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

    private func checkDocumentActions(_ actions: [(DocumentID, MemoryDocumentAction)]) throws {
        var liveCounts: [MemoryAddressKey: Int] = [:]
        for (id, action) in actions {
            let existing = documents[id]
            if action.create == nil, existing == nil { throw DurableStorageError.unknownDocument(id) }
            if action.create != nil, existing != nil { throw DurableStorageError.documentAlreadyExists(id) }
            if existing?.record.retiredAt != nil { throw DurableStorageError.documentRetired(id) }
            if case .delta(let version, _, _) = action.content {
                guard let previous = existing?.revisions.last else { throw DurableStorageError.documentDeltaHasNoBase(id) }
                guard previous.content.memoryVersion == version else { throw DurableStorageError.documentVersionTransitionRequiresBase(id) }
            }
            let key = action.create.map(MemoryAddressKey.init) ?? MemoryAddressKey(existing!.record)
            let current = documentAddresses[key]?.currentId
            var live = liveCounts[key] ?? (current == nil ? 0 : 1)
            if action.retire, current == id { live -= 1 }
            if action.create != nil, !action.retire { live += 1 }
            liveCounts[key] = live
        }
        if liveCounts.values.contains(where: { $0 > 1 }) { throw DurableStorageError.documentAddressOccupied }
    }

    /// Applies only a prepared plan. All validation is complete before this call.
    mutating func apply(_ plan: MemoryCommitPlan) {
        for write in plan.writes {
            switch write {
            case .conversation(let value, _):
                recordTypes[value.id.rawValue] = "conversation"; conversations[value.id] = value
                memoryInsert(&conversationIds, value.id)
                if let owner = value.owner {
                    memoryInsert(&conversationIdsByOwnerConversation[owner.conversationId, default: []], value.id)
                    memoryInsert(&conversationIdsByOwnerTask[owner.taskId, default: []], value.id)
                }
                nextId = max(nextId, value.id.rawValue + 1)
            case .entry(let value, _):
                recordTypes[value.id.rawValue] = "entry"; entries[value.id] = value; entryCommitSeqs[value.id] = plan.seq
                memoryInsert(&entryIds[value.conversationId, default: []], value.id)
                if value.head != nil { memoryInsert(&headEntryIds[value.conversationId, default: []], value.id) }
                nextId = max(nextId, value.id.rawValue + 1)
            case .task(let value, _):
                recordTypes[value.id.rawValue] = "task"
                if let previous = tasks[value.id] {
                    if previous.state.status != value.state.status {
                        taskIdsByStatus[previous.state.status]?.removeAll { $0 == value.id }
                        memoryInsert(&taskIdsByStatus[value.state.status, default: []], value.id)
                    }
                } else {
                    memoryInsert(&taskIds, value.id); memoryInsert(&taskIdsByStatus[value.state.status, default: []], value.id)
                }
                tasks[value.id] = value; nextId = max(nextId, value.id.rawValue + 1)
            case .submission(let value, _):
                recordTypes[value.id.rawValue] = "submission"
                if let previous = submissions[value.id] {
                    if previous.status != value.status {
                        submissionIdsByStatus[previous.status]?.removeAll { $0 == value.id }
                        memoryInsert(&submissionIdsByStatus[value.status, default: []], value.id)
                    }
                    if let request = previous.requestId {
                        let key = MemoryStringKey(request)
                        if submissionIdsByRequest[previous.conversationId]?[key] == value.id {
                            submissionIdsByRequest[previous.conversationId]?.removeValue(forKey: key)
                            if submissionIdsByRequest[previous.conversationId]?.isEmpty == true { submissionIdsByRequest.removeValue(forKey: previous.conversationId) }
                        }
                    }
                } else {
                    memoryInsert(&submissionIds, value.id); memoryInsert(&submissionIdsByStatus[value.status, default: []], value.id)
                }
                submissions[value.id] = value
                if let request = value.requestId { submissionIdsByRequest[value.conversationId, default: [:]][MemoryStringKey(request)] = value.id }
                nextId = max(nextId, value.id.rawValue + 1)
            default: break
            }
        }
        for (id, action) in plan.actions { applyDocument(id, action, seq: plan.seq) }
        nextSeq = plan.seq.rawValue + 1
    }

    private mutating func applyDocument(_ id: DocumentID, _ action: MemoryDocumentAction, seq: Seq) {
        var stored: MemoryDocument
        if let create = action.create {
            let record = DocumentRecord(id: id, kind: create.kind, scope: create.scope, createdAt: seq, key: create.key,
                                        retiredAt: action.retire ? seq : nil, history: create.history, fork: create.fork,
                                        extensionFields: create.extensionFields)
            stored = MemoryDocument(record: record, revisions: [MemoryRevision(content: action.content!, seq: seq)])
            recordTypes[id.rawValue] = "document"
            memoryInsert(&documentAddresses[MemoryAddressKey(record), default: MemoryAddressIndex()].ids, id)
            memoryInsert(&documentIdsByScope[MemoryScopeKey(record.scope), default: []], id)
            nextId = max(nextId, id.rawValue + 1)
        } else {
            stored = documents[id]!
            if let content = action.content {
                let revision = MemoryRevision(content: content, seq: seq)
                if case .base = content, stored.record.memoryCurrentOnly { stored.revisions = [revision] }
                else { stored.revisions.append(revision) }
            }
            if action.retire {
                let old = stored.record
                stored.record = DocumentRecord(id: id, kind: old.kind, scope: old.scope, createdAt: old.createdAt, key: old.key,
                                               retiredAt: seq, history: old.history, fork: old.fork, extensionFields: old.extensionFields)
            }
        }
        if action.retire, stored.record.memoryCurrentOnly { stored.revisions = [] }
        if action.create != nil || action.retire {
            let key = MemoryAddressKey(stored.record)
            if action.retire, documentAddresses[key]?.currentId == id { documentAddresses[key]?.currentId = nil }
            if action.create != nil, !action.retire { documentAddresses[key]?.currentId = id }
        }
        documents[id] = stored
    }

    func materialize(_ id: DocumentID, at: DocumentPoint) throws -> StoredDocument? {
        guard let stored = documents[id] else { return nil }
        if case .sequence = at, stored.record.memoryCurrentOnly { throw DurableStorageError.documentDoesNotRetainHistory(id) }
        guard stored.record.memoryAlive(at) else { return nil }
        let revisions = stored.revisions.filter { revision in
            if case .sequence(let seq) = at { return revision.seq <= seq }
            return true
        }
        guard let baseIndex = revisions.lastIndex(where: { if case .base = $0.content { return true }; return false }),
              case .base(let version, let base, _) = revisions[baseIndex].content else {
            throw DurableStorageError.documentMissingBase(id)
        }
        let batches: [[Delta.Op]] = try revisions.dropFirst(baseIndex + 1).map {
            guard case .delta(let revisionVersion, let ops, _) = $0.content, version == revisionVersion else {
                throw DurableStorageError.documentVersionBoundaryWithoutBase(id)
            }
            return ops
        }
        let replayed = try Delta.applyImmutableBatches(.object(base), batches)
        // The typed Swift result requires an object root. Corrupt non-object roots fail decoding.
        let value = try (replayed ?? .null).decode(JSONObject.self)
        return StoredDocument(record: stored.record, version: version, value: value, deltasSinceBase: batches.count)
    }
}

func memoryInsert<T: Comparable>(_ values: inout [T], _ value: T) {
    let index = memoryLowerBound(values, value)
    values.insert(value, at: index)
}
func memoryLowerBound<T: Comparable>(_ values: [T], _ target: T) -> Int {
    var low = 0; var high = values.count
    while low < high {
        let middle = low + (high - low) / 2
        if values[middle] < target { low = middle + 1 } else { high = middle }
    }
    return low
}
extension DocumentContent {
    var memoryVersion: Int {
        switch self { case .base(let version, _, _), .delta(let version, _, _): version }
    }
}
extension DocumentRecord {
    var memoryCurrentOnly: Bool {
        if case .conversation = scope { return history == .latest }
        return true
    }
    func memoryAlive(_ at: DocumentPoint) -> Bool {
        switch at {
        case .current: retiredAt == nil
        case .sequence(let seq): createdAt <= seq && (retiredAt == nil || seq < retiredAt!)
        }
    }
}
