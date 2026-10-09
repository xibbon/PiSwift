import PiSwiftChord
import PiSwiftDurable

extension StorageChecks {
    static func case15(_ h: Self) async throws {
        let root = try await h.root(), id = try await h.mint()
        let record = documentRecord(id, "conversation.notes", scope(root), ["history": "rewindable", "fork": "asOf"])
        var initial: JSONValue = ["items": ["a"], "nested": ["count": 1]]
        let createdAt = try await h.commit([create(record, initial)])
        var appended: JSONValue = ["b"]
        let changedAt = try await h.commit([change(id, [["p", ["items"], 1, 0, appended], ["s", ["nested", "count"], 2]])])
        initial = replacing(initial, ["items": ["a", "caller mutation"]]); appended = ["b", "caller mutation"]
        try StorageAssertions.ok(initial != ["items": ["a"], "nested": ["count": 1]] && appended != ["b"])
        try StorageAssertions.partialDeepEqual(try await h.document(id, number(createdAt)), ["version": 1, "value": ["items": ["a"], "nested": ["count": 1]], "deltasSinceBase": 0])
        var changed = try await h.document(id, number(changedAt))!
        let changedValue: JSONValue = ["items": ["a", "b"], "nested": ["count": 2]]
        try StorageAssertions.deepEqual(changed["value"], changedValue)
        try StorageAssertions.deepEqual(changed["deltasSinceBase"], 1)
        changed = replacing(changed, ["value": ["items": ["a", "b", "read mutation"], "nested": ["count": 2]]])
        try StorageAssertions.ok(changed["value"] != changedValue)
        try StorageAssertions.deepEqual(try await h.document(id)?["value"], changedValue)
        let checkpoint: JSONValue = ["items": ["checkpoint"], "nested": ["count": 3]]
        let checkpointAt = try await h.commit([base(id, checkpoint, version: 2)])
        let replacement: JSONValue = ["items": ["replacement"], "nested": ["count": 4]]
        let replacedAt = try await h.commit([change(id, [["r", replacement]], version: 2)])
        try StorageAssertions.partialDeepEqual(try await h.document(id, number(changedAt)), ["version": 1, "value": changedValue])
        try StorageAssertions.partialDeepEqual(try await h.document(id, number(checkpointAt)), ["version": 2, "value": checkpoint, "deltasSinceBase": 0])
        try StorageAssertions.partialDeepEqual(try await h.document(id, number(replacedAt)), ["value": replacement, "deltasSinceBase": 1])
        try StorageAssertions.deepEqual(try await h.document(id)?["deltasSinceBase"], 1)
        let secondId = try await h.mint()
        let retiredAt = try await h.commit([create(replacing(record, ["id": number(secondId)]), ["items": ["new"]]), retire(id), change(id, [["s", ["retiring"], true]], version: 2)])
        let address: JSONValue = ["kind": record["kind"]!, "scope": record["scope"]!]
        try StorageAssertions.deepEqual(try await h.find(address, number(changedAt))?["id"], number(id))
        try StorageAssertions.partialDeepEqual(try await h.find(address, number(retiredAt)), ["id": number(secondId), "createdAt": number(retiredAt)])
        try StorageAssertions.strictEqual(try await h.scan("document", ["scope": scope(root), "at": number(changedAt)]).ids, [id])
        try StorageAssertions.strictEqual(try await h.scan("document", ["scope": scope(root), "at": number(retiredAt)]).ids, [secondId])
        try StorageAssertions.deepEqual(try await h.document(id, number(retiredAt)), nil)
        try StorageAssertions.deepEqual(try await h.document(secondId)?["value"], ["items": ["new"]])
    }
    static func case16(_ h: Self) async throws {
        let root = try await h.root(), id = try await h.mint()
        let record = documentRecord(id, "conversation.long-tail", scope(root), ["history": "rewindable", "fork": "asOf"])
        let initial: JSONValue = ["revision": 0, "rows": .array((0..<512).map { ["value": .number(Double($0)), "stable": .string("row-\($0)")] })]
        let createdAt = try await h.commit([create(record, initial)])
        var beforeRows = initial["rows"]!.arrayValue!, beforeAt = createdAt
        for revision in 1...24 {
            let index = (revision * 17) % beforeRows.count
            beforeRows[index] = replacing(beforeRows[index], ["value": .number(Double(-revision))])
            beforeAt = try await h.commit([change(id, [["s", ["rows", .number(Double(index)), "value"], .number(Double(-revision))], ["s", ["revision"], .number(Double(revision))]])])
        }
        let before: JSONValue = ["revision": 24, "rows": .array(beforeRows)]
        var replacement: JSONValue = ["revision": 100, "rows": .array((0..<512).map { ["value": .number(Double(10_000 + $0)), "stable": .string("new-\($0)")] })]
        let snapshot = replacement
        let replacementAt = try await h.commit([change(id, [["r", replacement]])])
        var changedRows = replacement["rows"]!.arrayValue!
        changedRows[0] = replacing(changedRows[0], ["value": -999]); replacement = replacing(replacement, ["rows": .array(changedRows)])
        try StorageAssertions.ok(replacement != snapshot)
        var currentRows = snapshot["rows"]!.arrayValue!
        for revision in 101...124 {
            let index = (revision * 19) % currentRows.count
            currentRows[index] = replacing(currentRows[index], ["value": .number(Double(-revision))])
            try await h.commit([change(id, [["s", ["rows", .number(Double(index)), "value"], .number(Double(-revision))], ["s", ["revision"], .number(Double(revision))]])])
        }
        let current: JSONValue = ["revision": 124, "rows": .array(currentRows)]
        try StorageAssertions.deepEqual(try await h.document(id, number(createdAt))?["value"], initial)
        try StorageAssertions.deepEqual(try await h.document(id, number(beforeAt))?["value"], before)
        try StorageAssertions.deepEqual(try await h.document(id, number(replacementAt))?["value"], snapshot)
        var read = try await h.document(id)!
        try StorageAssertions.deepEqual(read["value"], current)
        currentRows[0] = replacing(currentRows[0], ["value": -1_000]); read = replacing(read, ["value": ["revision": 124, "rows": .array(currentRows)]])
        try StorageAssertions.ok(read["value"] != current)
        try StorageAssertions.deepEqual(try await h.document(id)?["value"], current)
    }
    static func case17(_ h: Self) async throws {
        let root = try await h.root(), child = try await h.mint(), child2 = try await h.mint()
        try await h.commit([write("conversation", ["id": number(child)]), write("conversation", ["id": number(child2)])])
        let source = try await h.mint()
        let record = documentRecord(source, "copy.source", scope(root), ["history": "rewindable", "fork": "asOf"])
        let old: JSONValue = ["count": 1, "rows": [["value": "base"]]]
        let current: JSONValue = ["count": 2, "rows": [["value": "base"], ["value": "current"]]]
        let createdAt = try await h.commit([create(record, old, version: 2)])
        try await h.commit([change(source, [["s", ["count"], 2], ["p", ["rows"], 1, 0, [["value": "current"]]]], version: 2)])
        let historical = try await h.mint(), currentCopy = try await h.mint(), retiredCopy = try await h.mint()
        func childRecord(_ id: Int64, _ conversation: Int64) -> JSONValue { replacing(record, ["id": number(id), "scope": scope(conversation)]) }
        try await h.commit([copy(childRecord(historical, child), source, number(createdAt)), copy(childRecord(currentCopy, child2), source), copy(childRecord(retiredCopy, root), source), retire(retiredCopy)])
        try StorageAssertions.partialDeepEqual(try await h.document(historical), ["version": 2, "value": old])
        try StorageAssertions.partialDeepEqual(try await h.document(currentCopy), ["version": 2, "value": current])
        try StorageAssertions.deepEqual(try await h.document(retiredCopy), nil)
        try await h.commit([base(source, ["count": 99, "rows": []], version: 2), retire(source)])
        try StorageAssertions.deepEqual(try await h.document(currentCopy)?["value"], current)
        let latestSource = try await h.mint(), latestCopy = try await h.mint()
        let latestRecord = documentRecord(latestSource, "copy.latest", scope(root), ["history": "latest", "fork": "current"])
        try await h.commit([create(latestRecord, ["retained": "copy"], version: 4)])
        try await h.commit([copy(replacing(latestRecord, ["id": number(latestCopy), "scope": scope(child)]), latestSource)])
        try await h.commit([base(latestSource, ["retained": "source-only"], version: 4), retire(latestSource)])
        try StorageAssertions.partialDeepEqual(try await h.document(latestCopy), ["version": 4, "value": ["retained": "copy"]])
        let conflict = try await h.mint()
        var conflictError: (any Error)?
        do { try await h.commit([copy(childRecord(conflict, child), currentCopy), retire(currentCopy)]) }
        catch { conflictError = error }
        try StorageAssertions.ok(conflictError is StorageRejected, "Expected StorageRejected; got \(String(describing: conflictError))")
        try StorageAssertions.deepEqual(try await h.document(conflict), nil)
        try StorageAssertions.deepEqual(try await h.document(currentCopy)?["value"], current)
        let mismatch = try await h.mint()
        var mismatchError: (any Error)?
        do { try await h.commit([copy(replacing(childRecord(mismatch, child), ["kind": "copy.mismatch"]), currentCopy)]) }
        catch { mismatchError = error }
        try StorageAssertions.ok(mismatchError is StorageRejected, "Expected StorageRejected; got \(String(describing: mismatchError))")
        try StorageAssertions.deepEqual(try await h.document(mismatch), nil)
    }
    static func case18(_ h: Self) async throws {
        try await h.root()
        let id = try await h.mint(), record = documentRecord(id, "session.settings", ["kind": "session"])
        try await h.commit([create(record, ["count": 1])])
        try await h.commit([change(id, [["s", ["count"], 2]])])
        let migrated = try await h.commit([base(id, ["count": 3], version: 2)])
        try StorageAssertions.partialDeepEqual(try await h.document(id), ["version": 2, "value": ["count": 3]])
        try await StorageAssertions.rejects(messageIncludes: "does not retain historical content") { try await h.document(id, number(migrated)) }
        try await StorageAssertions.rejects(messageIncludes: "version transition requires a base") { try await h.commit([change(id, [["s", ["count"], 4]])]) }
        try StorageAssertions.deepEqual(try await h.document(id)?["value"], ["count": 3])
        try await h.commit([retire(id)])
        try StorageAssertions.deepEqual(try await h.document(id), nil)
    }
    static func case19(_ h: Self) async throws {
        let root = try await h.root(), first = try await h.mint(), second = try await h.mint(), conversation = try await h.mint(), tid = try await h.mint()
        let singleton = try await h.mint(), family = try await h.mint(), other = try await h.mint()
        let session: JSONValue = ["kind": "session"], taskScope: JSONValue = ["kind": "task", "taskId": number(tid)]
        let created = try await h.commit([
            write("task", task(tid, root)),
            create(documentRecord(first, "cache", session, ["key": "__proto__"]), ["owner": "first"]),
            create(documentRecord(second, "cache", session, ["key": "constructor"]), ["owner": "second"]),
            create(documentRecord(conversation, "cache", scope(root), ["history": "latest", "fork": "current", "key": "__proto__"]), ["owner": "conversation"]),
            create(documentRecord(singleton, "task.cache", taskScope), ["owner": "singleton"]),
            create(documentRecord(family, "task.cache", taskScope, ["key": "member"]), ["owner": "family"]),
            create(documentRecord(other, "task.other", taskScope), ["owner": "other"])])
        try StorageAssertions.deepEqual(try await h.find(["kind": "cache", "scope": session, "key": "__proto__"])?["id"], number(first))
        try StorageAssertions.strictEqual(try await h.scan("document", ["scope": session, "at": "current"], 1).items.count, 1)
        let page1 = try await h.scan("document", ["scope": session, "at": "current"], 1)
        let page2 = try await h.scan("document", ["scope": session, "at": "current"], 1, page1.next)
        try StorageAssertions.strictEqual(page1.ids + page2.ids, [first, second])
        try StorageAssertions.strictEqual(try await h.scan("document", ["scope": scope(root), "at": "current"]).ids, [conversation])
        try StorageAssertions.deepEqual(try await h.find(["kind": "task.cache", "scope": taskScope])?["id"], number(singleton))
        try StorageAssertions.deepEqual(try await h.find(["kind": "task.cache", "scope": taskScope, "key": "member"])?["id"], number(family))
        try StorageAssertions.strictEqual(try await h.scan("document", ["scope": taskScope, "at": "current", "kind": "task.cache"]).ids, [singleton, family])
        try await StorageAssertions.rejects(messageIncludes: "does not retain historical content") { try await h.document(singleton, number(created)) }
    }
    static func case20(_ h: Self) async throws {
        let root = try await h.root(), first = try await h.mint(), second = try await h.mint()
        let record = documentRecord(first, "singleton", ["kind": "session"])
        try await h.commit([create(record, ["value": 1])])
        try await StorageAssertions.rejects(messageIncludes: "already has a current incarnation") {
            try await h.commit([create(replacing(record, ["id": number(second)]), ["value": 2]), change(first, [])])
        }
        try StorageAssertions.deepEqual(try await h.document(first)?["value"], ["value": 1])
        try StorageAssertions.deepEqual(try await h.document(second), nil)
        let empty = try await h.mint()
        let emptyRecord = documentRecord(empty, "singleton", scope(root), ["key": "empty", "history": "rewindable", "fork": "initial"])
        let emptyAt = try await h.commit([create(emptyRecord, [:]), retire(empty)])
        try StorageAssertions.deepEqual(try await h.document(empty), nil)
        try StorageAssertions.deepEqual(try await h.document(empty, number(emptyAt)), nil)
        try StorageAssertions.deepEqual(try await h.find(["kind": "singleton", "scope": scope(root), "key": "empty"], number(emptyAt)), nil)
    }
    static func case21(_ h: Self) async throws {
        let root = try await h.root(), tid = try await h.mint(), sid = try await h.mint(), did = try await h.mint()
        let task = task(tid, root), input = submission(sid, root, ["requestId": "atomic"])
        let record = documentRecord(did, "atomic", ["kind": "session"])
        let baseline = try await h.commit([write("task", task), write("submission", input), create(record, ["count": 1])])
        let eid = try await h.mint(), conflict = try await h.mint()
        try await StorageAssertions.rejects(messageIncludes: "already has a current incarnation") {
            try await h.commit([write("task", replacing(task, ["state": ["status": "running", "checkpoint": ["phase": "effect"]]])),
                                write("submission", replacing(input, ["status": "unanswered", "reason": "failed"])),
                                write("entry", entry(eid, root, "transient")), create(replacing(record, ["id": number(conflict)]), ["count": 2])])
        }
        try StorageAssertions.deepEqual(try await h.task(tid), task)
        try StorageAssertions.strictEqual(try await h.scan("task", ["status": "pending"]).items, [task])
        try StorageAssertions.deepEqual(try await h.request(root, "atomic"), input)
        try StorageAssertions.deepEqual(try await h.entry(eid), nil)
        try StorageAssertions.deepEqual(try await h.document(conflict), nil)
        try StorageAssertions.deepEqual(try await h.find(["kind": record["kind"]!, "scope": record["scope"]!])?["id"], number(did))
        let after = try await h.commit([change(did, [["s", ["count"], 3]])])
        try StorageAssertions.greaterThan(after, baseline)
    }
    static func case22(_ h: Self) async throws {
        let root = try await h.root()
        // Swift cannot represent lone surrogates. These canonically equivalent strings
        // have distinct code units. Also check an embedded NUL in every indexed field.
        for suffix in ["", "\u{0}"] {
            let first = "\u{E9}" + suffix, second = "e\u{301}" + suffix
            let task1 = try await h.mint(), task2 = try await h.mint(), sub1 = try await h.mint(), sub2 = try await h.mint()
            let kind1 = try await h.mint(), kind2 = try await h.mint(), key1 = try await h.mint(), key2 = try await h.mint()
            let session: JSONValue = ["kind": "session"]
            try await h.commit([
                write("task", task(task1, root, ["kind": .string(first)])), write("task", task(task2, root, ["kind": .string(second)])),
                write("submission", submission(sub1, root, ["requestId": .string(first)])), write("submission", submission(sub2, root, ["requestId": .string(second)])),
                create(documentRecord(kind1, first, session), ["identity": "first kind"]),
                create(documentRecord(kind2, second, session), ["identity": "second kind"]),
                create(documentRecord(key1, "family", session, ["key": .string(first)]), ["identity": "first key"]),
                create(documentRecord(key2, "family", session, ["key": .string(second)]), ["identity": "second key"])])
            try StorageAssertions.strictEqual(try await h.scan("task", ["kind": .string(first)]).ids, [task1])
            try StorageAssertions.strictEqual(try await h.scan("task", ["kind": .string(second)]).ids, [task2])
            try StorageAssertions.deepEqual(try await h.task(task1)?["kind"], .string(first))
            try StorageAssertions.deepEqual(try await h.task(task2)?["kind"], .string(second))
            try StorageAssertions.deepEqual(try await h.request(root, first)?["requestId"], .string(first))
            try StorageAssertions.deepEqual(try await h.request(root, first)?["id"], number(sub1))
            try StorageAssertions.deepEqual(try await h.request(root, second)?["id"], number(sub2))
            try StorageAssertions.deepEqual(try await h.find(["kind": .string(first), "scope": session])?["id"], number(kind1))
            try StorageAssertions.deepEqual(try await h.find(["kind": .string(second), "scope": session])?["id"], number(kind2))
            try StorageAssertions.deepEqual(try await h.find(["kind": "family", "key": .string(first), "scope": session])?["id"], number(key1))
            try StorageAssertions.deepEqual(try await h.find(["kind": "family", "key": .string(second), "scope": session])?["id"], number(key2))
            try StorageAssertions.strictEqual(try await h.scan("document", ["scope": session, "at": "current", "kind": .string(first)]).ids, [kind1])
        }
    }
}
