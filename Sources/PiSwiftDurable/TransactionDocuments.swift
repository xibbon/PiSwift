import PiSwiftChord
import Synchronization

/// One cached incarnation. Content changes only after storage has accepted the batch.
final class LoadedDocument: Sendable {
    let address: DocumentAddress
    let record: DocumentRecord
    let valueVersion: Int
    let tracker: Tracker
    struct State: Sendable { var storedVersion: Int; var deltasSinceBase: Int }
    let state: Mutex<State>
    init(address: DocumentAddress, record: DocumentRecord, storedVersion: Int, valueVersion: Int, deltasSinceBase: Int, tracker: Tracker) {
        self.address = address; self.record = record; self.valueVersion = valueVersion; self.tracker = tracker
        state = Mutex(State(storedVersion: storedVersion, deltasSinceBase: deltasSinceBase))
    }
    private struct Decoded: Sendable { let revision: Int; let value: any Sendable }
    private let decoded = Mutex<[ObjectIdentifier: Decoded]>([:])
    func snapshot<Value: Decodable & Sendable>(_ type: Value.Type) throws -> Value {
        var revision = tracker.revision
        var tree = tracker.value
        while tracker.revision != revision { revision = tracker.revision; tree = tracker.value }
        return try snapshot(type, revision: revision, tree: tree)
    }
    func snapshot<Value: Decodable & Sendable>(_ type: Value.Type, revision: Int, tree: JSONValue) throws -> Value {
        try decoded.withLock { cache in
            let key = ObjectIdentifier(type)
            if let saved = cache[key], saved.revision == revision, let value = saved.value as? Value { return value }
            let value = try tree.decode(type)
            cache[key] = Decoded(revision: revision, value: value)
            return value
        }
    }
    var storedVersion: Int { state.withLock { $0.storedVersion } }
    var deltasSinceBase: Int { state.withLock { $0.deltasSinceBase } }
}

private enum DocumentTarget: Sendable {
    case loaded(LoadedDocument)
    case created(DocumentCreate, Tracker)
    case retirement(DocumentRecord)
    case forkCopy(ForkDocumentCopy)
}
private final class DocumentEntry: Sendable {
    let address: DocumentAddress
    var definition: DocumentDefinition? { state.withLock { $0.definition } }
    struct State: Sendable {
        var definition: DocumentDefinition?
        var target: DocumentTarget?
        var change: Change?
        var prepared: Prepared?
        var acquisition: Task<JSONDraft, any Error>?
        var retirement: Task<Void, any Error>?
        var retire = false
    }
    let state: Mutex<State>
    init(address: DocumentAddress, definition: DocumentDefinition?, retire: Bool, target: DocumentTarget? = nil) {
        self.address = address; state = Mutex(State(definition: definition, target: target, retire: retire))
    }
}
private struct DocumentPlan: Sendable {
    let address: DocumentAddress
    let create: DocumentCreate?
    let record: DocumentRecord?
    var retire: Bool
    var content: StorageWrite?
    let tracker: Tracker?
    let prepared: Prepared?
    let loaded: LoadedDocument?
    let definition: DocumentDefinition?
    var conversationID: ConversationID?
    var id: DocumentID { create?.id ?? record!.id }
    var scope: DocumentScope { create?.scope ?? record!.scope }
    var fork: DocumentFork? { create?.fork ?? record?.fork }
}

/// Staged incarnations, including more than one incarnation at the same address.
final class TransactionDocuments: Sendable {
    private struct State: Sendable {
        var entries: [DocumentEntry] = []
        var latest: [[UInt8]: DocumentEntry] = [:]
        var plans: [DocumentPlan] = []
    }
    private let state = Mutex(State())

    func stageForkCopies(_ copies: [ForkDocumentCopy]) {
        state.withLock { state in
            for copy in copies {
                let entry = DocumentEntry(address: copy.address, definition: nil, retire: false, target: .forkCopy(copy))
                state.entries.append(entry)
                state.latest[Array(documentAddressID(copy.address).utf8)] = entry
            }
        }
    }

