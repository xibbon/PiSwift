import PiSwiftChord
import Synchronization

internal struct TransactionTableState: Sendable {
    var writes: [StorageWrite] = []
    var createdConversationIDs: Set<ConversationID> = []
    var forkSourceConversationIDs: Set<ConversationID> = []
    var forkSourceDocumentIDs: Set<DocumentID> = []
    var tasks: [TaskID: TransactionTask] = [:]
    var taskOrder: [TaskID] = []
    var submissions: [SubmissionID: SubmissionRecord] = [:]
    var submissionOrder: [SubmissionID] = []
    var submissionChanges: [(SubmissionID, TransactionSubmissionChange)] = []
}

internal struct TransactionTask: Sendable {
    var committedRead: Task<TaskRecord?, any Error>?
    var write: TaskRecord?
    var created = false
}

internal enum TransactionSubmissionChange: Sendable {
    case settlement(SubmissionSettlement)
    case placed(EntryID)
}

extension Transaction {
    /// Returns a conversation by ID, or nil when that ID is absent.
    public func conversation(_ id: ConversationID) async throws -> ConversationRecord? {
        try await operation(tableRead: "conversation") { try await storage.conversation(id, context: context) }
    }

    /// Reads the entry identified by ID, or nil when it is absent.
    public func entry(_ id: EntryID) async throws -> EntryRecord? {
        try await operation(tableRead: "entry") { try await storage.entry(id, context: context)?.entry }
    }

    /// Reads the entry identified by ID, or nil when it is absent.
    public func entry<Data>(_ token: EntryKind<Data>, id: EntryID) async throws -> TypedEntry<Data>?
    where Data: Codable & Sendable {
        try await operation(tableRead: "entry") {
            guard let record = try await storage.entry(id, context: context)?.entry, token.matches(record) else { return nil }
            return try TypedEntry(record)
        }
    }

    /// Reads the stored task record before the first table write, or returns nil when absent.
    public func task(_ id: TaskID) async throws -> TaskRecord? {
        try await operation(tableRead: "task") { try await committedTask(id) }
    }

    /// Returns a page of conversations that match all query filters.
    public func scanConversations(_ query: ConversationQuery, limit: Int, cursor: Cursor? = nil) async throws -> Page<ConversationRecord, Cursor> {
        try await operation(tableRead: "scanConversations") {
            try await storage.scanConversations(query, limit: limit, cursor: cursor, context: context)
        }
    }

    /// Returns a page of entries in the visible ancestry and requested range.
    public func scanEntries(_ query: EntryQuery, limit: Int, cursor: Cursor? = nil) async throws -> Page<EntryRecord, Cursor> {
        try await operation(tableRead: "scanEntries") {
            try await storage.scanEntries(query, limit: limit, cursor: cursor, context: context)
        }
    }

    /// Returns the newest visible entry ID, if this conversation has entries.
    /// v1.5.2 session-group-commit.test.ts:259–260.
    public func latestEntryId(_ conversationId: ConversationID) async throws -> EntryID? {
        try await operation(tableRead: "latestEntryId") {
            try await session.latestEntryId(conversationId, context: context)
        }
    }

    /// Returns the newest visible entry that sets a context lower bound.
    public func latestHeadMarker(_ conversationId: ConversationID) async throws -> EntryRecord? {
        try await operation(tableRead: "latestHeadMarker") {
            try await session.latestHeadMarker(conversationId, atOrBefore: nil, context: context)
        }
    }

    /// Returns a page of tasks that match all query filters.
    public func scanTasks(_ query: TaskQuery, limit: Int, cursor: Cursor? = nil) async throws -> Page<TaskRecord, Cursor> {
        try await operation(tableRead: "scanTasks") {
            try await storage.scanTasks(query, limit: limit, cursor: cursor, context: context)
        }
    }

    /// Reads a submission, including a placed continued run, in this transaction.
    public func submission(_ id: SubmissionID) async throws -> SubmissionRecord? {
        try await operation(tableRead: "submission") { try await storage.submission(id, context: context) }
    }

    /// Returns the submission for the conversation-scoped request key, or nil.
    public func submissionByRequest(_ conversationId: ConversationID, requestId: String) async throws -> SubmissionRecord? {
        try await operation(tableRead: "submissionByRequest") {
            try await storage.submissionByRequest(conversationId, requestId: requestId, context: context)
        }
    }

