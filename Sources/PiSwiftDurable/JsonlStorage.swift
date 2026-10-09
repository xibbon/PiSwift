import Foundation
import PiSwiftChord

/// JSONL storage with memory indexes and recoverable sidecar files.
/// Retains the full state in RAM. Each open replays all of main.jsonl. The main file
/// is never compacted. Use one open storage for each directory. Opening can repair
/// or remove file tails.
public actor JsonlStorage: DurableStorage {
    let fileSystem: any FileSystem
    let directory: String
    let mainPath: String
    let fsync: Bool
    let memory = MemoryStorage()
    var currentOnlyDocuments = Set<Int64>()
    var liveTaskSidecars = Set<Int64>()
    private var closed = false
    private var poisonError: JsonlStoragePoisonedError?
    private var occupied = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    var queuedOperationCount: Int { waiters.count }

    private init(fileSystem: any FileSystem, directory: String, mainPath: String, options: JsonlStorageOptions) {
        self.fileSystem = fileSystem; self.directory = directory; self.mainPath = mainPath; fsync = options.fsync
    }

    /// Opens or creates a directory through the supplied file system.
    public static func open(directory: String, fileSystem: any FileSystem, options: JsonlStorageOptions = .init(), context: ChordContext = .background) async throws -> JsonlStorage {
        let absolute = try jsonlFileResult(await fileSystem.absolutePath(directory, context: context), action: "path resolution")
        try jsonlFileResult(await fileSystem.createDir(absolute, options: .init(recursive: true), context: context), action: "directory creation")
        let main = try jsonlFileResult(await fileSystem.joinPath([absolute, "main.jsonl"], context: context), action: "path join")
        let storage = JsonlStorage(fileSystem: fileSystem, directory: absolute, mainPath: main, options: options)
        try await storage.recover(context: context)
        return storage
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

    /// Stores all writes before it publishes the new memory state.
    public func commit(_ writes: [StorageWrite], context: ChordContext) async throws -> Seq {
        await acquire(); defer { release() }
        try assertUsable()
        let prepared = try await memory.prepareCommit(writes)
        let encoded = try encodeCommit(seq: prepared.seq, writes: prepared.writes)
        let replacements = planReclamations(writes: prepared.writes, encoded: encoded)
        // Resolve all paths before the first append. A path failure has no durable effect.
        var sidecars: [(file: String, content: String, path: String)] = []
        for sidecar in encoded.sidecars {
            sidecars.append((sidecar.file, sidecar.content, try await resolveFile(sidecar.file, context: context)))
        }
        for sidecar in sidecars {
            do {
                try jsonlFileResult(await fileSystem.appendFile(sidecar.path, content: .text(sidecar.content), context: context), action: "append to \(sidecar.file)")
            } catch { throw poison(error) }
        }
        if fsync {
            for sidecar in sidecars {
                do {
                    try jsonlFileResult(await fileSystem.flushFile(sidecar.path, context: context), action: "flush of \(sidecar.file)")
                } catch { throw poison(error) }
            }
        }
        do {
            try jsonlFileResult(await fileSystem.appendFile(mainPath, content: .text(encoded.marker), context: context), action: "append to main.jsonl")
        } catch { throw poison(error) }
        let seq = await prepared.apply()
        adoptSidecarState(writes: prepared.writes)
        await reclaimSidecars(replacements, context: context)
        return seq
    }

    public func mintId<Kind: DurableIDKind>() async throws -> DurableID<Kind> {
        try await withStore { try await $0.mintId() }
    }
    public func conversation(_ id: ConversationID, context: ChordContext) async throws -> ConversationRecord? {
        try await withStore { try await $0.conversation(id, context: context) }
    }
    public func scanConversations(_ query: ConversationQuery, limit: Int, cursor: Cursor?, context: ChordContext) async throws -> Page<ConversationRecord, Cursor> {
        try await withStore { try await $0.scanConversations(query, limit: limit, cursor: cursor, context: context) }
    }
    public func entry(_ id: EntryID, context: ChordContext) async throws -> EntryLookup? {
        try await withStore { try await $0.entry(id, context: context) }
    }
    public func entry(_ conversationId: ConversationID, id: EntryID, context: ChordContext) async throws -> EntryLookup? {
        try await withStore { try await $0.entry(conversationId, id: id, context: context) }
    }
    public func findLatestHeadMarker(_ conversationId: ConversationID, atOrBeforeEntryId: EntryID?, context: ChordContext) async throws -> EntryRecord? {
        try await withStore { try await $0.findLatestHeadMarker(conversationId, atOrBeforeEntryId: atOrBeforeEntryId, context: context) }
    }
    public func scanEntries(_ query: EntryQuery, limit: Int, cursor: Cursor?, context: ChordContext) async throws -> Page<EntryRecord, Cursor> {
        try await withStore { try await $0.scanEntries(query, limit: limit, cursor: cursor, context: context) }
    }
    public func task(_ id: TaskID, context: ChordContext) async throws -> TaskRecord? {
        try await withStore { try await $0.task(id, context: context) }
    }
    public func scanTasks(_ query: TaskQuery, limit: Int, cursor: Cursor?, context: ChordContext) async throws -> Page<TaskRecord, Cursor> {
        try await withStore { try await $0.scanTasks(query, limit: limit, cursor: cursor, context: context) }
    }
    public func submission(_ id: SubmissionID, context: ChordContext) async throws -> SubmissionRecord? {
        try await withStore { try await $0.submission(id, context: context) }
    }
    public func scanSubmissions(_ query: SubmissionQuery, limit: Int, cursor: Cursor?, context: ChordContext) async throws -> Page<SubmissionRecord, Cursor> {
        try await withStore { try await $0.scanSubmissions(query, limit: limit, cursor: cursor, context: context) }
    }
    public func submissionByRequest(_ conversationId: ConversationID, requestId: String, context: ChordContext) async throws -> SubmissionRecord? {
        try await withStore { try await $0.submissionByRequest(conversationId, requestId: requestId, context: context) }
    }
    public func findDocument(_ address: DocumentAddress, at: DocumentPoint, context: ChordContext) async throws -> DocumentRecord? {
        try await withStore { try await $0.findDocument(address, at: at, context: context) }
    }
    public func document(_ id: DocumentID, at: DocumentPoint, context: ChordContext) async throws -> StoredDocument? {
        try await withStore { try await $0.document(id, at: at, context: context) }
    }
    public func scanDocuments(_ query: DocumentQuery, limit: Int, cursor: Cursor?, context: ChordContext) async throws -> Page<DocumentRecord, Cursor> {
        try await withStore { try await $0.scanDocuments(query, limit: limit, cursor: cursor, context: context) }
    }
    public func close(context: ChordContext) async throws {
        await acquire(); defer { release() }
        if closed { return }
        closed = true
        try await memory.close(context: context)
    }

    func resolveFile(_ file: String, context: ChordContext) async throws -> String {
        try jsonlFileResult(await fileSystem.joinPath([directory, file], context: context), action: "path join")
    }
}

/// Opens or creates JSONL storage through the local file system.
public func openLocalJsonlStorage(directory: String, options: JsonlStorageOptions = .init(), context: ChordContext = .background) async throws -> JsonlStorage {
    try await JsonlStorage.open(directory: directory, options: options, context: context)
}