    func acquire(_ definition: DocumentDefinition, address: DocumentAddress, seedProvider: @escaping @Sendable () throws -> JSONValue?, tx: Transaction) async throws -> JSONDraft {
        try tx.assertOpen()
        try tx.assertTaskDocumentsOpen(address)
        let task = state.withLock { state -> Task<JSONDraft, any Error> in
            let key = Array(documentAddressID(address).utf8)
            let latest = state.latest[key]
            if let latest, let task = latest.state.withLock({ $0.retire ? nil : $0.acquisition }) { return task }
            if let latest, latest.state.withLock({ state in
                guard !state.retire, case .forkCopy = state.target else { return false }
                return true
            }) {
                let task = Task { try await self.acquireForkCopy(latest, definition: definition, tx: tx) }
                latest.state.withLock { $0.acquisition = task }
                return task
            }
            let skipLoad = latest?.state.withLock { $0.retire } ?? false
            let entry = DocumentEntry(address: address, definition: definition, retire: false)
            state.entries.append(entry); state.latest[key] = entry
            let task = Task { try await self.acquire(entry, seed: seedProvider(), skipLoad: skipLoad, tx: tx) }
            entry.state.withLock { $0.acquisition = task }
            return task
        }
        return try await task.value
    }

    private func acquireForkCopy(_ entry: DocumentEntry, definition: DocumentDefinition, tx: Transaction) async throws -> JSONDraft {
        let copy = entry.state.withLock { state -> ForkDocumentCopy in
            guard case .forkCopy(let copy) = state.target else { preconditionFailure("Expected fork copy") }
            return copy
        }
        guard let stored = try await tx.storage.document(copy.source.id, at: copy.source.at, context: tx.context) else {
            throw SessionError.message("Fork source document \(copy.source.id.rawValue) cannot be read")
        }
        try tx.assertOpen()
        guard case .conversation = stored.record.scope,
              stored.record.kind.utf8.elementsEqual(copy.record.kind.utf8),
              stored.record.key.map({ Array($0.utf8) }) == copy.record.key.map({ Array($0.utf8) }),
              stored.record.history == copy.record.history, stored.record.fork == copy.record.fork else {
            throw SessionError.message("Fork source document \(copy.source.id.rawValue) does not match the copied record")
        }
        let record = DocumentRecord(id: copy.record.id, kind: copy.record.kind, scope: copy.record.scope,
                                    createdAt: stored.record.createdAt, key: copy.record.key,
                                    history: copy.record.history, fork: copy.record.fork)
        let value = try definition.materialize(StoredDocument(record: record, version: stored.version, value: stored.value, deltasSinceBase: 0))
        let tracker = try Delta.track(.object(value))
        let change = tracker.beginChange(lifetime: tx.lifetime)
        entry.state.withLock { $0.definition = definition; $0.target = .created(copy.record, tracker); $0.change = change }
        return try change.state
    }

    private func acquire(_ entry: DocumentEntry, seed: JSONValue?, skipLoad: Bool, tx: Transaction) async throws -> JSONDraft {
        let loaded = skipLoad ? nil : try await tx.session.loadDocument(entry.definition!, address: entry.address, context: tx.context)
        try tx.assertOpen()
        if let loaded {
            try entry.definition!.check(loaded.record); try entry.definition!.checkVersion(loaded.storedVersion, record: loaded.record)
            let change = loaded.tracker.beginChange(lifetime: tx.lifetime)
            entry.state.withLock { $0.target = .loaded(loaded); $0.change = change }
            return try change.state
        }
        switch entry.address.scope {
        case .session: break
        case .conversation(let id, _): try await tx.requireConversation(id)
        case .task(let id, _):
            guard let task = try await tx.currentTask(id) else { throw DocumentDefinitionError("Task \(id.rawValue) does not exist") }
            if task.state.status == "terminal" { throw DocumentDefinitionError("Task \(id.rawValue) is terminal") }
        }
        try tx.assertOpen()
        let initial = try entry.definition!.initial(seed)
        let id: DocumentID = try await tx.storage.mintId()
        try tx.assertOpen()
        let tracker = try Delta.track(.object(initial))
        let change = tracker.beginChange(lifetime: tx.lifetime)
        let create = entry.definition!.create(entry.address, id: id)
        entry.state.withLock { $0.target = .created(create, tracker); $0.change = change }
        return try change.state
    }

    func retire(_ definition: DocumentDefinition, address: DocumentAddress, tx: Transaction) async throws {
        try tx.assertOpen()
        try await startRetirement(definition, address: address, tx: tx)?.value
    }