    /// Creates a conversation with the supplied ownership and optional configuration.
    public func createConversation(ownership: ConversationOwnership) async throws -> ConversationRecord {
        try await operation(tableWrite: true) { try await stageConversation(parent: nil, ownership: ownership) }
    }

    internal func createRootConversation() async throws -> ConversationRecord {
        try await operation(tableWrite: true) {
            try await stageConversation(parent: nil, ownership: .ownerless(), reservedId: rootConversationID)
        }
    }

    /// Creates a conversation with capped ancestry through the selected entry.
    public func forkConversation(_ parentConversationId: ConversationID, at: EntryID, ownership: ConversationOwnership) async throws -> ConversationRecord {
        try await operation(tableWrite: true) {
            try await stageConversation(parent: ConversationParent(conversationId: parentConversationId, at: at), ownership: ownership)
        }
    }

    private func stageConversation(parent: ConversationParent?, ownership: ConversationOwnership, reservedId: ConversationID? = nil) async throws -> ConversationRecord {
        let id: ConversationID
        if let reservedId { id = reservedId } else { id = try await storage.mintId() }
        try assertOpen()
        var owner: ConversationOwner?
        if case .task(let ownerId, _) = ownership {
            guard let task = try await currentTask(ownerId) else {
                throw SessionError.message("Conversation owner task \(ownerId.rawValue) does not exist")
            }
            try assertOpen()
            owner = ConversationOwner(conversationId: task.conversationId, taskId: ownerId)
        }
        if let parent {
            let copies = try await prepareForkDocumentCopies(storage: storage, parentConversationId: parent.conversationId,
                                                            at: parent.at, childConversationId: id, context: context)
            try assertOpen()
            documents.stageForkCopies(copies)
            tableState.withLock { state in
                state.forkSourceConversationIDs.insert(parent.conversationId)
                state.forkSourceDocumentIDs.formUnion(copies.map { $0.source.id })
            }
        }
        let record = ConversationRecord(id: id, parent: parent, owner: owner)
        tableState.withLock { state in
            state.createdConversationIDs.insert(id)
            state.writes.append(.conversation(value: record))
        }
        try await conversationCreated(self, record)
        try assertOpen()
        return record
    }

    internal func rejectForkSourceWrites(_ plans: [(DocumentID, DocumentScope, DocumentFork?, Bool)]) throws {
        let snapshot = tableState.withLock { $0 }
        for (id, scope, fork, changes) in plans where changes {
            if snapshot.forkSourceDocumentIDs.contains(id) {
                throw SessionError.message("Cannot change fork source document \(id.rawValue) in the fork transaction")
            }
            if case .conversation(let conversation, _) = scope,
               snapshot.forkSourceConversationIDs.contains(conversation), fork == .current {
                throw SessionError.message("Cannot fork conversation \(conversation.rawValue) while changing its current-policy documents")
            }
        }
    }

    /// Creates an immutable entry in the transaction's conversation history.
    public func appendEntry(_ conversationId: ConversationID, value: EntryDraft) async throws -> EntryRecord {
        try await operation(tableWrite: true) {
            try await requireConversation(conversationId)
            try assertOpen()
            let id: EntryID = try await storage.mintId()
            try assertOpen()
            let head: EntryID?
            switch value.head { case .self: head = id; case .entry(let value): head = value; case nil: head = nil }
            let record = EntryRecord(id: id, conversationId: conversationId, kind: value.kind, model: value.model,
                                     data: value.data, head: head, edits: value.edits, byTaskId: scope.taskId,
                                     extensionFields: value.extensionFields)
            try validateTableJSON(record)
            tableState.withLock { $0.writes.append(.entry(value: record)) }
            return record
        }
    }

    /// Creates an immutable entry in the transaction's conversation history.
    public func appendEntry<Data>(_ token: EntryKind<Data>, conversationId: ConversationID, value: TypedEntryDraft<Data>) async throws -> TypedEntry<Data>
    where Data: Codable & Sendable {
        try await operation(tableWrite: true) {
            let data = try value.data.map { try JSONValue(encoding: $0) }
            return try TypedEntry(await appendEntry(conversationId, value: EntryDraft(kind: token.kind, model: value.model, data: data, head: value.head, edits: value.edits)))
        }
    }

