import PiSwiftChord
import PiSwiftDurable

extension StorageChecks {
    static func case1(_ h: Self) async throws {
        try StorageAssertions.strictEqual(try await h.mint(), 2)
        try StorageAssertions.strictEqual(try await h.root(), 1)
        try StorageAssertions.deepEqual(try await h.conversation(1), ["id": 1])
        try await StorageAssertions.rejects(messageIncludes: "ID 1 already belongs to conversation") {
            try await h.commit([write("conversation", ["id": 1])])
        }
    }
    static func case2(_ h: Self) async throws {
        let root = try await h.root(), eid = try await h.mint(), tid = try await h.mint(), sid = try await h.mint()
        let task = task(tid, root), input = submission(sid, root, ["requestId": "request-1", "status": "placed", "entry": number(eid)])
        let record = entry(eid, root, "user", ["data": ["text": "hello"]])
        let seq = try await h.commit([write("entry", record), write("task", task), write("submission", input)])
        try StorageAssertions.deepEqual(try await h.entry(eid), ["entry": record, "commitSeq": number(seq)])
        try StorageAssertions.deepEqual(try await h.task(tid), task)
        try StorageAssertions.deepEqual(try await h.submission(sid), input)
        let transient = try await h.mint()
        try await StorageAssertions.rejects(messageIncludes: "ID 1 already belongs to conversation") {
            try await h.commit([
                write("task", replacing(task, ["state": ["status": "running", "checkpoint": ["phase": "effect"]]])),
                write("submission", replacing(input, ["status": "done", "answer": number(transient)])),
                write("entry", entry(transient, root, "assistant")), write("conversation", ["id": number(root)])])
        }
        try StorageAssertions.deepEqual(try await h.task(tid), task)
        try StorageAssertions.deepEqual(try await h.submission(sid), input)
        try StorageAssertions.deepEqual(try await h.entry(transient), nil)
        let next = try await h.commit([write("entry", entry(try await h.mint(), root, "after-rollback"))])
        try StorageAssertions.greaterThan(next, seq)
    }
    static func case3(_ h: Self) async throws {
        let root = try await h.root(), eid = try await h.mint(), tid = try await h.mint(), sid = try await h.mint()
        var data: JSONValue = ["nested": [1, 2]]
        var checkpoint: JSONValue = ["phase": "ready", "nested": ["count": 1]]
        var detail: JSONValue = ["codes": ["initial"]]
        let state: JSONValue = ["status": "pending", "checkpoint": checkpoint]
        try await h.commit([write("entry", entry(eid, root, "note", ["data": data])),
                            write("task", task(tid, root, ["state": state])),
                            write("submission", submission(sid, root, ["status": "unanswered", "reason": "failed", "detail": detail]))])
        data = replacing(data, ["nested": [1, 2, 3]])
        checkpoint = replacing(checkpoint, ["nested": ["count": 2]])
        detail = replacing(detail, ["codes": ["initial", "mutated"]])
        try StorageAssertions.ok(data != ["nested": [1, 2]] && checkpoint != state["checkpoint"] && detail != ["codes": ["initial"]])
        try StorageAssertions.deepEqual(try await h.entry(eid)?["entry"]?["data"], ["nested": [1, 2]])
        try StorageAssertions.deepEqual(try await h.task(tid)?["state"], state)
        try StorageAssertions.deepEqual(try await h.submission(sid)?["detail"], ["codes": ["initial"]])
        var readEntry = try await h.entry(eid)!["entry"]!
        var readTask = try await h.task(tid)!
        var readInput = try await h.submission(sid)!
        readEntry = replacing(readEntry, ["data": ["nested": [1, 2, 9]]])
        readTask = replacing(readTask, ["state": ["status": "pending", "checkpoint": ["phase": "ready", "nested": ["count": 9]]]])
        readInput = replacing(readInput, ["detail": ["codes": ["initial", "read mutation"]]])
        try StorageAssertions.ok(readEntry["data"] != ["nested": [1, 2]] && readTask["state"] != state && readInput["detail"] != ["codes": ["initial"]])
        try StorageAssertions.deepEqual(try await h.entry(eid)?["entry"]?["data"], ["nested": [1, 2]])
        try StorageAssertions.deepEqual(try await h.task(tid)?["state"], state)
        try StorageAssertions.deepEqual(try await h.submission(sid)?["detail"], ["codes": ["initial"]])
    }
    static func case4(_ h: Self) async throws {
        let root = try await h.root(), eid = try await h.mint()
        var data: JSONValue = ["__proto__": ["polluted": false], "constructor": ["label": "stored"], "toString": "value"]
        try await h.commit([write("entry", entry(eid, root, "note", ["data": data]))])
        data = replacing(data, ["__proto__": ["polluted": true], "constructor": ["label": "mutated"]])
        var first = try await h.entry(eid)!["entry"]!["data"]!
        try StorageAssertions.ok(first.objectValue != nil && first.objectValue!["__proto__"] != nil)
        try StorageAssertions.deepEqual(first["__proto__"], ["polluted": false])
        try StorageAssertions.deepEqual(first["constructor"], ["label": "stored"])
        try StorageAssertions.deepEqual(first["toString"], "value")
        let empty: JSONValue = [:]
        try StorageAssertions.deepEqual(empty["polluted"], nil)
        first = replacing(first, ["__proto__": ["polluted": true]])
        try StorageAssertions.ok(first != data)
        let second = try await h.entry(eid)!["entry"]!["data"]!
        try StorageAssertions.deepEqual(second["__proto__"], ["polluted": false])
        try StorageAssertions.deepEqual(second["constructor"], ["label": "stored"])
        try StorageAssertions.deepEqual(second["toString"], "value")
    }
    static func case5(_ h: Self) async throws {
        let root = try await h.root()
        try await h.commit([write("entry", entry(30, root)), write("entry", entry(10, root)), write("entry", entry(20, root, "marker", ["head": 10]))])
        try StorageAssertions.strictEqual(try await h.scan("entry", ["conversationId": number(root)]).ids, [30, 20, 10])
        try StorageAssertions.deepEqual(try await h.marker(root)?["id"], 20)
    }
    static func case6(_ h: Self) async throws {
        let root = try await h.root(), oldest = try await h.mint(), middle = try await h.mint(), newest = try await h.mint()
        try await h.commit([oldest, middle, newest].map { write("entry", entry($0, root)) })
        let first = try await h.scan("entry", ["conversationId": number(root)], 2)
        try StorageAssertions.strictEqual(first.ids, [newest, middle])
        try await h.commit([write("entry", entry(try await h.mint(), root))])
        let second = try await h.scan("entry", ["conversationId": number(root)], 2, first.next)
        try StorageAssertions.strictEqual(second.ids, [oldest]); try StorageAssertions.strictEqual(second.next, nil)
    }
    static func case7(_ h: Self) async throws {
        let root = try await h.root(), secondId = try await h.mint(), third = try await h.mint()
        try await h.commit([write("conversation", ["id": number(third)]), write("conversation", ["id": number(secondId)])])
        let first = try await h.scan("conversation", [:], 2)
        try StorageAssertions.strictEqual(first.ids, [root, secondId]); try StorageAssertions.ok(first.next != nil)
        let cursor = try JSONValue(jsonText: JSONValue.object(first.next!).jsonText()).decode(Cursor.self)
        let second = try await h.scan("conversation", [:], 2, cursor)
        try StorageAssertions.strictEqual(second.ids, [third]); try StorageAssertions.strictEqual(second.next, nil)
    }
    static func case8(_ h: Self) async throws {
        let root = try await h.root(), other = try await h.mint(), task1 = try await h.mint(), task2 = try await h.mint()
        let one = try await h.mint(), two = try await h.mint(), three = try await h.mint()
        try await h.commit([write("conversation", ["id": number(other)]),
            write("conversation", ["id": number(one), "owner": ["conversationId": number(root), "taskId": number(task1)]]),
            write("conversation", ["id": number(two), "owner": ["conversationId": number(root), "taskId": number(task2)]]),
            write("conversation", ["id": number(three), "owner": ["conversationId": number(other), "taskId": number(task1)]])])
        let first = try await h.scan("conversation", ["ownerConversationId": number(root)], 1)
        try StorageAssertions.strictEqual(first.ids, [one]); try StorageAssertions.ok(first.next != nil)
        let second = try await h.scan("conversation", ["ownerConversationId": number(root)], 1, first.next)
        try StorageAssertions.strictEqual(second.ids, [two]); try StorageAssertions.strictEqual(second.next, nil)
        try StorageAssertions.strictEqual(try await h.scan("conversation", ["ownerTaskId": number(task1)]).ids, [one, three])
        try StorageAssertions.strictEqual(try await h.scan("conversation", ["ownerConversationId": number(root), "ownerTaskId": number(task1)]).ids, [one])
    }
    static func case9(_ h: Self) async throws {
        let root = try await h.root(), rootFirst = try await h.mint(), rootFork = try await h.mint(), rootSame = try await h.mint()
        let rootSeq = try await h.commit([write("entry", entry(rootFirst, root)), write("entry", entry(rootFork, root, "marker", ["head": number(rootFirst)])), write("entry", entry(rootSame, root))])
        let child = try await h.mint()
        try await h.commit([write("conversation", ["id": number(child), "parent": ["conversationId": number(root), "at": number(rootFork)]])])
        let childFork = try await h.mint(), childExcluded = try await h.mint()
        try await h.commit([write("entry", entry(childFork, child, "note")), write("entry", entry(childExcluded, child))])
        let rootLater = try await h.mint()
        try await h.commit([write("entry", entry(rootLater, root))])
        let grandchild = try await h.mint()
        try await h.commit([write("conversation", ["id": number(grandchild), "parent": ["conversationId": number(child), "at": number(childFork)]])])
        let head = try await h.mint(), tail = try await h.mint()
        let grandSeq = try await h.commit([write("entry", entry(head, grandchild, "marker", ["head": number(head)])), write("entry", entry(tail, grandchild))])
        let childLater = try await h.mint()
        try await h.commit([write("entry", entry(childLater, child))])
        let query: JSONValue = ["conversationId": number(grandchild)]
        let first = try await h.scan("entry", query, 2)
        try StorageAssertions.strictEqual(first.ids, [tail, head])
        let second = try await h.scan("entry", query, 2, first.next)
        try StorageAssertions.strictEqual(second.ids, [childFork, rootFork])
        let third = try await h.scan("entry", query, 2, second.next)
        try StorageAssertions.strictEqual(third.ids, [rootFirst]); try StorageAssertions.strictEqual(third.next, nil)
        let ascending = replacing(query, ["order": "ascending"])
        let up1 = try await h.scan("entry", ascending, 2)
        try StorageAssertions.strictEqual(up1.ids, [rootFirst, rootFork])
        let up2 = try await h.scan("entry", ascending, 2, up1.next)
        try StorageAssertions.strictEqual(up2.ids, [childFork, head])
        let up3 = try await h.scan("entry", query, 2, up2.next)
        try StorageAssertions.strictEqual(up3.ids, [tail]); try StorageAssertions.strictEqual(up3.next, nil)
        try StorageAssertions.strictEqual(try await h.scan("entry", replacing(ascending, ["minEntryId": number(rootFork), "maxEntryId": number(childFork)])).ids, [rootFork, childFork])
        try await StorageAssertions.rejects(messageIncludes: "cursor") { try await h.scan("entry", replacing(query, ["order": "descending"]), 2, up1.next) }
        let current = try await h.marker(grandchild), historical = try await h.marker(grandchild, childFork)
        try StorageAssertions.deepEqual(current?["id"], number(head)); try StorageAssertions.deepEqual(current?["head"], number(head))
        try StorageAssertions.deepEqual(historical?["id"], number(rootFork)); try StorageAssertions.deepEqual(historical?["head"], number(rootFirst))
        try StorageAssertions.deepEqual(try await h.marker(grandchild, rootFirst), nil)
        let active = replacing(query, ["minEntryId": current!["head"]!])
        let active1 = try await h.scan("entry", active, 1)
        try StorageAssertions.strictEqual(active1.ids, [tail]); try StorageAssertions.ok(active1.next != nil)
        let active2 = try await h.scan("entry", active, 1, active1.next)
        try StorageAssertions.strictEqual(active2.ids, [head]); try StorageAssertions.strictEqual(active2.next, nil)
        try StorageAssertions.strictEqual(try await h.scan("entry", replacing(query, ["minEntryId": historical!["head"]!, "maxEntryId": number(childFork)])).ids, [childFork, rootFork, rootFirst])
        let lookup: JSONValue = ["entry": entry(rootFirst, root), "commitSeq": number(rootSeq)]
        try StorageAssertions.deepEqual(try await h.entry(rootFirst), lookup)
        try StorageAssertions.deepEqual(try await h.entry(rootFork)?["commitSeq"], number(rootSeq))
        try StorageAssertions.deepEqual(try await h.entry(head)?["commitSeq"], number(grandSeq))
        try StorageAssertions.deepEqual(try await h.entry(tail)?["commitSeq"], number(grandSeq))
        try StorageAssertions.deepEqual(try await h.entry(999_999), nil)
        try StorageAssertions.deepEqual(try await h.entry(rootFirst, in: grandchild), lookup)
        try StorageAssertions.deepEqual(try await h.entry(childFork, in: grandchild)?["entry"]?["conversationId"], number(child))
        try StorageAssertions.deepEqual(try await h.entry(tail, in: grandchild)?["commitSeq"], number(grandSeq))
        for id in [rootSame, rootLater, childExcluded, childLater, 999_999] {
            try StorageAssertions.deepEqual(try await h.entry(id, in: grandchild), nil)
        }
        try StorageAssertions.deepEqual(try await h.entry(head, in: root), nil)
        try await StorageAssertions.rejects(messageIncludes: "Unknown conversation") { try await h.entry(rootFirst, in: 999_999) }
        try await StorageAssertions.rejects(messageIncludes: "Unknown conversation") { try await h.scan("entry", ["conversationId": 999_999]) }
    }
    static func case10(_ h: Self) async throws {
        let root = try await h.root()
        var conversations = [root], tasks: [Int64] = [], submissions: [Int64] = []
        for _ in 0..<3 {
            let cid = try await h.mint(), tid = try await h.mint(), sid = try await h.mint()
            try await h.commit([write("conversation", ["id": number(cid)]), write("task", task(tid, root)), write("submission", submission(sid, root))])
            conversations.append(cid); tasks.append(tid); submissions.append(sid)
        }
        for (table, ids) in [("conversation", conversations), ("task", tasks), ("submission", submissions)] {
            for order in [nil, "ascending", "descending"] as [String?] {
                let query: JSONValue = order.map { ["order": .string($0)] } ?? [:]
                var page = try await h.scan(table, query, 2), found = page.ids
                while let next = page.next {
                    let cursor = try JSONValue(jsonText: JSONValue.object(next).jsonText()).decode(Cursor.self)
                    page = try await h.scan(table, [:], 2, cursor); found.append(contentsOf: page.ids)
                }
                try StorageAssertions.strictEqual(found, order == "descending" ? Array(ids.reversed()) : ids)
            }
            let descending = try await h.scan(table, ["order": "descending"], 2)
            try StorageAssertions.strictEqual(try await h.scan(table, ["order": "descending"], 2, descending.next).ids, Array(ids.reversed().dropFirst(2).prefix(2)))
            try await StorageAssertions.rejects(messageIncludes: "cursor") { try await h.scan(table, ["order": "ascending"], 2, descending.next) }
        }
    }
    static func case11(_ h: Self) async throws {
        let root = try await h.root(), one = try await h.mint(), two = try await h.mint(), three = try await h.mint()
        let first = task(one, root, ["memos": ["winner": "first"]]), second = task(two, root, ["background": true]), third = task(three, root, ["abortRequested": true])
        try await h.commit([first, second, third].map { write("task", $0) })
        let running = replacing(first, ["state": ["status": "running", "checkpoint": ["phase": "effect", "attempt": 1]], "abortRequested": true])
        try await h.commit([write("task", running)])
        try StorageAssertions.deepEqual(try await h.task(one), running)
        let terminal = task(one, root, ["state": ["status": "terminal", "outcome": ["status": "completed", "result": ["entryId": 99]]], "abortRequested": true])
        try await h.commit([write("task", terminal)])
        try StorageAssertions.deepEqual(try await h.task(one), terminal)
        let page = try await h.scan("task", ["status": "pending"], 1)
        try StorageAssertions.strictEqual(page.ids, [two]); try StorageAssertions.ok(page.next != nil)
        try StorageAssertions.strictEqual(try await h.scan("task", ["status": "pending"], 1, page.next).ids, [three])
        try StorageAssertions.strictEqual(try await h.scan("task", ["status": "terminal", "abortRequested": true]).items, [terminal])
        try StorageAssertions.strictEqual(try await h.scan("task", ["background": true]).ids, [two])
    }
    static func case12(_ h: Self) async throws {
        let root = try await h.root(), ownerId = try await h.mint(), waitingId = try await h.mint(), completingId = try await h.mint()
        let owner = task(ownerId, root)
        let waiting = task(waitingId, root, ["owner": number(ownerId), "state": ["status": "waiting", "checkpoint": ["phase": "next"], "on": [number(ownerId)], "policy": "allSettled"], "memos": ["kept": true]])
        let outcome: JSONValue = ["status": "failed", "error": ["message": "held"]]
        let completing = task(completingId, root, ["owner": number(ownerId), "state": ["status": "completing", "outcome": outcome]])
        try await h.commit([owner, waiting, completing].map { write("task", $0) })
        try StorageAssertions.deepEqual(try await h.task(waitingId), waiting)
        try StorageAssertions.deepEqual(try await h.task(completingId), completing)
        try StorageAssertions.strictEqual(try await h.scan("task", ["status": "waiting"]).items, [waiting])
        try StorageAssertions.strictEqual(try await h.scan("task", ["status": "completing"]).items, [completing])
        try StorageAssertions.strictEqual(try await h.scan("task", ["status": "pending"]).ids, [ownerId])
        let terminal = replacing(completing, ["state": ["status": "terminal", "outcome": outcome]])
        try await h.commit([write("task", terminal)])
        try StorageAssertions.strictEqual(try await h.scan("task", ["status": "completing"]).items, [])
        try StorageAssertions.strictEqual(try await h.scan("task", ["status": "terminal"]).items, [terminal])
    }
    static func case13(_ h: Self) async throws {
        let root = try await h.root(), other = try await h.mint()
        try await h.commit([write("conversation", ["id": number(other)])])
        let one = try await h.mint(), two = try await h.mint(), three = try await h.mint()
        let first = submission(one, root, ["requestId": "same"]), second = submission(two, root, ["requestId": "other"]), third = submission(three, other, ["requestId": "same"])
        try await h.commit([first, second, third].map { write("submission", $0) })
        try StorageAssertions.deepEqual(try await h.request(root, "same"), first)
        try StorageAssertions.deepEqual(try await h.request(other, "same"), third)
        let placed = replacing(second, ["status": "placed", "entry": number(try await h.mint())])
        try await h.commit([write("submission", placed)])
        try StorageAssertions.deepEqual(try await h.submission(two), placed)
        try StorageAssertions.deepEqual(try await h.request(root, "other"), placed)
        for (query, expected): (JSONValue, [Int64]) in [
            ([:], [one, two, three]), (["conversationId": number(root)], [one, two]),
            (["status": "queued"], [one, three]), (["status": "placed"], [two]),
            (["conversationId": number(other), "status": "queued"], [three]),
            (["conversationId": number(other), "status": "placed"], [])] {
            var cursor: Cursor?, found: [Int64] = []
            repeat { let page = try await h.scan("submission", query, 1, cursor); found.append(contentsOf: page.ids); cursor = page.next } while cursor != nil
            try StorageAssertions.strictEqual(found, expected)
        }
        try StorageAssertions.strictEqual(try await h.scan("submission", ["status": "placed"]).items, [placed])
    }
    static func case14(_ h: Self) async throws {
        let root = try await h.root(), doneId = try await h.mint(), failedId = try await h.mint()
        let queuedDone = submission(doneId, root, ["requestId": "passive-done", "type": "write"]), queuedFailed = submission(failedId, root, ["requestId": "passive-failed", "type": "write"])
        try await h.commit([write("submission", queuedDone), write("submission", queuedFailed)])
        let done = replacing(queuedDone, ["status": "done", "entry": number(try await h.mint())])
        let unanswered = replacing(queuedFailed, ["status": "unanswered", "reason": "closed", "detail": ["retryable": false]])
        try await h.commit([write("submission", done), write("submission", unanswered)])
        try StorageAssertions.deepEqual(try await h.submission(doneId), done)
        try StorageAssertions.deepEqual(try await h.request(root, "passive-done"), done)
        try StorageAssertions.deepEqual(try await h.submission(failedId), unanswered)
        try StorageAssertions.deepEqual(try await h.request(root, "passive-failed"), unanswered)
    }
    static func case23(_ h: Self) async throws {
        let root = try await h.root()
        try await h.commit([write("entry", entry(100, root))])
        try StorageAssertions.strictEqual(try await h.mint(), 101)
        try await StorageAssertions.rejects(messageIncludes: "ID 100 already belongs to entry") { try await h.commit([write("task", task(100, root))]) }
        try await h.commit([write("entry", entry(EntryID.maximumRawValue, root, "last-id"))])
        try await StorageAssertions.rejects(messageIncludes: "ID space is exhausted") { try await h.mint() }
        try await StorageAssertions.rejects(messageIncludes: "ID space is exhausted") { try await h.mint() }
    }
    static func case24(_ h: Self) async throws {
        try await h.root()
        try await h.storage.close(context: context)
        try await StorageAssertions.rejects(messageIncludes: "closed") { try await h.conversation(1) }
        try await StorageAssertions.rejects(messageIncludes: "closed") { try await h.commit([]) }
        try await StorageAssertions.rejects(messageIncludes: "closed") { try await h.mint() }
    }
}