    func startRetirement(_ definition: DocumentDefinition, address: DocumentAddress, tx: Transaction) throws -> Task<Void, any Error>? {
        try tx.assertOpen()
        return state.withLock { state -> Task<Void, any Error>? in
            let key = Array(documentAddressID(address).utf8)
            if let latest = state.latest[key] {
                return latest.state.withLock { state in
                    if state.retire { return nil }
                    state.retire = true
                    if let acquisition = state.acquisition {
                        let task = Task { _ = try await acquisition.value }
                        state.retirement = task
                        return task
                    }
                    return state.retirement
                }
            }
            let entry = DocumentEntry(address: address, definition: definition, retire: true)
            state.entries.append(entry); state.latest[key] = entry
            let task = Task {
                let record: DocumentRecord?
                if let cached = tx.session.cachedDocument(address) { record = cached.record }
                else { record = try await tx.storage.findDocument(address, at: .current, context: tx.context) }
                try tx.assertOpen()
                if let record { try definition.check(record); entry.state.withLock { $0.target = .retirement(record) } }
            }
            entry.state.withLock { $0.retirement = task }
            return task
        }
    }

    func abort() { for entry in state.withLock({ $0.entries }) { entry.state.withLock { $0.change?.abort(); $0.prepared?.abort() } } }
    func prepare() throws {
        for entry in state.withLock({ $0.entries }) {
            try entry.state.withLock { if let change = $0.change { $0.prepared = try change.prepare() } }
        }
    }

    func assemble(tx: Transaction) async throws -> [StorageWrite] {
        var plans: [DocumentPlan] = []
        for entry in state.withLock({ $0.entries }) {
            let plan = entry.state.withLock { state -> DocumentPlan? in
                guard let target = state.target else { return nil }
                switch target {
                case .forkCopy(let copy):
                    return DocumentPlan(address: entry.address, create: copy.record, record: nil, retire: state.retire, content: .documentCopy(record: copy.record, source: copy.source), tracker: nil, prepared: nil, loaded: nil, definition: nil)
                case .retirement(let record): return DocumentPlan(address: entry.address, create: nil, record: record, retire: state.retire, content: nil, tracker: nil, prepared: nil, loaded: nil, definition: nil)
                case .created(let record, let tracker):
                    let prepared = state.prepared!
                    return DocumentPlan(address: entry.address, create: record, record: nil, retire: state.retire, content: .documentCreate(record: record, content: DocumentBaseContent(version: state.definition!.version, value: prepared.value.objectValue!)), tracker: tracker, prepared: prepared, loaded: nil, definition: state.definition)
                case .loaded(let loaded):
                    let prepared = state.prepared!
                    let content: StorageWrite?
                    if loaded.storedVersion < state.definition!.version { content = .documentChange(id: loaded.record.id, content: .base(version: state.definition!.version, value: prepared.value.objectValue!)) }
                    else if !prepared.ops.isEmpty { content = .documentChange(id: loaded.record.id, content: .delta(version: state.definition!.version, ops: prepared.ops)) }
                    else { content = nil }
                    return DocumentPlan(address: entry.address, create: nil, record: loaded.record, retire: state.retire, content: content, tracker: loaded.tracker, prepared: prepared, loaded: loaded, definition: state.definition)
                }
            }
            if let plan { plans.append(plan) }
        }
        try tx.rejectForkSourceWrites(plans.map { ($0.id, $0.scope, $0.fork, $0.content != nil || $0.retire) })
        let terminal = tx.terminalTaskIDs()
        var retiring = Set<DocumentID>()
        for index in plans.indices {
            if case .task(let id, _) = plans[index].scope, terminal.contains(id) {
                plans[index].retire = true; retiring.insert(plans[index].id)
            }
        }
        for id in terminal where !tx.createdTaskIDs().contains(id) {
            var cursor: Cursor?
            repeat {
                let page = try await tx.storage.scanDocuments(DocumentQuery(scope: .task(taskId: id), at: .current), limit: 256, cursor: cursor, context: tx.context)
                for record in page.items where !retiring.contains(record.id) {
                    let address = DocumentAddress(kind: record.kind, scope: record.scope, key: record.key)
                    plans.append(DocumentPlan(address: address, create: nil, record: record, retire: true, content: nil, tracker: nil, prepared: nil, loaded: nil, definition: nil)); retiring.insert(record.id)
                }
                cursor = page.next
            } while cursor != nil
        }
        for index in plans.indices {
            switch plans[index].scope {
            case .session: break
            case .conversation(let id, _): plans[index].conversationID = id
            case .task(let id, _): plans[index].conversationID = try await tx.currentTask(id)?.conversationId
            }
        }
        var writes: [StorageWrite] = []
        for index in plans.indices {
            if let loaded = plans[index].loaded, let prepared = plans[index].prepared, let definition = plans[index].definition,
               case .documentChange(_, .delta, _) = plans[index].content,
               try definition.checkpointWhen?(prepared.value.objectValue!, prepared.ops, CheckpointInfo(deltasSinceBase: loaded.deltasSinceBase)) == true {
                plans[index].content = .documentChange(id: plans[index].id, content: .base(version: definition.version, value: prepared.value.objectValue!))
            }
            if let content = plans[index].content { writes.append(content) }
            if plans[index].retire { writes.append(.documentRetire(id: plans[index].id)) }
        }
        state.withLock { $0.plans = plans }
        return writes
    }

