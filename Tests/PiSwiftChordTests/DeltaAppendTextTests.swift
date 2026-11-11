import Testing
import PiSwiftChord

@Suite struct DeltaAppendTextTests {
    private func commit(_ tracker: Tracker, _ edit: (JSONDraft) throws -> Void) throws -> [Delta.Op] {
        let change = tracker.beginChange()
        try edit(change.state)
        let prepared = try change.prepare()
        #expect(try Delta.applyImmutable(tracker.value, prepared.ops) == prepared.value)
        try tracker.adopt(prepared)
        return prepared.ops
    }

    @Test func recordsAnAppendOpAndTheAppendedValue() throws {
        let tracker = try Delta.track(["title": "t", "content": [["text": "hello"]], "meta": ["note": "n"]])
        let before = tracker.value
        #expect(try commit(tracker) { root in
            let content = try #require(try root.child("content"))
            let block = try #require(try content.child(0))
            try block.appendText("text", " world")
        } == [.append(["content", 0, "text"], " world")])
        #expect(try commit(tracker) { try $0.appendText("title", "!") } == [.append(["title"], "!")])
        #expect(try commit(tracker) { root in
            let meta = try #require(try root.child("meta"))
            try meta.appendText("note", "ote")
        } ==
                [.append(["meta", "note"], "ote")])
        #expect(tracker.value == ["title": "t!", "content": [["text": "hello world"]], "meta": ["note": "note"]])
        #expect(before == ["title": "t", "content": [["text": "hello"]], "meta": ["note": "n"]])
    }

    @Test func joinsSeveralAppendsToOneKeyInOneChangeNextToOtherChanges() throws {
        let tracker = try Delta.track(["title": "old", "content": [["text": "hello"]]])
        let ops = try commit(tracker) { root in
            let content = try #require(try root.child("content"))
            let block = try #require(try content.child(0))
            try block.appendText("text", " a")
            try root.set("title", "new")
            try block.appendText("text", " b")
            try block.appendText("text", "")
            try block.appendText("text", " c")
            #expect(try block.get("text") == "hello a b c")
        }
        #expect(ops.contains(.append(["content", 0, "text"], " a b c")))
        #expect(ops.contains(.set(["title"], "new")))
        #expect(ops.count == 2)
    }

    @Test func fallsBackToStringComparisonWhenSameKeyAssignedOrDeleted() throws {
        let tracker = try Delta.track(["title": "t", "meta": ["note": "n"]])
        #expect(try commit(tracker) { root in
            try root.appendText("title", " x")
            let title = try #require(try root.get("title")?.stringValue)
            try root.set("title", .string(title + " y"))
        } == [.append(["title"], " x y")])
        #expect(try commit(tracker) { root in
            try root.appendText("title", " z")
            try root.set("title", "replaced")
        } == [.set(["title"], "replaced")])
        #expect(try commit(tracker) { root in
            try root.set("title", "assigned")
            try root.appendText("title", " then appended")
        } == [.set(["title"], "assigned then appended")])
        #expect(try commit(tracker) { root in
            let meta = try #require(try root.child("meta"))
            try meta.appendText("note", "x")
            try meta.remove("note")
        } == [.delete(["meta", "note"])])
    }

    @Test func appendsInsideBlockSameChangeInsertedOrReplaced() throws {
        let tracker = try Delta.track(["content": [["text": "old"]]])
        _ = try commit(tracker) { root in
            let content = try #require(try root.child("content"))
            try content.append(["text": "new"])
            let newBlock = try #require(try content.child(1))
            try newBlock.appendText("text", " block")
            try content.set(0, ["text": "other"])
            let otherBlock = try #require(try content.child(0))
            try otherBlock.appendText("text", " one")
        }
        #expect(tracker.value == ["content": [["text": "other one"], ["text": "new block"]]])
    }

    @Test func rejectsNonStringMissingArrayAndSettledDraft() throws {
        // Upstream: "rejects what a JavaScript caller can get wrong". A plain object
        // cannot be passed here because the receiver has type JSONDraft.
        let tracker = try Delta.track(["title": "t", "content": ["x"]])
        let change = tracker.beginChange()
        let root = try change.state
        #expect(throws: TrackerError.invalidOperation("appendText() needs a string at \"content\"")) {
            try root.appendText("content", "x")
        }
        #expect(throws: TrackerError.invalidOperation("appendText() needs a string at \"missing\"")) {
            try root.appendText("missing", "x")
        }
        let content = try #require(try root.child("content"))
        #expect(throws: TrackerError.invalidOperation("appendText() needs a string at \"0\"")) {
            try content.appendText("0", "x")
        }
        _ = try change.prepare()
        #expect(throws: TrackerError.settled) { try root.appendText("title", "x") }
        let aborted = tracker.beginChange()
        let state = try aborted.state
        aborted.abort()
        #expect(throws: TrackerError.settled) { try state.appendText("title", "x") }
    }
}

