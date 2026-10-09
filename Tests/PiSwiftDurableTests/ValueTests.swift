import Testing
import PiSwiftChord
import PiSwiftDurable

extension PiSwiftDurableTests {
    @Test func IDsAndSequences() throws {
        #expect(rootConversationID.rawValue == 1)
        for number: Double in [1, 2, 9_007_199_254_740_991] {
            let id: TaskID = try idFromNumber(number)
            let seq = try seqFromNumber(number)
            #expect(try JSONValue(encoding: id) == .number(number))
            #expect(try JSONValue(encoding: seq) == .number(number))
            #expect(try JSONValue.number(number).decode(TaskID.self) == id)
            #expect(try JSONValue.number(number).decode(Seq.self) == seq)
        }
        for number: Double in [0, -1, 1.5, 9_007_199_254_740_992, .infinity, -.infinity, .nan] {
            #expect(throws: DurableValueError.self) { let _: EntryID = try idFromNumber(number) }
            #expect(throws: DurableValueError.self) { try seqFromNumber(number) }
        }
        #expect(throws: DurableValueError.invalidID("0")) { try EntryID(0) }
        #expect(throws: DurableValueError.invalidSequence("0")) { try Seq(0) }
        #expect(throws: DurableValueError.self) { try JSONValue.string("2").decode(EntryID.self) }
        #expect(DurableValueError.invalidID("0").description == "Invalid durable ID: 0; expected an integer from 1 through 9007199254740991")
        #expect(DurableValueError.invalidSequence("0").description == "Invalid durable sequence: 0; expected an integer from 1 through 9007199254740991")
        #expect(DurableStorageError.idSpaceExhausted.description == "ID space is exhausted")
        #expect(try Seq(1) < Seq(3))
    }