    func adopt(seq: Seq, session: Session) throws -> [DocumentCommitChange] {
        var result: [DocumentCommitChange] = []
        for plan in state.withLock({ $0.plans }) {
            let record: DocumentRecord
            if let old = plan.record {
                record = DocumentRecord(id: old.id, kind: old.kind, scope: old.scope, createdAt: old.createdAt, key: old.key, retiredAt: plan.retire ? seq : old.retiredAt, history: old.history, fork: old.fork, extensionFields: old.extensionFields)
            } else {
                let create = plan.create!
                record = DocumentRecord(id: create.id, kind: create.kind, scope: create.scope, createdAt: seq, key: create.key, retiredAt: plan.retire ? seq : nil, history: create.history, fork: create.fork, extensionFields: create.extensionFields)
            }
            if let prepared = plan.prepared, let tracker = plan.tracker, let definition = plan.definition {
                if plan.loaded == nil ? !plan.retire : !prepared.ops.isEmpty { try tracker.adopt(prepared) } else { prepared.abort() }
                if let loaded = plan.loaded {
                    loaded.state.withLock {
                        $0.storedVersion = max($0.storedVersion, definition.version)
                        if case .documentChange(_, .base, _) = plan.content { $0.deltasSinceBase = 0 }
                        else if case .documentChange(_, .delta, _) = plan.content { $0.deltasSinceBase += 1 }
                    }
                } else if !plan.retire {
                    session.installDocument(LoadedDocument(address: plan.address, record: record, storedVersion: definition.version, valueVersion: definition.version, deltasSinceBase: 0, tracker: tracker))
                }
            }
            if plan.retire {
                if plan.record != nil { session.evictDocument(plan.address, recordID: record.id) }
                result.append(DocumentCommitChange(record: record, conversationId: plan.conversationID, version: nil, value: nil, ops: []))
            } else if case .documentCopy(_, let source, _) = plan.content {
                result.append(DocumentCommitChange(record: record, conversationId: plan.conversationID, source: source))
            } else if plan.content != nil, let prepared = plan.prepared, let definition = plan.definition {
                result.append(DocumentCommitChange(record: record, conversationId: plan.conversationID, version: definition.version, value: prepared.value.objectValue!, ops: plan.loaded == nil ? [] : prepared.ops))
            }
        }
        return result
    }
}