@Suite struct TrackerCompetitionV152Tests {
    @Test func makesOlderOfTwoOpenDraftsStaleWhenNewerAdopted() throws {
        let tracker = try Delta.track(["n": 0])
        let older = tracker.beginChange()
        let newer = tracker.beginChange()
        try older.state.set("n", 1)
        try newer.state.set("n", 2)
        let preparedOlder = try older.prepare()
        let preparedNewer = try newer.prepare()
        try tracker.adopt(preparedNewer)
        #expect(tracker.value == ["n": 2])
        #expect(throws: TrackerError.stale) { try tracker.adopt(preparedOlder) }
    }

    @Test func makesNewerOfTwoOpenDraftsStaleWhenOlderAdopted() throws {
        let tracker = try Delta.track(["n": 0])
        let older = tracker.beginChange()
        let newer = tracker.beginChange()
        let olderDraft = try older.state
        let newerDraft = try newer.state
        try olderDraft.set("n", 1)
        try newerDraft.set("n", 2)
        try tracker.adopt(older.prepare())
        #expect(tracker.value == ["n": 1])
        #expect(throws: TrackerError.settled) { try newerDraft.set("n", 3) }
    }

    @Test func makesEveryOtherOfThreeDraftsStaleWhicheverAdopted() throws {
        for winner in 0..<3 {
            let tracker = try Delta.track(["n": 0])
            let changes = (0..<3).map { _ in tracker.beginChange() }
            let drafts = try changes.map { try $0.state }
            for (index, draft) in drafts.enumerated() { try draft.set("n", .number(Double(index + 1))) }
            let prepared = try changes.map { try $0.prepare() }
            try tracker.adopt(prepared[winner])
            #expect(tracker.value == .object(["n": .number(Double(winner + 1))]))
            for index in 0..<3 where index != winner {
                #expect(throws: TrackerError.stale) { try tracker.adopt(prepared[index]) }
            }
        }
    }
}

@Suite struct DeltaImmutableV152Tests {
    @Test func keepsOwnProtoMemberAsDataAndCopiedObject() throws {
        // Upstream: "keep an own __proto__ member as data and the prototype of the copied object".
        // Swift has ordered JSONObject values and no object prototype.
        let base: JSONValue = ["__proto__": ["polluted": true], "n": 1]
        let checked = try #require(try Delta.applyImmutable(base, [.set(["n"], 2)]))
        #expect(checked["__proto__"] == ["polluted": true])
        #expect(checked["n"] == 2)
        #expect(base["n"] == 1)
        let tracker = try Delta.track(base)
        let change = tracker.beginChange()
        try change.state.set("n", 2)
        try tracker.adopt(change.prepare())
        #expect(tracker.value == checked)
        #expect(tracker.value.objectValue?.keys == base.objectValue?.keys)
    }
}
