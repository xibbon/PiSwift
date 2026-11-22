import Testing
import PiSwiftChord
@testable import PiSwiftDurable

private let v160MemoTask = TaskKind<JSONObject, JSONObject>(name: "test.v160.memo", version: 1,
    initial: { _ in ["phase": "start"] })

@Suite("v1.6.0 transaction records")
struct D1V160TransactionTests {
    @Test func signalMemosRetainConsumedAndExpiredStates() throws {
        // v1.6.0 signals.ts:42-55,185-220: memo values are opaque task JSON.
        let raw: JSONValue = ["id": 7, "conversationId": 1, "kind": "test.v160.memo", "version": 1,
            "input": [:], "background": false, "abortRequested": false,
            "state": ["status": "pending", "checkpoint": ["phase": "start"]],
            "memos": ["pi.signal.answer/one": ["version": 1, "value": ["ok": true], "consumed": true],
                      "pi.signal.answer/two": ["expired": true]]]
        let decoded = try raw.decode(TaskRecord.self)
        #expect(decoded.memos?["pi.signal.answer/one"]?["consumed"] == true)
        #expect(decoded.memos?["pi.signal.answer/two"]?["expired"] == true)
        #expect(try JSONValue(encoding: decoded) == raw)
    }

    @Test func stagedLiveTaskWritesMergeMemos() async throws {
        // v1.6.0 transaction.ts:579-584: signal and checkpoint writes in one commit retain both memos.
        let test = try await openTestSession()
        let conversation = try await createConversation(test.session)
        let taskId = try await test.session.commit({ tx in
            try await tx.createTask(v160MemoTask, input: [:], options: TaskOptions(ownership: .conversation(), conversationId: conversation))
        }, context: .background)
        try await test.session.commit({ tx in
            let stored = try #require(try await tx.task(taskId))
            let signal = TaskRecord(id: taskId, conversationId: conversation, kind: stored.kind, version: stored.version,
                input: stored.input, state: stored.state, owner: stored.owner, background: stored.background,
                abortRequested: stored.abortRequested, memos: ["pi.signal.answer/k": ["version": 1, "value": "yes"]])
            try tx.setTask(signal)
            let checkpoint = TaskRecord(id: taskId, conversationId: conversation, kind: stored.kind, version: stored.version,
                input: stored.input, state: .running(checkpoint: ["phase": "next"]), owner: stored.owner,
                background: stored.background, abortRequested: stored.abortRequested,
                memos: ["progress": ["step": 2]])
            try tx.setTask(checkpoint)
        }, context: .background)
        let saved = try #require(await test.storage.task(taskId, context: .background))
        #expect(saved.memos == ["pi.signal.answer/k": ["version": 1, "value": "yes"], "progress": ["step": 2]])
        #expect(saved.state.status == "running")
    }

    @Test func inboxKeepRoundTripsAndRejectsUnknownValues() throws {
        // v1.6.0 inbox.ts:8-18: only an input inbox item stores onAbort: "keep".
        let stored: JSONValue = ["id": 3, "mode": "followUp", "content": "hello", "onAbort": "keep"]
        let item = try stored.decode(InboxItem.self)
        #expect(item.onAbort == .keep)
        #expect(try JSONValue(encoding: item) == stored)
        let badValue: JSONValue = ["id": 3, "mode": "followUp", "content": "hello", "onAbort": "withdraw"]
        #expect(throws: (any Error).self) { try badValue.decode(InboxItem.self) }
        let nullValue: JSONValue = ["id": 3, "mode": "followUp", "content": "hello", "onAbort": .null]
        #expect(throws: (any Error).self) { try nullValue.decode(InboxItem.self) }
        let badWrite: JSONValue = ["id": 3, "mode": "write", "entry": ["kind": "note"], "onAbort": "keep"]
        #expect(throws: (any Error).self) { try badWrite.decode(InboxItem.self) }
    }

    @Test func submissionNotifyRoundTripsAndRejectsMalformedFields() throws {
        // v1.6.0 types.ts:518-531: notify is an optional stored submission base field.
        let raw: JSONValue = ["id": 11, "conversationId": 1, "type": "input", "status": "queued",
            "notify": ["taskId": 7, "key": "answered"]]
        let record = try raw.decode(SubmissionRecord.self)
        #expect(try record.notify == SubmissionNotify(taskId: TaskID(7), key: "answered"))
        #expect(try JSONValue(encoding: record) == raw)
        for bad: JSONValue in [
            ["id": 11, "conversationId": 1, "type": "input", "status": "queued", "notify": ["taskId": 7]],
            ["id": 11, "conversationId": 1, "type": "input", "status": "queued", "notify": ["taskId": "seven", "key": "answered"]]
        ] {
            #expect(throws: (any Error).self) { try bad.decode(SubmissionRecord.self) }
        }
    }

    @Test func notificationTargetSurvivesSubmissionSettlement() async throws {
        // v1.6.0 transaction.ts:1068-1111: settlement keeps the submission's notify field.
        let test = try await openTestSession()
        let conversation = try await createConversation(test.session)
        let notify = SubmissionNotify(taskId: try TaskID(99), key: "answered")
        let id = try await test.session.commit({ tx in
            let entry = try await tx.appendEntry(conversation, value: EntryDraft(kind: "test.note"))
            let created = try await tx.createSubmission(try SubmissionCreate.input(conversationId: conversation,
                notify: notify))
            try tx.placeSubmission(created.id, entry: entry.id)
            try tx.settleSubmission(created.id, settlement: .done(answer: entry.id))
            return created.id
        }, context: .background)
        let saved = try #require(await test.storage.submission(id, context: .background))
        #expect(saved.status == "done")
        #expect(try saved.notify == notify)
        #expect(try JSONValue(encoding: saved)["notify"] == ["taskId": 99, "key": "answered"])
    }
}
