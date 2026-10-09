import Testing
import PiSwiftChord
@testable import PiSwiftDurable

private let tableWork = TaskKind<JSONObject, JSONObject>(name: "test.work", version: 1, initial: { _ in ["phase": "start"] })
private let tableProgress = try! TaskDocToken<JSONObject>(kind: "test.progress", version: 1, initial: { ["lines": []] })
private let tableStep = try! TaskDocFamilyToken<JSONObject, JSONValue>(kind: "test.step", version: 1, initial: { _ in ["lines": []] })
private let tableNotes = try! RewindableConversationDocToken<JSONObject>(kind: "test.notes", version: 1, fork: .asOf, initial: { ["text": ""] })

private func tableTask(_ session: Session, _ conversation: ConversationID, withDocument: Bool = false) async throws -> TaskID {
    try await session.commit({ tx in
        let id = try await tx.createTask(tableWork, input: ["path": "a"], options: TaskOptions(ownership: .conversation(), conversationId: conversation))
        if withDocument { try await tx.doc(tableProgress, taskId: id).set("lines", ["started"]) }
        return id
    }, context: .background)
}

private func tableTerminal(_ task: TaskRecord) -> TaskRecord {
    TaskRecord(id: task.id, conversationId: task.conversationId, kind: task.kind, version: task.version,
               input: task.input, state: .terminal(outcome: .completed(result: ["ok": true])),
               background: task.background, abortRequested: task.abortRequested)
}

private func tableReplace(_ task: TaskRecord, conversation: ConversationID? = nil, abortRequested: Bool? = nil,
                          state: TaskState? = nil, memos: JSONObject? = nil) -> TaskRecord {
    TaskRecord(id: task.id, conversationId: conversation ?? task.conversationId, kind: task.kind, version: task.version,
               input: task.input, state: state ?? task.state, owner: task.owner, background: task.background,
               abortRequested: abortRequested ?? task.abortRequested, memos: memos)
}

