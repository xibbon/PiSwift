import Foundation
import PiSwiftChord

/// JSONL storage with memory indexes and recoverable sidecar files.
/// Retains the full state in RAM. Each open replays all of main.jsonl. The main file
/// is never compacted. Use one writable storage for each directory. A read-only open
/// holds a snapshot and does not change the files. A writable open can repair file tails.
public actor JsonlStorage: DurableStorage {
    let fileSystem: any FileSystem
    let directory: String
    let mainPath: String
    let fsync: Bool
    let readOnly: Bool
    var mainSize: Int64 = 0
    let memory = MemoryStorage()
    var currentOnlyDocuments = Set<Int64>()
    var liveTaskSidecars = Set<Int64>()
    private var closed = false
    private var poisonError: JsonlStoragePoisonedError?
    private var occupied = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    var queuedOperationCount: Int { waiters.count }

    private init(fileSystem: any FileSystem, directory: String, mainPath: String, options: JsonlStorageOptions) {
        self.fileSystem = fileSystem; self.directory = directory; self.mainPath = mainPath; fsync = options.fsync; readOnly = options.readOnly
    }

    /// Opens or creates a directory. Read-only mode opens existing files without changes.
    public static func open(directory: String, fileSystem: any FileSystem, options: JsonlStorageOptions = .init(), context: ChordContext = .background) async throws -> JsonlStorage {
        let absolute = try jsonlFileResult(await fileSystem.absolutePath(directory, context: context), action: "path resolution")
        if !options.readOnly {
            try jsonlFileResult(await fileSystem.createDir(absolute, options: .init(recursive: true), context: context), action: "directory creation")
        }
        let main = try jsonlFileResult(await fileSystem.joinPath([absolute, "main.jsonl"], context: context), action: "path join")
        // A writer can reclaim a sidecar after recovery reads an older main file.
        // As in v1.5.2, retry corruption only when the main file changed, with at most five attempts.
        var attempt = 1
        while true {
            let storage = JsonlStorage(fileSystem: fileSystem, directory: absolute, mainPath: main, options: options)
            do {
                try await storage.recover(context: context)
                return storage
            } catch {
                guard options.readOnly, attempt < 5, error is JsonlCorruptionError,
                      await storage.mainChanged(context: context) else { throw error }
                attempt += 1
            }
        }
    }

    /// Opens or creates storage through the local file system.
    public static func open(directory: String, options: JsonlStorageOptions = .init(), context: ChordContext = .background) async throws -> JsonlStorage {
        try await open(directory: directory, fileSystem: LocalExecutionEnv(), options: options, context: context)
    }

    // Hold this gate across each suspension. The actor alone permits reentrant I/O.
    private func acquire() async {
        if !occupied { occupied = true; return }
        await withCheckedContinuation { waiters.append($0) }
    }
    private func release() {
        if waiters.isEmpty { occupied = false }
        else { waiters.removeFirst().resume() }
    }
    private func assertUsable() throws {
        if closed { throw DurableStorageError.closed(backend: "JsonlStorage") }
        if let poisonError { throw poisonError }
    }
    private func poison(_ cause: any Error) -> JsonlStoragePoisonedError {
        if let poisonError { return poisonError }
        let error = JsonlStoragePoisonedError(cause: cause); poisonError = error; return error
    }
    private func withStore<Value: Sendable>(_ operation: (MemoryStorage) async throws -> Value) async throws -> Value {
        await acquire(); defer { release() }
        try assertUsable()
        return try await operation(memory)
    }

    /// Stores each accepted batch before it sends its receipt.
    public func commit(_ batches: [[StorageWrite]], receive: @Sendable (Int, Seq) -> Void, context: ChordContext) async throws -> CommitResult {
        await acquire(); defer { release() }
        try assertUsable()
        if readOnly { throw JsonlStorageReadOnlyError() }
        var seqs: [Seq] = []
        var commits: [JsonlEncoded] = []
        var replacements: [(file: String, content: String)] = []
        var refused: (any Error & Sendable)?
        do {
            for writes in batches {
                let prepared: PreparedMemoryCommit
                do { prepared = try await memory.prepareCommit(writes) }
                catch let error as DurableStorageError where error.isCommitRefusal { refused = error; break }
                catch let error as DocumentCopyFailure { refused = error; break }
                let encoded = try encodeCommit(seq: prepared.seq, writes: prepared.writes)
                // Keep later records when an earlier batch replaces their sidecar.
                for sidecar in encoded.sidecars {
                    if let index = replacements.firstIndex(where: { $0.file == sidecar.file }) {
                        replacements[index].content += sidecar.content
                    }
                }
                for replacement in planReclamations(writes: prepared.writes, encoded: encoded) {
                    if let index = replacements.firstIndex(where: { $0.file == replacement.file }) {
                        replacements[index] = replacement
                    } else { replacements.append(replacement) }
                }
                seqs.append(await prepared.apply())
                adoptSidecarState(writes: prepared.writes)
                commits.append(encoded)
            }
            if !commits.isEmpty { try await appendCommits(commits, context: context) }
        } catch {
            // Reads must not observe memory state that the files did not confirm.
            if seqs.isEmpty { throw error }
            throw poison(error)
        }
        for (index, seq) in seqs.enumerated() { receive(index, seq) }
        await reclaimSidecars(replacements, context: context)
        return CommitResult(stored: seqs.count, refused: refused)
    }

    /// Allocates an unused positive ID from the shared record namespace.
    public func mintId<Kind: DurableIDKind>() async throws -> DurableID<Kind> {
        try await withStore { try await $0.mintId() }
    }
    /// Returns a conversation by ID, or nil when that ID is absent.
    public func conversation(_ id: ConversationID, context: ChordContext) async throws -> ConversationRecord? {
        try await withStore { try await $0.conversation(id, context: context) }
    }
    /// Returns a page of conversations that match all query filters.
    public func scanConversations(_ query: ConversationQuery, limit: Int, cursor: Cursor?, context: ChordContext) async throws -> Page<ConversationRecord, Cursor> {
        try await withStore { try await $0.scanConversations(query, limit: limit, cursor: cursor, context: context) }
    }
    /// Reads the entry identified by ID, or nil when it is absent.
    public func entry(_ id: EntryID, context: ChordContext) async throws -> EntryLookup? {
        try await withStore { try await $0.entry(id, context: context) }
    }
    /// Reads the entry identified by ID, or nil when it is absent.
    public func entry(_ conversationId: ConversationID, id: EntryID, context: ChordContext) async throws -> EntryLookup? {
        try await withStore { try await $0.entry(conversationId, id: id, context: context) }
    }
    /// Returns the newest visible head marker at or below the inclusive entry cutoff.
    public func findLatestHeadMarker(_ conversationId: ConversationID, atOrBeforeEntryId: EntryID?, context: ChordContext) async throws -> EntryRecord? {
        try await withStore { try await $0.findLatestHeadMarker(conversationId, atOrBeforeEntryId: atOrBeforeEntryId, context: context) }
    }
    /// Returns a page of entries in the visible ancestry and requested range.
    public func scanEntries(_ query: EntryQuery, limit: Int, cursor: Cursor?, context: ChordContext) async throws -> Page<EntryRecord, Cursor> {
        try await withStore { try await $0.scanEntries(query, limit: limit, cursor: cursor, context: context) }
    }
    /// Returns the current stored task record, or nil when absent.
    public func task(_ id: TaskID, context: ChordContext) async throws -> TaskRecord? {
        try await withStore { try await $0.task(id, context: context) }
    }
    /// Returns a page of tasks that match all query filters.
    public func scanTasks(_ query: TaskQuery, limit: Int, cursor: Cursor?, context: ChordContext) async throws -> Page<TaskRecord, Cursor> {
        try await withStore { try await $0.scanTasks(query, limit: limit, cursor: cursor, context: context) }
    }
    /// Returns the current durable submission, or nil when it is absent.
    public func submission(_ id: SubmissionID, context: ChordContext) async throws -> SubmissionRecord? {
        try await withStore { try await $0.submission(id, context: context) }
    }
    /// Returns a page of submissions that match all query filters.
    public func scanSubmissions(_ query: SubmissionQuery, limit: Int, cursor: Cursor?, context: ChordContext) async throws -> Page<SubmissionRecord, Cursor> {
        try await withStore { try await $0.scanSubmissions(query, limit: limit, cursor: cursor, context: context) }
    }
    /// Returns the submission for the conversation-scoped request key, or nil.
    public func submissionByRequest(_ conversationId: ConversationID, requestId: String, context: ChordContext) async throws -> SubmissionRecord? {
        try await withStore { try await $0.submissionByRequest(conversationId, requestId: requestId, context: context) }
    }
    /// Finds the document incarnation alive at the address and requested point.
    public func findDocument(_ address: DocumentAddress, at: DocumentPoint, context: ChordContext) async throws -> DocumentRecord? {
        try await withStore { try await $0.findDocument(address, at: at, context: context) }
    }
    /// Returns the stored document incarnation at the requested point, or nil when absent.
    public func document(_ id: DocumentID, at: DocumentPoint, context: ChordContext) async throws -> StoredDocument? {
        try await withStore { try await $0.document(id, at: at, context: context) }
    }
    /// Returns a page of document incarnations alive at the requested point.
    public func scanDocuments(_ query: DocumentQuery, limit: Int, cursor: Cursor?, context: ChordContext) async throws -> Page<DocumentRecord, Cursor> {
        try await withStore { try await $0.scanDocuments(query, limit: limit, cursor: cursor, context: context) }
    }
    /// Releases this object's resources and rejects later operations.
    public func close(context: ChordContext) async throws {
        await acquire(); defer { release() }
        if closed { return }
        closed = true
        try await memory.close(context: context)
    }

    func mainChanged(context: ChordContext) async -> Bool {
        guard case .success(let info) = await fileSystem.fileInfo(mainPath, context: context) else { return false }
        return info.size != mainSize
    }

    func resolveFile(_ file: String, context: ChordContext) async throws -> String {
        try jsonlFileResult(await fileSystem.joinPath([directory, file], context: context), action: "path join")
    }
}

/// Opens or creates JSONL storage through the local file system.
/// This is the Swift equivalent of the upstream openNodeJsonlStorage function.
/// It uses the same local file system as JsonlStorage.open(directory:options:context:).
public func openLocalJsonlStorage(directory: String, options: JsonlStorageOptions = .init(), context: ChordContext = .background) async throws -> JsonlStorage {
    try await JsonlStorage.open(directory: directory, options: options, context: context)
}