extension Transaction {
    public func doc<Value: Codable & Sendable>(_ token: SessionDocToken<Value>) async throws -> JSONDraft {
        try await operation { try await documents.acquire(token.definition, address: DocumentAddress(kind: token.definition.kind, scope: .session()), seedProvider: { nil }, tx: self) }
    }
    public func retireDoc<Value: Codable & Sendable>(_ token: SessionDocToken<Value>) async throws {
        try await operation { try await documents.retire(token.definition, address: DocumentAddress(kind: token.definition.kind, scope: .session()), tx: self) }
    }
    public func doc<Value: Codable & Sendable>(_ token: ConversationDocToken<Value>, conversationId: ConversationID) async throws -> JSONDraft {
        try await operation { try await documents.acquire(token.definition, address: DocumentAddress(kind: token.definition.kind, scope: .conversation(conversationId: conversationId)), seedProvider: { nil }, tx: self) }
    }
    public func retireDoc<Value: Codable & Sendable>(_ token: ConversationDocToken<Value>, conversationId: ConversationID) async throws {
        try await operation { try await documents.retire(token.definition, address: DocumentAddress(kind: token.definition.kind, scope: .conversation(conversationId: conversationId)), tx: self) }
    }
    public func doc<Value: Codable & Sendable>(_ token: RewindableConversationDocToken<Value>, conversationId: ConversationID) async throws -> JSONDraft {
        try await operation { try await documents.acquire(token.definition, address: DocumentAddress(kind: token.definition.kind, scope: .conversation(conversationId: conversationId)), seedProvider: { nil }, tx: self) }
    }
    public func retireDoc<Value: Codable & Sendable>(_ token: RewindableConversationDocToken<Value>, conversationId: ConversationID) async throws {
        try await operation { try await documents.retire(token.definition, address: DocumentAddress(kind: token.definition.kind, scope: .conversation(conversationId: conversationId)), tx: self) }
    }
    public func doc<Value: Codable & Sendable>(_ token: TaskDocToken<Value>, taskId: TaskID) async throws -> JSONDraft {
        try await operation { try await documents.acquire(token.definition, address: DocumentAddress(kind: token.definition.kind, scope: .task(taskId: taskId)), seedProvider: { nil }, tx: self) }
    }
    public func retireDoc<Value: Codable & Sendable>(_ token: TaskDocToken<Value>, taskId: TaskID) async throws {
        try await operation { try await documents.retire(token.definition, address: DocumentAddress(kind: token.definition.kind, scope: .task(taskId: taskId)), tx: self) }
    }
    public func doc<Value: Codable & Sendable, Seed: Codable & Sendable>(_ token: SessionDocFamilyToken<Value, Seed>, key: String, seed: Seed) async throws -> JSONDraft {
        try await operation { try await documents.acquire(token.definition, address: DocumentAddress(kind: token.definition.kind, scope: .session(), key: key), seedProvider: { try JSONValue(encoding: seed) }, tx: self) }
    }
    public func retireDoc<Value: Codable & Sendable, Seed: Codable & Sendable>(_ token: SessionDocFamilyToken<Value, Seed>, key: String) async throws {
        try await operation { try await documents.retire(token.definition, address: DocumentAddress(kind: token.definition.kind, scope: .session(), key: key), tx: self) }
    }
    public func doc<Value: Codable & Sendable, Seed: Codable & Sendable>(_ token: ConversationDocFamilyToken<Value, Seed>, conversationId: ConversationID, key: String, seed: Seed) async throws -> JSONDraft {
        try await operation { try await documents.acquire(token.definition, address: DocumentAddress(kind: token.definition.kind, scope: .conversation(conversationId: conversationId), key: key), seedProvider: { try JSONValue(encoding: seed) }, tx: self) }
    }
    public func retireDoc<Value: Codable & Sendable, Seed: Codable & Sendable>(_ token: ConversationDocFamilyToken<Value, Seed>, conversationId: ConversationID, key: String) async throws {
        try await operation { try await documents.retire(token.definition, address: DocumentAddress(kind: token.definition.kind, scope: .conversation(conversationId: conversationId), key: key), tx: self) }
    }
    public func doc<Value: Codable & Sendable, Seed: Codable & Sendable>(_ token: RewindableConversationDocFamilyToken<Value, Seed>, conversationId: ConversationID, key: String, seed: Seed) async throws -> JSONDraft {
        try await operation { try await documents.acquire(token.definition, address: DocumentAddress(kind: token.definition.kind, scope: .conversation(conversationId: conversationId), key: key), seedProvider: { try JSONValue(encoding: seed) }, tx: self) }
    }
    public func retireDoc<Value: Codable & Sendable, Seed: Codable & Sendable>(_ token: RewindableConversationDocFamilyToken<Value, Seed>, conversationId: ConversationID, key: String) async throws {
        try await operation { try await documents.retire(token.definition, address: DocumentAddress(kind: token.definition.kind, scope: .conversation(conversationId: conversationId), key: key), tx: self) }
    }
    public func doc<Value: Codable & Sendable, Seed: Codable & Sendable>(_ token: TaskDocFamilyToken<Value, Seed>, taskId: TaskID, key: String, seed: Seed) async throws -> JSONDraft {
        try await operation { try await documents.acquire(token.definition, address: DocumentAddress(kind: token.definition.kind, scope: .task(taskId: taskId), key: key), seedProvider: { try JSONValue(encoding: seed) }, tx: self) }
    }
    public func retireDoc<Value: Codable & Sendable, Seed: Codable & Sendable>(_ token: TaskDocFamilyToken<Value, Seed>, taskId: TaskID, key: String) async throws {
        try await operation { try await documents.retire(token.definition, address: DocumentAddress(kind: token.definition.kind, scope: .task(taskId: taskId), key: key), tx: self) }
    }
}
