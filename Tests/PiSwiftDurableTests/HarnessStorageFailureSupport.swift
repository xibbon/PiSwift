import PiSwiftChord
import PiSwiftDurableTesting
import Testing
@testable import PiSwiftDurable

/// A distinct error instance lets tests check the first cause without formatting it.
final class HarnessStorageFailure: Error, Sendable {
    let message: String
    init(_ message: String = "disk gone") { self.message = message }
}

/// Injects failures and holds reads without a timer.
actor HarnessFailureStorage: DurableStorage {
    enum Call: Hashable, Sendable { case task, mint, range }
    let base = ControlledStorage()
    private var failures: [Call: any Error] = [:]
    private var closeFailure: (any Error)?
    private var rangeGate: (entered: SessionTestGate, release: SessionTestGate)?
    private var cancelRead: (@Sendable (ChordContext) throws -> Void)?
    private(set) var pages: [String] = []

    func fail(_ call: Call, with error: any Error) { failures[call] = error }
    func failClose(with error: any Error) { closeFailure = error }
    func cancelRange(_ action: @escaping @Sendable (ChordContext) throws -> Void) { cancelRead = action }
    func holdRange() -> (entered: SessionTestGate, release: SessionTestGate) {
        let gate = (entered: SessionTestGate(), release: SessionTestGate())
        rangeGate = gate
        return gate
    }
    private func check(_ call: Call) throws {
        if let error = failures.removeValue(forKey: call) { throw error }
    }
    func commit(_ writes: [StorageWrite], context: ChordContext) async throws -> Seq {
        try await base.commit(writes, context: context)
    }
    func mintId<Kind: DurableIDKind>() async throws -> DurableID<Kind> {
        try check(.mint)
        return try await base.mintId()
    }
    func conversation(_ id: ConversationID, context: ChordContext) async throws -> ConversationRecord? {
        try await base.conversation(id, context: context)
    }
    func scanConversations(_ query: ConversationQuery, limit: Int, cursor: Cursor?, context: ChordContext) async throws -> Page<ConversationRecord, Cursor> {
        try await base.scanConversations(query, limit: limit, cursor: cursor, context: context)
    }
    func entry(_ id: EntryID, context: ChordContext) async throws -> EntryLookup? { try await base.entry(id, context: context) }
    func entry(_ conversationId: ConversationID, id: EntryID, context: ChordContext) async throws -> EntryLookup? {
        try await base.entry(conversationId, id: id, context: context)
    }
    func findLatestHeadMarker(_ conversationId: ConversationID, atOrBeforeEntryId: EntryID?, context: ChordContext) async throws -> EntryRecord? {
        try await base.findLatestHeadMarker(conversationId, atOrBeforeEntryId: atOrBeforeEntryId, context: context)
    }
    func scanEntries(_ query: EntryQuery, limit: Int, cursor: Cursor?, context: ChordContext) async throws -> Page<EntryRecord, Cursor> {
        if limit > 1 {
            pages.append(cursor == nil ? "first" : "next")
            if let gate = rangeGate {
                rangeGate = nil
                gate.entered.release()
                await gate.release.wait()
            }
            try cancelRead?(context)
            try check(.range)
        }
        return try await base.scanEntries(query, limit: limit, cursor: cursor, context: context)
    }
    func task(_ id: TaskID, context: ChordContext) async throws -> TaskRecord? {
        try check(.task)
        return try await base.task(id, context: context)
    }
    func scanTasks(_ query: TaskQuery, limit: Int, cursor: Cursor?, context: ChordContext) async throws -> Page<TaskRecord, Cursor> {
        try await base.scanTasks(query, limit: limit, cursor: cursor, context: context)
    }
    func submission(_ id: SubmissionID, context: ChordContext) async throws -> SubmissionRecord? {
        try await base.submission(id, context: context)
    }
    func scanSubmissions(_ query: SubmissionQuery, limit: Int, cursor: Cursor?, context: ChordContext) async throws -> Page<SubmissionRecord, Cursor> {
        try await base.scanSubmissions(query, limit: limit, cursor: cursor, context: context)
    }
    func submissionByRequest(_ conversationId: ConversationID, requestId: String, context: ChordContext) async throws -> SubmissionRecord? {
        try await base.submissionByRequest(conversationId, requestId: requestId, context: context)
    }
    func findDocument(_ address: DocumentAddress, at: DocumentPoint, context: ChordContext) async throws -> DocumentRecord? {
        try await base.findDocument(address, at: at, context: context)
    }
    func document(_ id: DocumentID, at: DocumentPoint, context: ChordContext) async throws -> StoredDocument? {
        try await base.document(id, at: at, context: context)
    }
    func scanDocuments(_ query: DocumentQuery, limit: Int, cursor: Cursor?, context: ChordContext) async throws -> Page<DocumentRecord, Cursor> {
        try await base.scanDocuments(query, limit: limit, cursor: cursor, context: context)
    }
    func close(context: ChordContext) async throws {
        pages.append("close")
        try await base.close(context: context)
        if let closeFailure { throw closeFailure }
    }
}

func failureNote(_ root: Conversation) async throws -> EntryRecord {
    try await root.commit({ try await $0.appendEntry(root.id, value: .init(kind: "note")) }, context: .background)
}

func expectStorageFailure<T>(_ failure: HarnessStorageFailure,
                             _ operation: () async throws -> T) async {
    do { _ = try await operation(); Issue.record("Storage failure did not reach its caller") }
    catch { #expect((error as? HarnessStorageFailure) === failure) }
}

func expectSessionFailure<T>(_ failure: HarnessStorageFailure,
                             _ operation: () async throws -> T) async {
    do { _ = try await operation(); Issue.record("Failed Session accepted a call") }
    catch {
        guard let failed = error as? SessionFailed else { Issue.record("Expected SessionFailed, got \(error)"); return }
        #expect((failed.cause as? HarnessStorageFailure) === failure)
    }
}

func expectFailedEnd(_ harness: Harness, _ failure: HarnessStorageFailure) async {
    guard case .failed(let error) = await harness.closed else { Issue.record("Session did not end as failed"); return }
    #expect((error as? HarnessStorageFailure) === failure)
}

func expectFailedWatch(_ end: WatchEnd, _ failure: HarnessStorageFailure) {
    guard case .sessionFailed(let error) = end else { Issue.record("Watch did not end with the Session failure"); return }
    #expect((error as? HarnessStorageFailure) === failure)
}

func failureWaitingTask(_ entered: SessionTestGate, signals: SessionTestLog<String>) -> HarnessTestTask {
    harnessOneStep("test.failure-waiting") { _, runtime, _ in
        let ended = SessionTestGate()
        let registration = runtime.signal.addAbortListener { _ in ended.release() }
        entered.release()
        await ended.wait()
        runtime.signal.removeAbortListener(registration)
        signals.append("aborted")
    }
}
