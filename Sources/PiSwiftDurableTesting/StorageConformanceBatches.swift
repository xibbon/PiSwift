import Synchronization
import PiSwiftChord
import PiSwiftDurable

extension StorageChecks {
    static func case25(_ h: StorageChecks) async throws {
        let root = try await h.root()
        let first = try await h.mint(), last = try await h.mint(), document = try await h.mint()
        let record = documentRecord(document, "batch.doc", scope(root), ["history": "latest", "fork": "initial"])
        let read = Mutex<Task<JSONValue?, any Error>?>(nil)
        let (result, receipts) = try await h.commitBatches([
            [write("entry", entry(first, root)), create(record, ["count": 1])],
            [change(document, [["s", ["count"], 2]])],
            [write("entry", entry(last, root))],
        ], onReceive: { _, _ in
            read.withLock { if $0 == nil { $0 = Task { try await h.entry(last) } } }
        })
        try StorageAssertions.strictEqual(result.stored, 3)
        try StorageAssertions.ok(result.refused == nil)
        try StorageAssertions.strictEqual(receipts.map(\.index), [0, 1, 2])
        let observed = try await read.withLock { $0 }?.value
        try StorageAssertions.strictEqual(observed?["commitSeq"]?.int64Value, receipts[2].seq.rawValue)
        try StorageAssertions.strictEqual(try await h.entry(first)?["commitSeq"]?.int64Value, receipts[0].seq.rawValue)
        try StorageAssertions.strictEqual(try await h.entry(last)?["commitSeq"]?.int64Value, receipts[2].seq.rawValue)
        try StorageAssertions.deepEqual(try await h.document(document)?["value"], ["count": 2])
        let next = try await h.commit([write("entry", entry(try await h.mint(), root))])
        try StorageAssertions.greaterThan(next, receipts[2].seq.rawValue)
    }

    static func case26(_ h: StorageChecks) async throws {
        let root = try await h.root()
        let first = try await h.mint(), after = try await h.mint(), taskID = try await h.mint()
        let (result, receipts) = try await h.commitBatches([
            [write("entry", entry(first, root))],
            [write("task", task(taskID, root)), write("entry", entry(first, root))],
            [write("entry", entry(after, root))],
        ])
        try StorageAssertions.strictEqual(result.stored, 1)
        try StorageAssertions.ok(result.refused != nil)
        try StorageAssertions.strictEqual(receipts.map(\.index), [0])
        try StorageAssertions.ok(try await h.entry(first) != nil)
        try StorageAssertions.ok(try await h.entry(after) == nil)
        try StorageAssertions.strictEqual(try await h.scan("task").ids, [])
        let (refused, none) = try await h.commitBatches([[write("conversation", ["id": number(root)])]])
        try StorageAssertions.strictEqual(refused.stored, 0)
        try StorageAssertions.ok(refused.refused != nil)
        try StorageAssertions.ok(none.isEmpty)
        try await h.commit([write("entry", entry(after, root))])
        try StorageAssertions.ok(try await h.entry(after) != nil)
    }

    static func case27(_ h: StorageChecks) async throws {
        let root = try await h.root(), document = try await h.mint()
        try await h.commit([create(documentRecord(document, "staged", ["kind": "session"]), ["n": 1])])
        let first = try await h.mint(), second = try await h.mint(), after = try await h.mint()
        let (result, receipts) = try await h.commitBatches([
            [write("entry", entry(first, root))],
            [write("entry", entry(second, root)), retire(document), retire(document)],
            [write("entry", entry(after, root))],
        ])
        try StorageAssertions.strictEqual(result.stored, 1)
        try StorageAssertions.ok(result.refused != nil)
        try StorageAssertions.strictEqual(receipts.map(\.index), [0])
        try StorageAssertions.ok(try await h.entry(first) != nil)
        try StorageAssertions.ok(try await h.entry(second) == nil)
        try StorageAssertions.ok(try await h.entry(after) == nil)
        try StorageAssertions.deepEqual(try await h.document(document)?["value"], ["n": 1])
    }

    static func case28(_ h: StorageChecks) async throws {
        let root = try await h.root(), child = try await h.mint(), source = try await h.mint(), copied = try await h.mint()
        func record(_ id: Int64, _ conversation: Int64) -> JSONValue {
            documentRecord(id, "batch.copy", scope(conversation), ["history": "rewindable", "fork": "asOf"])
        }
        let (result, receipts) = try await h.commitBatches([
            [create(record(source, root), ["count": 1])],
            [change(source, [["s", ["count"], 2]])],
            [write("conversation", ["id": number(child)]), copy(record(copied, child), source)],
        ])
        try StorageAssertions.strictEqual(result.stored, 3)
        try StorageAssertions.ok(result.refused == nil)
        try StorageAssertions.deepEqual(try await h.document(copied)?["value"], ["count": 2])
        try StorageAssertions.deepEqual(try await h.document(source, number(receipts[0].seq.rawValue))?["value"], ["count": 1])
        let later = try await h.mint(), laterCopy = try await h.mint()
        let (refused, none) = try await h.commitBatches([[
            write("conversation", ["id": number(later)]), copy(record(laterCopy, later), source),
            change(source, [["s", ["count"], 3]]),
        ]])
        try StorageAssertions.strictEqual(refused.stored, 0)
        try StorageAssertions.ok(refused.refused != nil)
        try StorageAssertions.ok(none.isEmpty)
        try StorageAssertions.ok(try await h.conversation(later) == nil)
        try StorageAssertions.deepEqual(try await h.document(source)?["value"], ["count": 2])
    }

    static func case29(_ h: StorageChecks) async throws {
        let root = try await h.root(), doneID = try await h.mint(), failedID = try await h.mint()
        let placedDone = submission(doneID, root, ["requestId": "continue-done", "type": "continue", "status": "placed"])
        let placedFailed = submission(failedID, root, ["requestId": "continue-failed", "type": "continue", "status": "placed"])
        try await h.commit([write("submission", placedDone), write("submission", placedFailed)])
        try StorageAssertions.deepEqual(try await h.submission(doneID), placedDone)
        try StorageAssertions.strictEqual(try await h.scan("submission", ["status": "placed"]).items, [placedDone, placedFailed])
        let done = replacing(placedDone, ["status": "done", "answer": number(try await h.mint())])
        let unanswered = replacing(placedFailed, ["status": "unanswered", "reason": "nothing_to_answer"])
        try await h.commit([write("submission", done), write("submission", unanswered)])
        try StorageAssertions.deepEqual(try await h.submission(doneID), done)
        try StorageAssertions.deepEqual(try await h.request(root, "continue-done"), done)
        try StorageAssertions.deepEqual(try await h.submission(failedID), unanswered)
        try StorageAssertions.deepEqual(try await h.request(root, "continue-failed"), unanswered)
    }

    static func case30(_ h: StorageChecks) async throws {
        _ = try await h.root()
        for createFirst in [true, false] {
            let id = try await h.mint()
            let record = documentRecord(id, "twice", ["kind": "session"], ["key": createFirst ? "first" : "last"])
            let creation = create(record, ["x": 1])
            let mutation = change(id, [["s", ["x"], 2]])
            let writes = createFirst ? [creation, mutation] : [mutation, creation]
            let (result, receipts) = try await h.commitBatches([writes])
            try StorageAssertions.strictEqual(result.stored, 0)
            try StorageAssertions.ok(result.refused != nil)
            try StorageAssertions.ok(receipts.isEmpty)
            try StorageAssertions.ok(try await h.document(id) == nil)
        }
    }
}