    /// Creates a typed task and stores its encoded input and initial checkpoint.
    public func createTask<Input, Checkpoint>(_ task: TaskKind<Input, Checkpoint>, input: Input, options: TaskOptions) async throws -> TaskID {
        try await operation(tableWrite: true) {
            var owner: TaskRecord?
            if case .task(let ownerId, _) = options.ownership {
                owner = try await currentTask(ownerId)
                try assertOpen()
                guard let owner else { throw SessionError.message("Task owner \(ownerId.rawValue) does not exist") }
                guard !options.background else { throw SessionError.message("A child task cannot be background") }
                if let conversationId = options.conversationId, conversationId != owner.conversationId {
                    throw SessionError.message("A child task lives in its owner's conversation \(owner.conversationId.rawValue)")
                }
            }
            guard let conversationId = owner?.conversationId ?? options.conversationId ?? scope.conversationId else {
                throw SessionError.message("Tx.createTask() requires options.conversationId")
            }
            try await requireConversation(conversationId)
            try assertOpen()
            let checkpoint = try JSONValue(encoding: task.initial(input))
            let inputValue = try JSONValue(encoding: input)
            let id: TaskID = try await storage.mintId()
            try assertOpen()
            let record = TaskRecord(id: id, conversationId: conversationId, kind: task.name, version: task.version,
                                    input: inputValue, state: .pending(checkpoint: checkpoint), owner: owner?.id,
                                    background: options.background, abandonOnRestart: options.abandonOnRestart ? true : nil)
            try validateTableJSON(record)
            tableState.withLock { state in
                if state.tasks[id] == nil { state.taskOrder.append(id) }
                state.tasks[id] = TransactionTask(write: record, created: true)
            }
            return id
        }
    }

    /// Creates the durable record for an input or entry-write request.
    public func createSubmission(_ create: SubmissionCreate) async throws -> SubmissionRecord {
        try await operation(tableWrite: true) {
            try await requireConversation(create.conversationId)
            try assertOpen()
            let id: SubmissionID = try await storage.mintId()
            try assertOpen()
            let record = create.record(id: id)
            try validateTableJSON(record)
            tableState.withLock { state in
                state.submissionOrder.append(id)
                state.submissions[id] = record
            }
            return record
        }
    }

    /// Stores the final answer or unanswered reason for a submission.
    public func settleSubmission(_ id: SubmissionID, settlement: SubmissionSettlement) throws {
        try synchronousOperation(tableWrite: true) {
            try validateTableJSON(settlement)
            tableState.withLock { $0.submissionChanges.append((id, .settlement(settlement))) }
        }
    }

    /// Records the entry at which an input submission entered the conversation.
    public func placeSubmission(_ id: SubmissionID, entry: EntryID) throws {
        try synchronousOperation(tableWrite: true) {
            tableState.withLock { $0.submissionChanges.append((id, .placed(entry))) }
        }
    }

    internal func setTask(_ value: TaskRecord) throws {
        try synchronousOperation(tableWrite: true) {
            try tableState.withLock { state in
                var task = state.tasks[value.id] ?? TransactionTask()
                let candidate = task.write
                if candidate?.state.status == "terminal" {
                    throw SessionError.message("Task \(value.id.rawValue) already has a terminal candidate")
                }
                if let candidate, candidate.conversationId != value.conversationId {
                    throw SessionError.message("Task \(value.id.rawValue) cannot change conversations")
                }
                let startedAt = candidate?.startedAt ?? value.startedAt ?? (value.state.status == "running" ? Double(now()) : nil)
                let endedAt = candidate?.endedAt ?? value.endedAt ?? (value.state.status == "terminal" ? Double(now()) : nil)
                // v1.6.0 transaction.ts:579-584: a live replacement keeps memos staged
                // by an earlier write in this transaction. The later value wins for a key.
                var memos = value.memos
                if let earlier = candidate?.memos, value.state.status != "terminal", value.state.status != "completing" {
                    var merged = earlier
                    for (name, memo) in value.memos ?? [:] { merged[name] = memo }
                    memos = merged
                }
                let record = TaskRecord(id: value.id, conversationId: value.conversationId, kind: value.kind, version: value.version,
                                        input: value.input, state: value.state, owner: value.owner, background: value.background,
                                        abortRequested: value.abortRequested, abortReason: value.abortReason,
                                        abandonOnRestart: value.abandonOnRestart, startedAt: startedAt, endedAt: endedAt,
                                        memos: memos, restarts: value.storedRestarts,
                                        extensionFields: value.carrierCopyFields)
                try validateTableJSON(record)
                task.write = record
                if state.tasks[value.id] == nil { state.taskOrder.append(value.id) }
                state.tasks[value.id] = task
            }
        }
    }

