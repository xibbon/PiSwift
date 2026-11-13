import PiSwiftChord
import Synchronization

/// The Session's write-through cache for hot record reads. All state is in one mutex.
internal final class SessionCachedStorage: DurableStorage {
    internal struct Sizes: Sendable {
        let conversations: Int
        let tasks: Int
        let liveTasks: Int
        let awaited: Int
        let waits: Int
        let submissions: Int
        let readsInFlight: Int
    }

    /// Count-bounded LRU. A hit and a replacement become the most recent use.
    private struct Lru<Key: Hashable, Value> {
        let capacity: Int
        private var values: [Key: (value: Value, used: UInt64)] = [:]
        private var clock: UInt64 = 0
        private var newest: Key?
        var count: Int { values.count }
        init(_ capacity: Int) { self.capacity = capacity }
        mutating func get(_ key: Key) -> Value? {
            guard var slot = values[key] else { return nil }
            if newest == key { return slot.value }
            clock &+= 1; slot.used = clock; values[key] = slot
            newest = key
            return slot.value
        }
        mutating func set(_ key: Key, _ value: Value) {
            clock &+= 1; values[key] = (value, clock)
            newest = key
            if values.count > capacity, let oldest = values.min(by: { $0.value.used < $1.value.used })?.key {
                values.removeValue(forKey: oldest)
            }
        }
        mutating func delete(_ key: Key) {
            values.removeValue(forKey: key)
            if newest == key { newest = nil }
        }
    }

    private struct Awaited {
        var count: Int
        var record: TaskRecord?
    }
    private struct Wait {
        let on: [TaskID]
        var left: Bool
    }
    private struct Reading {
        var count: Int
        var version: UInt64
    }
    private struct State {
        var conversations: Lru<ConversationID, ConversationRecord>
        var liveTasks: [TaskID: TaskRecord] = [:]
        var awaited: [TaskID: Awaited] = [:]
        var waits: [TaskID: Wait] = [:]
        var tasks: Lru<TaskID, TaskRecord>
        var submissions: Lru<SubmissionID, SubmissionRecord>
        var reads: [Int64: Reading] = [:]

        init(conversations: Int, tasks: Int, submissions: Int) {
            self.conversations = Lru(conversations)
            self.tasks = Lru(tasks)
            self.submissions = Lru(submissions)
        }
        mutating func begin(_ id: Int64) -> UInt64 {
            var read = reads[id] ?? Reading(count: 0, version: 0)
            read.count += 1; reads[id] = read
            return read.version
        }
        mutating func end(_ id: Int64, from version: UInt64) -> Bool {
            guard var read = reads[id] else { return false }
            let changed = read.version != version
            read.count -= 1
            if read.count == 0 { reads.removeValue(forKey: id) }
            else { reads[id] = read }
            return changed
        }
        mutating func wrote(_ id: Int64) {
            guard var read = reads[id] else { return }
            read.version &+= 1; reads[id] = read
        }
        mutating func keepTask(_ record: TaskRecord) {
            if case .terminal = record.state {
                liveTasks.removeValue(forKey: record.id)
                if var value = awaited[record.id] {
                    value.record = record; awaited[record.id] = value
                } else { tasks.set(record.id, record) }
            } else {
                tasks.delete(record.id)
                liveTasks[record.id] = record
            }
        }
        mutating func release(_ on: [TaskID]) {
            for id in on {
                guard var value = awaited[id] else { continue }
                value.count -= 1
                if value.count > 0 { awaited[id] = value }
                else {
                    awaited.removeValue(forKey: id)
                    if let record = value.record { tasks.set(id, record) }
                }
            }
        }
        mutating func followWait(_ record: TaskRecord) {
            let wait = waits[record.id]
            if case .waiting(_, let on, _, _) = record.state {
                if let wait { release(wait.on) }
                waits[record.id] = Wait(on: on, left: false)
                for id in on {
                    if awaited[id] == nil {
                        let ended = tasks.get(id)
                        tasks.delete(id)
                        awaited[id] = Awaited(count: 0, record: ended)
                    }
                    awaited[id]!.count += 1
                }
                return
            }
            guard var wait else { return }
            if !wait.left, record.state.status != "terminal" {
                wait.left = true; waits[record.id] = wait
            } else {
                waits.removeValue(forKey: record.id)
                release(wait.on)
            }
        }
        mutating func task(_ id: TaskID) -> TaskRecord? {
            liveTasks[id] ?? awaited[id]?.record ?? tasks.get(id)
        }
    }