private func tableError(_ text: String, _ operation: () async throws -> Void) async {
    do { try await operation(); Issue.record("Expected error: \(text)") }
    catch { #expect(String(describing: error).contains(text)) }
}

private struct TableHeldConversationHooks: SessionHooks {
    let entered = SessionTestGate()
    let release = SessionTestGate()
    func conversationCreated(_ tx: Transaction, record: ConversationRecord) async throws {
        entered.release()
        await release.wait()
    }
}

private func tablePendingConversation(callbackFails: Bool) async throws {
    let storage = ControlledStorage()
    let hooks = TableHeldConversationHooks()
    let session = try await Session.open(storage: storage, hooks: hooks, context: .background)
    let transactions = SessionTestLog<Transaction>()
    let operations = SessionTestLog<Task<ConversationRecord, any Error>>()
    let observer = Task {
        await hooks.entered.wait()
        let tx = try #require(transactions.values.first)
        await tx.waitUntilSettled()
        hooks.release.release()
    }
    await tableError(callbackFails ? "callback failed" : "Session commit callback settled before its pending Tx operations") {
        try await session.commit({ tx in
            transactions.append(tx)
            operations.append(Task { try await tx.createConversation(ownership: .ownerless()) })
            await hooks.entered.wait()
            if callbackFails { throw SessionError.message("callback failed") }
        }, context: .background)
    }
    try await observer.value
    let operation = try #require(operations.values.first)
    do { _ = try await operation.value; Issue.record("Pending table operation was not rejected") }
    catch { #expect(String(describing: error) == "Transaction has settled") }
    #expect(await storage.commits.isEmpty)
    #expect(await storage.admittedCommits.isEmpty)
    _ = try await createConversation(session)
    #expect(await storage.commits.count == 1)
}

@Suite("PiSwiftDurableTests.SessionTables")
struct SessionTableTests {
    // session-tables.test.ts:82.
    @Test func SessionTablesReadBeforeWrite() async throws {
        let h = try await openTestSession()
        let conversation = try await createConversation(h.session)
        try await h.session.commit({ tx in
            #expect(try await tx.conversation(conversation) == ConversationRecord(id: conversation))
            #expect(try await tx.scanConversations(ConversationQuery(), limit: 1).items == [ConversationRecord(id: conversation)])
            #expect(try await tx.scanTasks(TaskQuery(conversationId: conversation), limit: 10).items.isEmpty)
            #expect(try await tx.scanEntries(EntryQuery(conversationId: conversation), limit: 10).items.isEmpty)
            _ = try await tx.appendEntry(conversation, value: EntryDraft(kind: "note"))
            await tableError("Tx.conversation() cannot read tables") { _ = try await tx.conversation(conversation) }
            await tableError("Tx.task() cannot read tables") { _ = try await tx.task(TaskID(1)) }
            await tableError("Tx.entry() cannot read tables") { _ = try await tx.entry(EntryID(1)) }
            await tableError("Tx.scanConversations() cannot read tables") { _ = try await tx.scanConversations(ConversationQuery(), limit: 10) }
            await tableError("Tx.scanEntries() cannot read tables") { _ = try await tx.scanEntries(EntryQuery(conversationId: conversation), limit: 10) }
            await tableError("Tx.scanTasks() cannot read tables") { _ = try await tx.scanTasks(TaskQuery(), limit: 10) }
            await tableError("Tx.latestHeadMarker() cannot read tables") { _ = try await tx.latestHeadMarker(conversation) }
            await tableError("Tx.submissionByRequest() cannot read tables") { _ = try await tx.submissionByRequest(conversation, requestId: "x") }
            try await tx.doc(tableNotes, conversationId: conversation).set("text", "after write")
        }, context: .background)
        #expect(try await h.session.snapshot(tableNotes, conversationId: conversation, context: .background) == ["text": "after write"])
    }

    // session-tables.test.ts:104.
    @Test func SessionTablesScanLimitsAndCursors() async throws {
        let h = try await openTestSession()
        var ids: [ConversationID] = []
        for _ in 0..<3 { ids.append(try await createConversation(h.session)) }
        try await h.session.commit({ tx in
            let first = try await tx.scanConversations(ConversationQuery(), limit: 2)
            #expect(first.items.map(\.id) == Array(ids.prefix(2)))
            #expect(first.next != nil)
            let second = try await tx.scanConversations(ConversationQuery(), limit: 2, cursor: first.next)
            #expect(second.items.map(\.id) == Array(ids.suffix(1)))
            #expect(second.next == nil)
        }, context: .background)
    }

    // session-tables.test.ts:121.
    @Test func SessionTablesSetTaskIsWrite() async throws {
        let h = try await openTestSession()
        let conversation = try await createConversation(h.session)
        let id = try await tableTask(h.session, conversation)
        try await h.session.commitWith({ tx in
            let task = try #require(await tx.task(id))
            try tx.setTask(task)
            await tableError("Tx.task() cannot read tables") { _ = try await tx.task(id) }
        }, context: .background)
    }

    // session-tables.test.ts:132. Value equality replaces JavaScript reference identity.
    @Test func SessionTablesMintIDsAndPublish() async throws {
        let h = try await openTestSession()
        let created = try await h.session.commit({ tx in
            let conversation = try await tx.createConversation(ownership: .ownerless())
            let first = try await tx.appendEntry(conversation.id, value: EntryDraft(kind: "note", data: "one"))
            let headed = try await tx.appendEntry(conversation.id, value: EntryDraft(kind: "summary", head: .self))
            let task = try await tx.createTask(tableWork, input: ["path": "x"], options: TaskOptions(ownership: .conversation(), conversationId: conversation.id, background: true))
            return (conversation, first, headed, task)
        }, context: .background)
        #expect(Set([created.0.id.rawValue, created.1.id.rawValue, created.2.id.rawValue, created.3.rawValue]).count == 4)
        #expect(created.2.head == created.2.id)
        #expect(created.1 == EntryRecord(id: created.1.id, conversationId: created.0.id, kind: "note", data: "one"))
        #expect(try await h.storage.entry(created.2.id, context: .background)?.entry == created.2)
        #expect(try await h.storage.task(created.3, context: .background) == TaskRecord(id: created.3, conversationId: created.0.id, kind: "test.work", version: 1, input: ["path": "x"], state: .pending(checkpoint: ["phase": "start"]), background: true))
        let changes = try #require(h.publications.values.last).changes
        #expect(changes.count == 4)
        #expect(changes.contains(.conversation(created.0)))
        #expect(changes.contains(.entry(created.1)))
        #expect(changes.contains(.entry(created.2)))
        #expect(await h.storage.admittedCommits.last?.count == changes.count)
        await tableError("requires options.conversationId") {
            _ = try await h.session.commit({ tx in try await tx.createTask(tableWork, input: [:], options: TaskOptions(ownership: .conversation())) }, context: .background)
        }
        await tableError("Conversation 12345 does not exist") {
            _ = try await h.session.commit({ tx in try await tx.appendEntry(ConversationID(12345), value: EntryDraft(kind: "note")) }, context: .background)
        }
    }

    // session-tables.test.ts:188.
    @Test func SessionTablesStagedConversationOwner() async throws {
        let h = try await openTestSession()
        let parent = try await createConversation(h.session)
        let created = try await h.session.commit({ tx in
            let supervisor = try await tx.createTask(tableWork, input: ["path": "background"], options: TaskOptions(ownership: .conversation(), conversationId: parent, background: true))
            let child = try await tx.createConversation(ownership: .task(taskId: supervisor))
            return (supervisor, child)
        }, context: .background)
        #expect(created.1.owner == ConversationOwner(conversationId: parent, taskId: created.0))
        #expect(try await h.storage.conversation(created.1.id, context: .background) == created.1)
        await tableError("cannot change conversations") {
            try await h.session.commitWith({ tx in
                let task = try #require(await tx.task(created.0))
                try tx.setTask(tableReplace(task, conversation: created.1.id))
            }, context: .background)
        }
        #expect(try await h.storage.task(created.0, context: .background)?.conversationId == parent)
    }

    // session-tables.test.ts:213.
    @Test func SessionTablesRejectInvalidOwnersAtomically() async throws {
        let h = try await openTestSession()
        let parent = try await createConversation(h.session)
        let rejected = SessionTestLog<ConversationID>()
        let rejectedTask = SessionTestLog<TaskID>()
        await tableError("cannot change conversations") {
            try await h.session.commitWith({ tx in
                let id = try await tx.createTask(tableWork, input: [:], options: TaskOptions(ownership: .conversation(), conversationId: parent))
                rejectedTask.append(id)
                let candidate = try #require(tx.stagedTasks().first)
                try tx.setTask(tableReplace(candidate, conversation: ConversationID(998)))
            }, context: .background)
        }
        #expect(try await h.storage.task(#require(rejectedTask.values.first), context: .background) == nil)
        await tableError("Conversation owner task 999 does not exist") {
            _ = try await h.session.commit({ tx in try await tx.createConversation(ownership: .task(taskId: TaskID(999))) }, context: .background)
        }
        for terminal in [false, true] {
            await tableError(terminal ? "is terminal" : "is abort-marked") {
                try await h.session.commitWith({ tx in
                    let id = try await tx.createTask(tableWork, input: [:], options: TaskOptions(ownership: .conversation(), conversationId: parent))
                    rejected.append(try await tx.createConversation(ownership: .task(taskId: id)).id)
                    let task = try #require(tx.stagedTasks().first)
                    try tx.setTask(terminal ? tableTerminal(task) : tableReplace(task, abortRequested: true))
                }, context: .background)
            }
        }
        for id in rejected.values { #expect(try await h.storage.conversation(id, context: .background) == nil) }
        let terminalId = try await tableTask(h.session, parent)
        try await h.session.commitWith({ tx in try tx.setTask(tableTerminal(#require(await tx.task(terminalId)))) }, context: .background)
        await tableError("is terminal") {
            _ = try await h.session.commit({ tx in try await tx.createConversation(ownership: .task(taskId: terminalId)) }, context: .background)
        }
    }

    // session-tables.test.ts:303. Swift values copy on write; nil replaces undefined.
    @Test func SessionTablesOwnStrictJSON() async throws {
        let h = try await openTestSession()
        let conversation = try await createConversation(h.session)
        var payload: JSONObject = ["nested": ["value": 1]]
        let entry = try await h.session.commit({ tx in
            let created = try await tx.appendEntry(conversation, value: EntryDraft(kind: "data", data: .object(payload)))
            payload["nested"] = ["value": 2]
            return created
        }, context: .background)
        #expect(try await h.storage.entry(entry.id, context: .background)?.entry.data == ["nested": ["value": 1]])
        let omitted = try await h.session.commit({ tx in try await tx.appendEntry(conversation, value: EntryDraft(kind: "omitted")) }, context: .background)
        #expect(omitted.data == nil)
        #expect(try JSONValue(encoding: omitted)["data"] == nil)
        let count = await h.storage.commits.count
        do {
            _ = try await h.session.commit({ tx in try await tx.appendEntry(conversation, value: EntryDraft(kind: "invalid", data: .number(.nan))) }, context: .background)
            Issue.record("Expected strict JSON rejection")
        } catch { #expect(await h.storage.commits.count == count) }
    }

    // session-tables.test.ts:330.
    @Test func SessionTablesReplaceTaskRecords() async throws {
        let h = try await openTestSession()
        let conversation = try await createConversation(h.session)
        let id = try await tableTask(h.session, conversation)
        try await h.session.commitWith({ tx in
            let task = try #require(await tx.task(id))
            try tx.setTask(tableReplace(task, state: .running(checkpoint: ["phase": "next", "step": 2]), memos: ["choice": "b"]))
        }, context: .background)
        let updated = try #require(await h.storage.task(id, context: .background))
        #expect(updated.state == .running(checkpoint: ["phase": "next", "step": 2]))
        #expect(updated.memos == ["choice": "b"])
        #expect(updated.startedAt == 1_000)
    }

    // session-tables.test.ts:354.
    @Test func SessionTablesCreateTaskAndDocument() async throws {
        let h = try await openTestSession()
        let conversation = try await createConversation(h.session)
        let id = try await h.session.commit({ tx in
            let id = try await tx.createTask(tableWork, input: [:], options: TaskOptions(ownership: .conversation(), conversationId: conversation))
            try await tx.doc(tableProgress, taskId: id).set("lines", ["created"])
            try await tx.doc(tableStep, taskId: id, key: "one", seed: .null).set("lines", ["step"])
            return id
        }, context: .background)
        #expect(try await h.session.snapshot(tableProgress, taskId: id, context: .background) == ["lines": ["created"]])
        let publication = try #require(h.publications.values.last)
        #expect(publication.changes.contains { if case .task(let task) = $0 { return task.id == id }; return false })
        #expect(documentChanges(publication).count == 2)
        #expect(documentChanges(publication).allSatisfy { $0.conversationId == conversation })
        try await h.session.commit({ tx in
            _ = try await tx.createConversation(ownership: .ownerless())
            try await tx.doc(tableProgress, taskId: id).set("lines", ["committed task"])
        }, context: .background)
        #expect(documentChanges(try #require(h.publications.values.last)).first?.conversationId == conversation)
    }

    // session-tables.test.ts:387.
    @Test func SessionTablesRejectTerminalTaskDocument() async throws {
        let h = try await openTestSession()
        let conversation = try await createConversation(h.session)
        let id = try await tableTask(h.session, conversation, withDocument: true)
        try await h.session.commitWith({ tx in
            let task = try #require(await tx.task(id))
            let progress = try await tx.doc(tableProgress, taskId: id)
            try tx.setTask(tableTerminal(task))
            await tableError("Task \(id.rawValue) is terminal") { _ = try await tx.doc(tableProgress, taskId: id) }
            await tableError("Task \(id.rawValue) is terminal") { _ = try await tx.doc(tableStep, taskId: id, key: "late", seed: .null) }
            #expect(throws: SessionError.self) { try tx.setTask(task) }
            try progress.set("lines", ["final"])
        }, context: .background)
        await tableError("Task \(id.rawValue) is terminal") {
            _ = try await h.session.commit({ tx in try await tx.doc(tableProgress, taskId: id) }, context: .background)
        }
    }

    // session-tables.test.ts:405.
    @Test func SessionTablesRetireAllTaskDocuments() async throws {
        let h = try await openTestSession()
        let conversation = try await createConversation(h.session)
        let id = try await tableTask(h.session, conversation, withDocument: true)
        try await h.session.commit({ tx in try await tx.doc(tableStep, taskId: id, key: "committed", seed: .null).set("lines", ["x"]) }, context: .background)
        let published = h.publications.count
        try await h.session.commitWith({ tx in
            let task = try #require(await tx.task(id))
            try await tx.doc(tableStep, taskId: id, key: "new", seed: .null).set("lines", ["created then retired"])
            try tx.setTask(tableTerminal(task))
        }, context: .background)
        let writes = try #require(await h.storage.commits.last)
        #expect(writes.count == 5)
        #expect(writes.filter { $0.type == "task" }.count == 1)
        #expect(writes.filter { $0.type == "document.create" }.count == 1)
        #expect(writes.filter { $0.type == "document.retire" }.count == 3)
        #expect(h.publications.count == published + 1)
        let documents = documentChanges(try #require(h.publications.values.last))
        #expect(documents.count == 3)
        #expect(documents.allSatisfy { $0.value == nil && $0.ops.isEmpty && $0.conversationId == conversation })
        #expect(try await h.session.snapshot(tableProgress, taskId: id, context: .background) == nil)
        #expect(try await h.session.snapshot(tableStep, taskId: id, key: "committed", context: .background) == nil)
        #expect(try await h.storage.scanDocuments(DocumentQuery(scope: .task(taskId: id), at: .current), limit: 10, cursor: nil, context: .background).items.isEmpty)
        await tableError("Task \(id.rawValue) is already terminal") {
            try await h.session.commitWith({ tx in try tx.setTask(tableTerminal(#require(await tx.task(id)))) }, context: .background)
        }
    }

    // session-tables.test.ts:451.
    @Test func SessionTablesValidateDocumentOwners() async throws {
        let h = try await openTestSession()
        await tableError("Task 4242 does not exist") {
            _ = try await h.session.commit({ tx in try await tx.doc(tableProgress, taskId: TaskID(4242)) }, context: .background)
        }
        await tableError("Conversation 4242 does not exist") {
            _ = try await h.session.commit({ tx in try await tx.doc(tableNotes, conversationId: ConversationID(4242)) }, context: .background)
        }
    }

    @Test func SessionTablesForkEdgeAndDocumentCopy() async throws {
        let h = try await openTestSession()
        let conversation = try await createConversation(h.session)
        let entry = try await h.session.commit({ tx in try await tx.appendEntry(conversation, value: EntryDraft(kind: "note")) }, context: .background)
        let child = try await h.session.commit({ tx in try await tx.forkConversation(conversation, at: entry.id, ownership: .ownerless()) }, context: .background)
        #expect(child.parent == ConversationParent(conversationId: conversation, at: entry.id))
        let current = try ConversationDocToken<JSONObject>(kind: "copy", version: 1, fork: .current, initial: { [:] })
        try await h.session.commit({ tx in _ = try await tx.doc(current, conversationId: conversation) }, context: .background)
        let count = await h.storage.commits.count
        let copiedChild = try await h.session.commit({ tx in
            try await tx.forkConversation(conversation, at: entry.id, ownership: .ownerless())
        }, context: .background)
        #expect(try await h.session.snapshot(current, conversationId: copiedChild.id, context: .background) == [:])
        #expect(await h.storage.commits.count == count + 1)
        #expect(documentCopyChanges(h.publications.values.last!).count == 1)
    }

    @Test func SessionTablesPendingConversationSuccess() async throws {
        try await tablePendingConversation(callbackFails: false)
    }

    @Test func SessionTablesPendingConversationFailure() async throws {
        try await tablePendingConversation(callbackFails: true)
    }

    @Test func SessionTablesSettledTypedAppend() async throws {
        let h = try await openTestSession()
        let conversation = try await createConversation(h.session)
        let tx = try await h.session.commit({ tx in tx }, context: .background)
        let token = try EntryKind<Double>("typed")
        await tableError("Transaction has settled") {
            _ = try await tx.appendEntry(token, conversationId: conversation, value: TypedEntryDraft(data: .nan))
        }
        await tableError("Transaction has settled") {
            _ = try await tx.entry(token, id: EntryID(10))
        }
    }

    @Test func SessionTablesSubmissionsAndTaskTimes() async throws {
        let h = try await openTestSession(now: { 4_000 })
        let conversation = try await createConversation(h.session)
        let id = try await tableTask(h.session, conversation)
        let submission = try await h.session.commit({ tx in
            let value = try await tx.createSubmission(.input(conversationId: conversation, requestId: "r"))
            let entry = try await tx.appendEntry(conversation, value: EntryDraft(kind: "input"))
            try tx.placeSubmission(value.id, entry: entry.id)
            try tx.settleSubmission(value.id, settlement: .done(answer: entry.id))
            return value.id
        }, context: .background)
        #expect(try await h.storage.submission(submission, context: .background)?.status == "done")
        try await h.session.commitWith({ tx in
            let task = try #require(await tx.task(id))
            try tx.setTask(tableReplace(task, state: .running(checkpoint: ["phase": "next"])))
            try tx.setTask(tableTerminal(task))
        }, context: .background)
        let task = try #require(await h.storage.task(id, context: .background))
        #expect(task.startedAt == 4_000)
        #expect(task.endedAt == 4_000)
        let write = try await h.session.commit({ tx in try await tx.createSubmission(.write(conversationId: conversation)) }, context: .background)
        await tableError("is not a placed input") {
            try await h.session.commit({ tx in try tx.settleSubmission(write.id, settlement: .done(answer: EntryID(555))) }, context: .background)
        }
        #expect(try await h.storage.submission(write.id, context: .background)?.status == "queued")
    }
}