    internal func stagedTasks() throws -> [TaskRecord] {
        try assertOpen()
        return tableState.withLock { state in state.taskOrder.compactMap { state.tasks[$0]?.write } }
    }

    internal func stagedConversations() throws -> [ConversationRecord] {
        try assertOpen()
        return tableState.withLock { state in
            state.writes.compactMap { if case .conversation(let value, _) = $0 { return value }; return nil }
        }
    }

    internal func terminalTaskIDs() -> Set<TaskID> {
        tableState.withLock { state in Set(state.tasks.values.compactMap { $0.write?.state.status == "terminal" ? $0.write?.id : nil }) }
    }

    internal func createdTaskIDs() -> Set<TaskID> {
        tableState.withLock { state in Set(state.tasks.compactMap { $0.value.created ? $0.key : nil }) }
    }

    internal func assertTaskDocumentsOpen(_ address: DocumentAddress) throws {
        if case .task(let id, _) = address.scope { try assertTaskDocumentsOpen(id) }
        else { try assertOpen() }
    }

    internal func assertTaskDocumentsOpen(_ id: TaskID) throws {
        try assertOpen()
        if tableState.withLock({ $0.tasks[id]?.write?.state.status == "terminal" }) {
            throw SessionError.message("Task \(id.rawValue) is terminal")
        }
    }

    internal func requireConversation(_ id: ConversationID) async throws {
        if tableState.withLock({ $0.createdConversationIDs.contains(id) }) { return }
        if try await storage.conversation(id, context: context) == nil {
            throw SessionError.message("Conversation \(id.rawValue) does not exist")
        }
    }

    internal func currentTask(_ id: TaskID) async throws -> TaskRecord? {
        if let write = tableState.withLock({ $0.tasks[id]?.write }) { return write }
        return try await committedTask(id)
    }

    internal func stagedTask(_ id: TaskID) -> TaskRecord? {
        tableState.withLock { $0.tasks[id]?.write }
    }

    private func committedTask(_ id: TaskID) async throws -> TaskRecord? {
        let read = tableState.withLock { state in
            var task = state.tasks[id] ?? TransactionTask()
            if let read = task.committedRead { return read }
            let storage = self.storage
            let context = self.context
            let read = Task { try await storage.task(id, context: context) }
            task.committedRead = read
            if state.tasks[id] == nil { state.taskOrder.append(id) }
            state.tasks[id] = task
            return read
        }
        return try await read.value
    }

    internal func assembleTables() async throws -> [StorageWrite] {
        let snapshot = tableState.withLock { $0 }
        var owners: [(String, TaskID)] = []
        for write in snapshot.writes {
            if case .conversation(let record, _) = write, let owner = record.owner { owners.append(("Conversation owner task", owner.taskId)) }
        }
        for id in snapshot.taskOrder {
            if let task = snapshot.tasks[id], task.created, let owner = task.write?.owner { owners.append(("Task owner", owner)) }
        }
        for (what, id) in owners {
            guard let owner = try await currentTask(id) else { throw SessionError.message("\(what) \(id.rawValue) does not exist") }
            if owner.state.status == "terminal" || owner.state.status == "completing" {
                throw SessionError.message("\(what) \(id.rawValue) is \(owner.state.status)")
            }
            if owner.abortRequested { throw SessionError.message("\(what) \(id.rawValue) is abort-marked") }
        }
        for id in snapshot.taskOrder {
            guard let task = snapshot.tasks[id], !task.created, let candidate = task.write else { continue }
            guard let committed = try await committedTask(id) else { throw SessionError.message("Task \(id.rawValue) does not exist") }
            if committed.state.status == "terminal" { throw SessionError.message("Task \(id.rawValue) is already terminal") }
            if committed.conversationId != candidate.conversationId { throw SessionError.message("Task \(id.rawValue) cannot change conversations") }
        }
        var submissions = snapshot.submissions
        var order = snapshot.submissionOrder
        var settling = snapshot.submissionOrder.compactMap { submissions[$0] }.filter {
            $0.status == "done" || $0.status == "unanswered"
        }
        for (id, change) in snapshot.submissionChanges {
            let current: SubmissionRecord
            if let candidate = submissions[id] { current = candidate }
            else if let stored = try await storage.submission(id, context: context) { current = stored }
            else { throw SessionError.message("Submission \(id.rawValue) does not exist") }
            let next = try applySubmissionChange(current, change)
            if next != current {
                if submissions[id] == nil { order.append(id) }
                submissions[id] = next
                if next.status == "done" || next.status == "unanswered" { settling.append(next) }
            }
        }
        var tasks = snapshot.tasks
        var taskOrder = snapshot.taskOrder
        for record in settling {
            guard let notify = try record.notify else { continue }
            try await session.touch(SessionKeys.taskKey(notify.taskId))
            let target: TaskRecord?
            if let staged = tasks[notify.taskId]?.write { target = staged }
            else { target = try await storage.task(notify.taskId, context: context) }
            let (_, updated) = try deliverSignal(record: target, token: SubmissionSettled,
                                                 key: notify.key, value: SettledSubmission(record), now: Double(now()))
            if let updated {
                var task = tasks[notify.taskId] ?? TransactionTask()
                task.write = updated
                if tasks[notify.taskId] == nil { taskOrder.append(notify.taskId) }
                tasks[notify.taskId] = task
            }
        }
        var writes = snapshot.writes
        for id in order { if let value = submissions[id] { writes.append(.submission(value: value)) } }
        for id in taskOrder { if let value = tasks[id]?.write { writes.append(.task(value: value)) } }
        return writes
    }
}