    @Test func scanHelpers() throws {
        for order in [ScanOrder.ascending, .descending] {
            #expect(try scanStart(requested: nil, cursor: nil, fallback: order) == ScanStart(order: order, after: nil))
            #expect(try scanStart(requested: order, cursor: nil, fallback: .ascending).order == order)
            let cursor = nextCursor(try EntryID(9_007_199_254_740_991), order: order)
            #expect(cursor == ["after": 9_007_199_254_740_991, "order": .string(order.rawValue)])
            #expect(try scanStart(requested: nil, cursor: cursor, fallback: .descending).order == order)
            let other: ScanOrder = order == .ascending ? .descending : .ascending
            #expect(throws: DurableStorageError.cursorOrderMismatch(stored: order, requested: other)) {
                try scanStart(requested: other, cursor: cursor, fallback: order)
            }
            for position: Double in [-9_007_199_254_740_991, -1, 0, 9_007_199_254_740_991] {
                #expect(try scanStart(requested: nil, cursor: ["after": .number(position)], fallback: order).after == Int64(position))
            }
        }
        let invalid: [JSONObject] = [[:], ["after": "1"], ["after": 1.5], ["after": nil],
                                     ["after": 9_007_199_254_740_992], ["after": -9_223_372_036_854_775_808],
                                     ["after": 1, "order": "sideways"], ["after": 1, "order": nil]]
        for cursor in invalid {
            #expect(throws: DurableStorageError.invalidCursor) {
                try scanStart(requested: nil, cursor: cursor, fallback: .ascending)
            }
        }
        #expect(DurableStorageError.invalidCursor.description == "Invalid storage cursor")
        #expect(DurableStorageError.cursorOrderMismatch(stored: .ascending, requested: .descending).description == "The cursor continues a ascending scan; the query asks for descending")
    }

    @Test func entryKindTokens() throws {
        #expect([userEntry.kind, assistantEntry.kind, systemEntry.kind, resetEntry.kind] == ["pi.user", "pi.assistant", "pi.system", "pi.reset"])
        #expect(throws: DurableValueError.emptyEntryKind) { try EntryKind<JSONValue>("") }
        let token = try EntryKind<JSONValue>("custom")
        let record = EntryRecord(id: try EntryID(2), conversationId: rootConversationID, kind: "custom", data: nil)
        #expect(token.matches(record))
        #expect(!token.matches(nil))
        let composed = try EntryKind<JSONValue>("é")
        let decomposed = EntryRecord(id: try EntryID(3), conversationId: rootConversationID, kind: "e\u{301}")
        #expect(!composed.matches(decomposed))
    }

    // Runtime parts of types.test.ts cases 1 and 2. Case 3 declares harness values;
    // it has no data-layer runtime assertion. See TypesPort.swift for the N/A list.
    @Test func upstreamRuntimeTypes() throws {
        let task = try TaskID(4)
        #expect(try JSONValue(encoding: task).jsonText() == "4")
        let values: [(JSONValue, String)] = [
            (["target": 2, "action": "omit"], "edit"),
            (["target": 2, "action": "replace", "messages": []], "edit"),
            (["status": "pending", "checkpoint": ["phase": "ready"]], "state"),
            (["status": "terminal", "outcome": ["status": "completed", "result": ["value": 1]]], "state"),
            (["id": 5, "conversationId": 1, "type": "input", "status": "done", "entry": 2, "answer": 3], "submission"),
            (["id": 5, "conversationId": 1, "type": "write", "status": "done", "entry": 2], "submission"),
            (["kind": "base", "version": 1, "value": ["count": 1]], "content"),
            (["kind": "delta", "version": 1, "ops": [["s", ["count"], 2]]], "content"),
            (["id": 6, "kind": "test", "scope": ["kind": "conversation", "conversationId": 1], "history": "rewindable", "fork": "asOf"], "document")
        ]
        for (json, kind) in values {
            let encoded: JSONValue
            switch kind {
            case "edit": encoded = try JSONValue(encoding: json.decode(ContextEdit.self))
            case "state": encoded = try JSONValue(encoding: json.decode(TaskState.self))
            case "submission": encoded = try JSONValue(encoding: json.decode(SubmissionRecord.self))
            case "content": encoded = try JSONValue(encoding: json.decode(DocumentContent.self))
            default: encoded = try JSONValue(encoding: json.decode(DocumentCreate.self))
            }
            #expect(encoded == json)
        }
    }

    @Test func draftSettlementAndSemantics() throws {
        func check<T: Codable>(_ value: JSONValue, _ type: T.Type) throws {
            #expect(try JSONValue(encoding: value.decode(type)) == value)
        }
        try check(["kind": "pi.reset", "head": "self", "data": nil], EntryDraft.self)
        try check(["kind": "custom", "head": 2, "future": true], EntryDraft.self)
        try check(["kind": "ownerless"], ConversationOwnership.self)
        try check(["kind": "task", "taskId": 4], ConversationOwnership.self)
        try check(["kind": "conversation"], TaskOwnership.self)
        try check(["kind": "task", "taskId": 4], TaskOwnership.self)
        try check(["status": "done", "answer": 3], SubmissionSettlement.self)
        try check(["status": "unanswered", "reason": "stopped", "detail": nil], SubmissionSettlement.self)
        try check(["scope": "session"], DocumentSemantics.self)
        try check(["scope": "task"], DocumentSemantics.self)
        for history in ["latest", "rewindable"] {
            for fork in ["initial", "current", "asOf"] where history != "latest" || fork != "asOf" {
                try check(["scope": "conversation", "history": .string(history), "fork": .string(fork)], DocumentSemantics.self)
            }
        }
    }

    @Test func invalidUnionShapesReject() throws {
        let invalid: [(JSONValue, String)] = [
            (["action": "future", "target": 2], "edit"),
            (["action": "replace", "target": 2], "edit"),
            (["action": "omit", "target": 2, "messages": []], "edit"),
            (["status": "future", "checkpoint": nil], "state"),
            (["status": "pending", "checkpoint": nil, "outcome": ["status": "completed", "result": nil]], "state"),
            (["status": "terminal", "checkpoint": nil, "outcome": ["status": "completed", "result": nil]], "state"),
            (["status": "completed", "result": 1, "error": ["message": "invalid"]], "outcome"),
            (["status": "future"], "outcome"),
            (["id": 5, "conversationId": 1, "type": "input", "status": "done", "entry": 2], "submission"),
            (["id": 5, "conversationId": 1, "type": "write", "status": "done", "entry": 2, "answer": 3], "submission"),
            (["kind": "future", "version": 1], "content"),
            (["kind": "base", "version": 1, "value": [:], "ops": []], "content"),
            (["kind": "delta", "version": 1, "value": [:], "ops": []], "content"),
            (["id": 6, "kind": "test", "scope": ["kind": "conversation", "conversationId": 1]], "document"),
            (["id": 6, "kind": "test", "scope": ["kind": "session"], "history": "latest", "fork": "current"], "document"),
            (["id": 6, "kind": "test", "scope": ["kind": "conversation", "conversationId": 1], "history": "latest", "fork": "asOf"], "document"),
            (["type": "future", "id": 6], "write"),
            (["type": "document.create", "record": ["id": 6, "kind": "test", "scope": ["kind": "session"]], "content": ["kind": "delta", "version": 1, "ops": []]], "write")
        ]
        for (json, kind) in invalid {
            #expect(throws: (any Error).self) {
                switch kind {
                case "edit": _ = try json.decode(ContextEdit.self)
                case "state": _ = try json.decode(TaskState.self)
                case "outcome": _ = try json.decode(TaskOutcome.self)
                case "submission": _ = try json.decode(SubmissionRecord.self)
                case "content": _ = try json.decode(DocumentContent.self)
                case "document": _ = try json.decode(DocumentCreate.self)
                default: _ = try json.decode(StorageWrite.self)
                }
            }
        }
        let invalidTask = TaskRecord(id: try TaskID(4), conversationId: rootConversationID, kind: "test", version: 1,
                                     input: nil, state: .terminal(outcome: .completed(result: 1)), memos: ["retained": true])
        #expect(throws: (any Error).self) { try JSONValue(encoding: invalidTask) }
    }
}