    private let backend: any DurableStorage
    var publishesImmediately: Bool {
        backend is MemoryStorage || backend is SqliteStorage || backend is JsonlStorage
    }
    private let state: Mutex<State>
    init(_ backend: any DurableStorage, conversationCapacity: Int = 4096,
         taskCapacity: Int = 256, submissionCapacity: Int = 256) {
        self.backend = backend
        self.state = Mutex(State(conversations: max(1, min(conversationCapacity, 4096)),
                                 tasks: max(1, min(taskCapacity, 256)),
                                 submissions: max(1, min(submissionCapacity, 256))))
    }
    var sizes: Sizes { state.withLock { s in
        Sizes(conversations: s.conversations.count, tasks: s.tasks.count,
              liveTasks: s.liveTasks.count, awaited: s.awaited.count,
              waits: s.waits.count, submissions: s.submissions.count,
              readsInFlight: s.reads.count)
    } }
    /// Test seam for forcing the same miss that count-based eviction causes.
    internal func evictConversation(_ id: ConversationID) {
        state.withLock { $0.conversations.delete(id) }
    }
    internal func evictSubmission(_ id: SubmissionID) {
        state.withLock { $0.submissions.delete(id) }
    }

    /// Called only by the publisher, before adoption. Receipts never call this.
    func published(_ writes: [StorageWrite]) {
        // Entry-only commits are common; the cache has no entry table.
        guard writes.contains(where: { write in
            switch write { case .conversation, .task, .submission: true; default: false }
        }) else { return }
        state.withLock { s in
            for write in writes {
                switch write {
                case .conversation(let value, _):
                    s.wrote(value.id.rawValue); s.conversations.set(value.id, value)
                case .task(let value, _):
                    s.wrote(value.id.rawValue); s.followWait(value); s.keepTask(value)
                case .submission(let value, _):
                    s.wrote(value.id.rawValue); s.submissions.set(value.id, value)
                default: break
                }
            }
        }
    }
    func commit(_ batches: [[StorageWrite]], receive: @Sendable (Int, Seq) -> Void, context: ChordContext) async throws -> CommitResult {
        try await backend.commit(batches, receive: receive, context: context)
    }
    func publishing(_ publish: @Sendable () -> Void, context: ChordContext) async throws {
        try await backend.publishing(publish, context: context)
    }
    func mintId<Kind: DurableIDKind>() async throws -> DurableID<Kind> { try await backend.mintId() }
    func conversation(_ id: ConversationID, context: ChordContext) async throws -> ConversationRecord? {
        while true {
            let (cached, version) = state.withLock { s -> (ConversationRecord?, UInt64?) in
                if let cached = s.conversations.get(id) { return (cached, nil) }
                return (nil, s.begin(id.rawValue))
            }
            if let cached { return cached }
            let value: ConversationRecord?
            do { value = try await backend.conversation(id, context: context) }
            catch { state.withLock { _ = $0.end(id.rawValue, from: version!) }; throw error }
            let (changed, current) = state.withLock { s -> (Bool, ConversationRecord?) in
                let changed = s.end(id.rawValue, from: version!)
                if !changed, let value { s.conversations.set(id, value) }
                return (changed, changed ? s.conversations.get(id) : value)
            }
            if !changed || current != nil { return current }
        }
    }
    func task(_ id: TaskID, context: ChordContext) async throws -> TaskRecord? {
        while true {
            let (cached, version) = state.withLock { s -> (TaskRecord?, UInt64?) in
                if let cached = s.task(id) { return (cached, nil) }
                return (nil, s.begin(id.rawValue))
            }
            if let cached { return cached }
            let value: TaskRecord?
            do { value = try await backend.task(id, context: context) }
            catch { state.withLock { _ = $0.end(id.rawValue, from: version!) }; throw error }
            let (changed, current) = state.withLock { s -> (Bool, TaskRecord?) in
                let changed = s.end(id.rawValue, from: version!)
                if !changed, let value { s.keepTask(value) }
                return (changed, changed ? s.task(id) : value)
            }
            if !changed || current != nil { return current }
        }
    }
    /// A submission read is not inserted: only written submissions are hot.
    func submission(_ id: SubmissionID, context: ChordContext) async throws -> SubmissionRecord? {
        while true {
            let (cached, version) = state.withLock { s -> (SubmissionRecord?, UInt64?) in
                if let cached = s.submissions.get(id) { return (cached, nil) }
                return (nil, s.begin(id.rawValue))
            }
            if let cached { return cached }
            let value: SubmissionRecord?
            do { value = try await backend.submission(id, context: context) }
            catch { state.withLock { _ = $0.end(id.rawValue, from: version!) }; throw error }
            let (changed, current) = state.withLock { s -> (Bool, SubmissionRecord?) in
                let changed = s.end(id.rawValue, from: version!)
                return (changed, changed ? s.submissions.get(id) : value)
            }
            if !changed || current != nil { return current }
        }
    }
    func scanConversations(_ query: ConversationQuery, limit: Int, cursor: Cursor?, context: ChordContext) async throws -> Page<ConversationRecord, Cursor> {
        try await backend.scanConversations(query, limit: limit, cursor: cursor, context: context)
    }
    func entry(_ id: EntryID, context: ChordContext) async throws -> EntryLookup? { try await backend.entry(id, context: context) }
    func entry(_ conversationId: ConversationID, id: EntryID, context: ChordContext) async throws -> EntryLookup? {
        try await backend.entry(conversationId, id: id, context: context)
    }
    func findLatestHeadMarker(_ conversationId: ConversationID, atOrBeforeEntryId: EntryID?, context: ChordContext) async throws -> EntryRecord? {
        try await backend.findLatestHeadMarker(conversationId, atOrBeforeEntryId: atOrBeforeEntryId, context: context)
    }
    func scanEntries(_ query: EntryQuery, limit: Int, cursor: Cursor?, context: ChordContext) async throws -> Page<EntryRecord, Cursor> {
        try await backend.scanEntries(query, limit: limit, cursor: cursor, context: context)
    }
    func scanTasks(_ query: TaskQuery, limit: Int, cursor: Cursor?, context: ChordContext) async throws -> Page<TaskRecord, Cursor> {
        try await backend.scanTasks(query, limit: limit, cursor: cursor, context: context)
    }
    func scanSubmissions(_ query: SubmissionQuery, limit: Int, cursor: Cursor?, context: ChordContext) async throws -> Page<SubmissionRecord, Cursor> {
        try await backend.scanSubmissions(query, limit: limit, cursor: cursor, context: context)
    }
    func submissionByRequest(_ conversationId: ConversationID, requestId: String, context: ChordContext) async throws -> SubmissionRecord? {
        try await backend.submissionByRequest(conversationId, requestId: requestId, context: context)
    }
    func findDocument(_ address: DocumentAddress, at: DocumentPoint, context: ChordContext) async throws -> DocumentRecord? {
        try await backend.findDocument(address, at: at, context: context)
    }
    func document(_ id: DocumentID, at: DocumentPoint, context: ChordContext) async throws -> StoredDocument? {
        try await backend.document(id, at: at, context: context)
    }
    func scanDocuments(_ query: DocumentQuery, limit: Int, cursor: Cursor?, context: ChordContext) async throws -> Page<DocumentRecord, Cursor> {
        try await backend.scanDocuments(query, limit: limit, cursor: cursor, context: context)
    }
    func close(context: ChordContext) async throws { try await backend.close(context: context) }
}