private func validateTableJSON<T: Encodable>(_ value: T) throws {
    _ = try JSONValue(encoding: value)
}

private func applySubmissionChange(_ current: SubmissionRecord, _ change: TransactionSubmissionChange) throws -> SubmissionRecord {
    if current.status == "done" || current.status == "unanswered" { return current }
    func merged(_ fields: JSONObject, _ extensions: JSONObject) -> JSONObject {
        var result = fields
        for (key, value) in extensions { result[key] = value }
        return result
    }
    switch change {
    case .placed(let entry):
        switch current {
        case .input(let id, let conversationId, let requestId, .queued(let fields)):
            return .input(id: id, conversationId: conversationId, requestId: requestId, state: .placed(entry: entry, extensions: fields))
        case .write(let id, let conversationId, let requestId, .queued(let fields)):
            return .write(id: id, conversationId: conversationId, requestId: requestId, state: .done(entry: entry, extensions: fields))
        case .input, .write, .continue:
            throw SessionError.message("Submission \(current.id.rawValue) is not queued")
        }
    case .settlement(.done(let answer, let extensions)):
        switch current {
        case .input(let id, let conversationId, let requestId, .placed(let entry, let fields)):
            return .input(id: id, conversationId: conversationId, requestId: requestId,
                state: .done(entry: entry, answer: answer, extensions: merged(fields, extensions)))
        case .continue(let id, let conversationId, let requestId, .placed(let fields)):
            return .continue(id: id, conversationId: conversationId, requestId: requestId,
                state: .done(answer: answer, extensions: merged(fields, extensions)))
        case .input, .write, .continue:
            throw SessionError.message("Submission \(current.id.rawValue) is not a placed input")
        }
    case .settlement(.unanswered(let reason, let detail, let extensions)):
        switch current {
        case .input(let id, let conversationId, let requestId, let state):
            let entry: EntryID?
            let fields: JSONObject
            switch state {
            case .queued(let value): entry = nil; fields = value
            case .placed(let value, let valueFields): entry = value; fields = valueFields
            case .done, .unanswered: return current
            }
            return .input(id: id, conversationId: conversationId, requestId: requestId,
                state: .unanswered(reason: reason, entry: entry, detail: detail, extensions: merged(fields, extensions)))
        case .write(let id, let conversationId, let requestId, let state):
            switch state {
            case .queued(let fields):
                return .write(id: id, conversationId: conversationId, requestId: requestId,
                    state: .unanswered(reason: reason, detail: detail, extensions: merged(fields, extensions)))
            case .done, .unanswered: return current
            }
        case .continue(let id, let conversationId, let requestId, let state):
            switch state {
            case .placed(let fields):
                return .continue(id: id, conversationId: conversationId, requestId: requestId,
                    state: .unanswered(reason: reason, detail: detail, extensions: merged(fields, extensions)))
            case .done, .unanswered: return current
            }
        }
    }
}
