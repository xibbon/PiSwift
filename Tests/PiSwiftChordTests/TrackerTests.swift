import Foundation
import Testing
import PiSwiftChord

private func trackerChild(_ parent: JSONDraft, _ key: String) throws -> JSONDraft {
    try #require(try parent.child(key))
}
private func trackerChild(_ parent: JSONDraft, _ index: Int) throws -> JSONDraft {
    try #require(try parent.child(index))
}
private func trackerError(_ text: String, _ action: () throws -> Void) {
    do { try action(); Issue.record("Expected error: \(text)") }
    catch { #expect(error is TrackerError); #expect(String(describing: error) == text) }
}
private func trackerReplay(_ prepared: Delta.Prepared) throws {
    let replay = try #require(try Delta.applyImmutable(prepared.base, prepared.ops))
    #expect(replay == prepared.value)
    #expect(Array(try replay.jsonText().utf8) == Array(try prepared.value.jsonText().utf8))
}

@Suite struct TrackerTests {
    @Test func materializesImmutableRevisionAndStaysLiveAcrossAwait() async throws {
        let base: JSONValue = ["count": 1, "nested": ["text": "a"], "values": [1]]
        let tracker = try Delta.track(base)
        let change = tracker.beginChange()
        let root = try change.state
        try root.set("count", 2)
        await Task.yield()
        try trackerChild(root, "nested").set("text", "ab")
        try trackerChild(root, "values").append(2)
        #expect(tracker.value == base)
        let prepared = try change.prepare()
        #expect(prepared.base == base)
        #expect(prepared.baseRevision == 0)
        #expect(prepared.value == ["count": 2, "nested": ["text": "ab"], "values": [1, 2]])
        #expect(prepared.ops == [.set(["count"], 2), .append(["nested", "text"], "b"), .splice(["values"], index: 1, remove: 0, items: [2])])
        trackerError("Cannot use a settled overlay") { _ = try root.get("count") }
        trackerError("Cannot use a settled overlay") { try root.set("count", 3) }
        trackerError("Change has already been settled") { _ = try change.prepare() }
        try trackerReplay(prepared)
        try tracker.adopt(prepared)
        #expect(tracker.revision == 1)
        #expect(tracker.value == prepared.value)
        #expect(base == ["count": 1, "nested": ["text": "a"], "values": [1]])
    }

    @Test func abortIsIdempotentAndRevokesHeldDescendants() throws {
        let tracker = try Delta.track(["child": ["value": 1]])
        let change = tracker.beginChange()
        let child = try trackerChild(change.state, "child")
        try child.set("value", 2)
        change.abort(); change.abort()
        #expect(tracker.value == ["child": ["value": 1]])
        trackerError("Cannot use a settled overlay") { _ = try child.snapshot() }
        trackerError("Change has already been settled") { _ = try change.prepare() }
        tracker.beginChange().abort()
    }

    @Test func competingPreparedAndOpenChangesBecomeStale() throws {
        let tracker = try Delta.track(["value": 0, "child": ["value": 0]])
        let first = tracker.beginChange()
        let second = tracker.beginChange()
        let open = tracker.beginChange()
        let held = try trackerChild(open.state, "child")
        try first.state.set("value", 1)
        try second.state.set("value", 2)
        let winner = try first.prepare()
        let loser = try second.prepare()
        try tracker.adopt(winner)
        #expect(loser.value["value"] == 2)
        trackerError("Prepared change is stale") { try tracker.adopt(loser) }
        trackerError("Prepared change is stale") { try tracker.adopt(loser) }
        trackerError("Prepared change has already been used") { try tracker.adopt(winner) }
        trackerError("Cannot use a settled overlay") { _ = try held.snapshot() }
        trackerError("Cannot use a settled overlay") { _ = try open.prepare() }
        open.abort()
    }

    @Test func adoptThenPublishRetainsEarlierRevision() throws {
        let tracker = try Delta.track(["value": 0, "nested": ["count": 0]])
        let first = tracker.beginChange()
        try first.state.set("value", 1)
        try trackerChild(first.state, "nested").set("count", 1)
        let prepared = try first.prepare()
        let operations = prepared.ops
        try tracker.adopt(prepared)
        #expect(operations.count == 2)
        #expect(prepared.ops == operations)
        let next = tracker.beginChange()
        try next.state.set("value", 2)
        try tracker.adopt(next.prepare())
        #expect(prepared.value == ["value": 1, "nested": ["count": 1]])
        #expect(tracker.value == ["value": 2, "nested": ["count": 1]])
    }

    @Test func replacementsRemainReadableAndNoOpAdoptionMakesCompetitorsStale() throws {
        let tracker = try Delta.track(["value": ["count": 1]])
        let equal = try tracker.prepareReplace(["value": ["count": 1]])
        let competitor = try tracker.prepareReplace(["value": ["count": 1]])
        #expect(equal.ops.isEmpty)
        try tracker.adopt(equal)
        #expect(tracker.revision == 1)
        trackerError("Prepared change is stale") { try tracker.adopt(competitor) }
        let replacement = try tracker.prepareReplace(["value": 3])
        #expect(replacement.ops == [.replace(["value": 3])])
        try tracker.adopt(replacement)
        #expect(replacement.base == ["value": ["count": 1]])
        #expect(replacement.value == tracker.value)
        #expect(competitor.value == ["value": ["count": 1]])
    }

    @Test func rejectsForeignAndAbortedPreparedResultsAndRetainsValues() throws {
        let first = try Delta.track(["value": 0])
        let second = try Delta.track(["value": 0])
        let prepared = try first.prepareReplace(["value": 1])
        trackerError("Prepared change belongs to a different tracker") { try second.adopt(prepared) }
        prepared.abort(); prepared.abort()
        trackerError("Prepared change has been aborted") { try first.adopt(prepared) }
        #expect(prepared.value == ["value": 1])
        let change = first.beginChange()
        try change.state.set("value", 2)
        let result = try change.prepare()
        let operations = result.ops
        change.abort(); change.abort()
        trackerError("Prepared change has been aborted") { try first.adopt(result) }
        #expect(result.ops == operations)
        #expect(result.value == ["value": 2])
    }

    @Test func deletesOwnMembersAndSupportsRootArrays() throws {
        let tracker = try Delta.track(["first": 1, "second": 2])
        let change = tracker.beginChange()
        try change.state.set("first", 3)
        try change.state.remove("second")
        try change.state.set("third", 4)
        try change.state.set("temporary", 1)
        try change.state.remove("temporary")
        #expect(try change.state.get("second") == nil)
        #expect(try change.state.contains("temporary") == false)
        let result = try change.prepare()
        try tracker.adopt(result)
        #expect(tracker.value == ["first": 3, "third": 4])
        let arrayTracker = try Delta.track([1, 2, 3])
        let arrayChange = arrayTracker.beginChange()
        try arrayChange.state.reverse()
        try arrayChange.state.append(4)
        let arrayResult = try arrayChange.prepare()
        try trackerReplay(arrayResult)
        #expect(arrayResult.value == [3, 2, 1, 4])
    }

    @Test func equalAssignmentsDetachPreviousHandles() throws {
        let base: JSONValue = ["object": ["nested": ["value": 1]], "array": [["value": 1]], "rows": [["value": 1]]]
        let tracker = try Delta.track(base)
        let change = tracker.beginChange()
        let oldObject = try trackerChild(change.state, "object")
        let oldArray = try trackerChild(change.state, "array")
        let rows = try trackerChild(change.state, "rows")
        let oldRow = try trackerChild(rows, 0)
        try change.state.set("object", ["nested": ["value": 1]])
        try change.state.set("array", [["value": 1]])
        try rows.set(0, ["value": 1])
        try trackerChild(oldObject, "nested").set("value", 9)
        try trackerChild(oldArray, 0).set("value", 9)
        try oldRow.set("value", 9)
        #expect(try change.state.snapshot() == base)
        let prepared = try change.prepare()
        #expect(prepared.ops.isEmpty)
        try tracker.adopt(prepared)
        #expect(tracker.value == base)
    }

    @Test func preservesIntegerAndStringKeyOrderAcrossReaddition() throws {
        let tracker = try Delta.track(["object": ["1": "one", "2": "two", "first": "a", "second": "b"]])
        let change = tracker.beginChange()
        let object = try trackerChild(change.state, "object")
        try object.remove("2"); try object.set("2", "two")
        try object.remove("first"); try object.set("first", "a")
        try object.set("3", "three"); try object.set("0", "zero")
        #expect(try object.keys() == ["0", "1", "2", "3", "second", "first"])
        let prepared = try change.prepare()
        #expect(prepared.value["object"]?.objectValue?.keys == ["0", "1", "2", "3", "second", "first"])
        try trackerReplay(prepared)
        try tracker.adopt(prepared)
    }

    @Test func ordersIntroducedIntegerKeysForRecipeReads() throws {
        let tracker = try Delta.track(["object": ["label": "x"], "first": ""])
        let change = tracker.beginChange()
        let object = try trackerChild(change.state, "object")
        try object.set("2", "two"); try object.set("1", "one")
        #expect(try object.keys() == ["1", "2", "label"])
        try change.state.set("first", .string(try #require(try object.keys().first)))
        let prepared = try change.prepare()
        #expect(prepared.value["first"] == "1")
        try trackerReplay(prepared)
    }

    @Test func normalizesEqualContainersAndRetainsBaseKeyOrder() throws {
        let tracker = try Delta.track(["child": ["a": 1, "b": 2], "count": 0])
        let change = tracker.beginChange()
        try change.state.set("child", ["b": 2, "a": 1])
        try change.state.set("count", 1)
        let prepared = try change.prepare()
        #expect(prepared.ops == [.set(["count"], 1)])
        #expect(prepared.value["child"]?.objectValue?.keys == ["a", "b"])
        try trackerReplay(prepared)
    }

    @Test func repeatedIdenticalWritesKeepPendingOverrides() throws {
        let tracker = try Delta.track(["value": 0, "values": [0]])
        let change = tracker.beginChange()
        let values = try trackerChild(change.state, "values")
        try change.state.set("value", 1); try change.state.set("value", 1)
        try values.set(0, .null); try values.set(0, .null)
        try values.append(2); try values.set(1, .null); try values.set(1, .null)
        #expect(try change.prepare().value == ["value": 1, "values": [nil, nil]])
    }

    @Test func rejectsGapsAndSupportsAppendLengthGrowthAndShrink() throws {
        let tracker = try Delta.track(["optional": "remove", "values": [1, 2]])
        let change = tracker.beginChange()
        let values = try trackerChild(change.state, "values")
        trackerError("Overlay arrays cannot contain holes") { try values.set(3, 4) }
        trackerError("Overlay arrays cannot contain holes") { try values.remove("0") }
        #expect(try values.snapshot() == [1, 2])
        #expect(tracker.value["values"] == [1, 2])
        try values.set(1, 9); try values.set(2, 3)
        try values.setCount(5)
        #expect(try values.snapshot() == [1, 9, 3, nil, nil])
        try values.setCount(4)
        try change.state.remove("optional")
        trackerError("Invalid array length") { try values.setCount(-1) }
        #expect(try values.snapshot() == [1, 9, 3, nil])
        let prepared = try change.prepare()
        #expect(prepared.value == ["values": [1, 9, 3, nil]])
        try trackerReplay(prepared)
    }

    @Test func readOnlyTraversalDoesNotDirtyNodes() throws {
        let tracker = try Delta.track(["nested": ["rows": [["value": 1]]]])
        let change = tracker.beginChange()
        let root = try change.state
        #expect(try root.kind == .object)
        #expect(try root.count() == 1)
        #expect(try root.keys() == ["nested"])
        #expect(try root.contains("nested"))
        #expect(try root.get("missing") == nil)
        #expect(try root.child("missing") == nil)
        let row = try trackerChild(trackerChild(trackerChild(root, "nested"), "rows"), 0)
        #expect(try row.get("value") == 1)
        #expect(try row.child("value") == nil)
        #expect(try change.prepare().ops.isEmpty)
    }

    @Test func copiesPropertyIndexAndStructuralPlacementsImmediately() throws {
        let tracker = try Delta.track(["property": nil, "values": [["value": 0], ["value": 1], ["value": 2]]])
        let change = tracker.beginChange()
        var external: JSONValue = ["value": 5]
        let values = try trackerChild(change.state, "values")
        try change.state.set("property", external)
        try values.set(0, external); try values.append(external)
        try values.prepend(contentsOf: [external])
        _ = try values.splice(2, deleteCount: 0, insert: [external])
        external = ["value": 99]
        #expect(external == ["value": 99])
        let prepared = try change.prepare()
        #expect(prepared.value["property"] == ["value": 5])
        #expect(prepared.value["values"] == [["value": 5], ["value": 5], ["value": 5], ["value": 1], ["value": 2], ["value": 5]])
        try trackerReplay(prepared)
    }

    @Test func copiesDraftSnapshotsWithinAndAcrossRevisions() throws {
        let tracker = try Delta.track(["a": ["child": ["value": 1]], "b": nil, "rows": [["child": ["value": 1]], ["child": ["value": 2]]]])
        let first = tracker.beginChange()
        let rows = try trackerChild(first.state, "rows")
        try first.state.set("b", try trackerChild(first.state, "a").snapshot())
        try trackerChild(trackerChild(first.state, "b"), "child").set("value", 3)
        try rows.set(1, try trackerChild(rows, 0).snapshot())
        let prepared = try first.prepare()
        #expect(prepared.value["a"]?["child"]?["value"] == 1)
        #expect(prepared.value["b"]?["child"]?["value"] == 3)
        try tracker.adopt(prepared)
        let second = tracker.beginChange()
        try trackerChild(trackerChild(trackerChild(second.state, "rows"), 1), "child").set("value", 4)
        let next = try second.prepare()
        #expect(next.value["rows"]?[0]?["child"]?["value"] == 1)
        #expect(next.value["rows"]?[1]?["child"]?["value"] == 4)
        try trackerReplay(next)
    }

    @Test func foldsIntroducedSubtreeEditsIntoPlacementPayloads() throws {
        let tracker = try Delta.track(["nested": nil, "rows": []])
        let change = tracker.beginChange()
        try change.state.set("nested", ["rows": [["value": 1]]])
        let nestedRows = try trackerChild(trackerChild(change.state, "nested"), "rows")
        try trackerChild(nestedRows, 0).set("value", 2)
        try nestedRows.append(["value": 3])
        let rows = try trackerChild(change.state, "rows")
        try rows.append(["values": [1]])
        try trackerChild(trackerChild(rows, 0), "values").append(2)
        let prepared = try change.prepare()
        #expect(prepared.ops == [.set(["nested"], ["rows": [["value": 2], ["value": 3]]]), .splice(["rows"], index: 0, remove: 0, items: [["values": [1, 2]]])])
        try trackerReplay(prepared)
    }

    @Test func structuralMutatorsReturnSnapshotsAndClampSplice() throws {
        let tracker = try Delta.track(["values": [3, 1, 2]])
        let change = tracker.beginChange()
        let values = try trackerChild(change.state, "values")
        try values.append(4); #expect(try values.popLast() == 4)
        try values.prepend(contentsOf: [0]); #expect(try values.popFirst() == 0)
        #expect(try values.splice(1, deleteCount: 1, insert: [5, 4]) == [1])
        try values.reverse()
        #expect(try values.snapshot() == [2, 4, 5, 3])
        #expect(try values.splice(-2, deleteCount: nil, insert: []) == [5, 3])
        #expect(try values.splice(99, deleteCount: nil, insert: []) == [])
        #expect(try values.splice(0, deleteCount: -2, insert: []) == [])
        #expect(try values.splice(-99, deleteCount: 99, insert: []) == [2, 4])
        #expect(try values.popFirst() == nil)
        #expect(try values.popLast() == nil)
        try trackerReplay(change.prepare())
    }

    @Test func heldHandlesFollowReindexingAndIgnoreDetachedWrites() throws {
        let tracker = try Delta.track(["child": ["value": "removed"], "values": [["value": "a"], ["value": "b"], ["value": "c"]]])
        let change = tracker.beginChange()
        let child = try trackerChild(change.state, "child")
        let values = try trackerChild(change.state, "values")
        let held = try trackerChild(values, 1)
        try values.prepend(contentsOf: [["value": "front"]])
        try held.set("value", "moved")
        #expect(try trackerChild(values, 2).get("value") == "moved")
        _ = try values.splice(2, deleteCount: 1, insert: [])
        try held.set("value", "detached")
        try change.state.remove("child")
        try child.set("value", "detached child")
        let prepared = try change.prepare()
        #expect(prepared.value == ["values": [["value": "front"], ["value": "a"], ["value": "c"]]])
        try trackerReplay(prepared)
    }

    @Test func introducedHandlesFollowMovementAndNestedWrites() throws {
        let tracker = try Delta.track(["values": []])
        let change = tracker.beginChange()
        let values = try trackerChild(change.state, "values")
        try values.append(["id": 1, "nested": [1]])
        let held = try trackerChild(values, 0)
        try values.prepend(contentsOf: [["id": 0, "nested": []]])
        try trackerChild(held, "nested").append(2)
        try values.reverse()
        try trackerChild(held, "nested").append(3)
        let prepared = try change.prepare()
        #expect(prepared.value == ["values": [["id": 1, "nested": [1, 2, 3]], ["id": 0, "nested": []]]])
        try trackerReplay(prepared)
    }

    @Test func movementUsesFinalPathsForHeldChildEdits() throws {
        let tracker = try Delta.track(["values": [["rank": 3, "edited": 0], ["rank": 1, "edited": 0], ["rank": 2, "edited": 0]]])
        let change = tracker.beginChange()
        let values = try trackerChild(change.state, "values")
        let held = try trackerChild(values, 0)
        try values.reverse()
        try held.set("edited", 1)
        let prepared = try change.prepare()
        #expect(prepared.ops.first == .move(["values"], permutation: [2, 1, 0]))
        #expect(prepared.ops.last == .set(["values", 2, "edited"], 1))
        try trackerReplay(prepared)
    }

    @Test func restoresOverridesAndCancelsStructuralEdits() throws {
        let tracker = try Delta.track(["values": [1, 2, 3]])
        let change = tracker.beginChange()
        let values = try trackerChild(change.state, "values")
        try values.set(1, 9); try values.set(1, 2)
        try values.reverse(); try values.reverse()
        try values.append(4); #expect(try values.popLast() == 4)
        let prepared = try change.prepare()
        #expect(prepared.value == ["values": [1, 2, 3]])
        #expect(prepared.ops.isEmpty)
    }

    @Test func sparseNullWritesKeepExplicitNulls() throws {
        let tracker = try Delta.track(["values": .array((0..<10_000).map { .number(Double($0)) })])
        let change = tracker.beginChange()
        let values = try trackerChild(change.state, "values")
        try values.set(17, .null); try values.set(9_000, .null)
        let prepared = try change.prepare()
        #expect(prepared.value["values"]?[17] == .null)
        #expect(prepared.value["values"]?[9_000] == .null)
        #expect(prepared.ops.count == 2)
        try trackerReplay(prepared)
    }

    @Test func sharesUnchangedValuesAndMakesRepeatedPlacementsIndependent() throws {
        let tracker = try Delta.track(["changed": ["count": 1, "sibling": ["value": "kept"]], "untouched": ["value": 2], "values": [["value": 1], ["value": 2]]])
        let base = tracker.value
        let change = tracker.beginChange()
        try trackerChild(change.state, "changed").set("count", 3)
        let values = try trackerChild(change.state, "values")
        let held = try trackerChild(values, 0)
        try values.prepend(contentsOf: [held.snapshot()])
        try held.set("value", 9)
        let shared: JSONValue = ["value": 1]
        try values.append(contentsOf: [shared, shared])
        try trackerChild(values, 3).set("value", 7)
        let prepared = try change.prepare()
        #expect(prepared.value["changed"]?["sibling"] == base["changed"]?["sibling"])
        #expect(prepared.value["untouched"] == base["untouched"])
        #expect(prepared.value["values"] == [["value": 1], ["value": 9], ["value": 2], ["value": 7], ["value": 1]])
        try tracker.adopt(prepared)
        #expect(base["changed"]?["count"] == 1)
    }

    @Test func emitsAppendAndRollingWindowOperations() throws {
        let tracker = try Delta.track(["text": "abcdefgh"])
        let first = tracker.beginChange()
        try first.state.set("text", "abcdefghij")
        let appended = try first.prepare()
        #expect(appended.ops == [.append(["text"], "ij")])
        try tracker.adopt(appended)
        let second = tracker.beginChange()
        try second.state.set("text", "defghijxyz")
        #expect(try second.prepare().ops == [.trim(["text"], 3), .append(["text"], "xyz")])
    }

    @Test func reverseDepthObjectEditsKeepShallowFirstEmission() throws {
        var base: JSONValue = ["value": 0]
        for _ in 0..<512 { base = ["value": 0, "next": base] }
        let tracker = try Delta.track(base)
        let change = tracker.beginChange()
        var nodes = [try change.state]
        while let next = try nodes.last?.child("next") { nodes.append(next) }
        for index in nodes.indices.reversed() { try nodes[index].set("value", .number(Double(index + 1))) }
        let prepared = try change.prepare()
        #expect(prepared.ops.count == nodes.count)
        var path: Delta.Path = []
        var value = prepared.value
        for index in nodes.indices {
            #expect(prepared.ops[index] == .set(path + ["value"], .number(Double(index + 1))))
            #expect(value["value"] == .number(Double(index + 1)))
            if let next = value["next"] { value = next }
            path.append("next")
        }
    }

    @Test func foldsReservedOwnKeysAtNearestSafeAncestor() throws {
        let base = try JSONValue(jsonText: #"{"safe":{"__proto__":{"value":1}}}"#)
        let tracker = try Delta.track(base)
        let change = tracker.beginChange()
        try trackerChild(trackerChild(change.state, "safe"), "__proto__").set("value", 2)
        let prepared = try change.prepare()
        #expect(prepared.ops == [.set(["safe"], ["__proto__": ["value": 2]])])
        try trackerReplay(prepared)
        try tracker.adopt(prepared)
        #expect(tracker.value["safe"]?["__proto__"]?["value"] == 2)
    }

    @Test func concurrentPreparationsHaveOneWinnerAndSettledDraftThrowsAcrossTasks() async throws {
        let tracker = try Delta.track(["value": 0])
        let firstTask = Task.detached {
            let change = tracker.beginChange()
            let draft = try change.state
            try draft.set("value", 1)
            return (try change.prepare(), draft)
        }
        let secondTask = Task.detached {
            let change = tracker.beginChange()
            try change.state.set("value", 2)
            return try change.prepare()
        }
        let (first, held) = try await firstTask.value
        let second = try await secondTask.value
        try tracker.adopt(first)
        trackerError("Prepared change is stale") { try tracker.adopt(second) }
        let errorText = await Task.detached {
            do { _ = try held.snapshot(); return "No error" }
            catch { return String(describing: error) }
        }.value
        #expect(errorText == "Cannot use a settled overlay")
        #expect(tracker.value == ["value": 1])
    }
    @Test func rejectsNonFinitePlacementsWithoutPartialMutation() throws {
        let base: JSONValue = ["number": 0, "payload": nil, "values": [1, 2]]
        let tracker = try Delta.track(base)
        let change = tracker.beginChange()
        let root = try change.state
        let values = try trackerChild(root, "values")
        let text = "Value contains a non-finite number and is not strict JSON"
        trackerError(text) { try root.set("number", .number(.nan)) }
        trackerError(text) { try root.set("payload", ["nested": .number(.infinity)]) }
        trackerError(text) { try values.set(0, .number(-.infinity)) }
        trackerError(text) { try values.append(contentsOf: [["staged": true], .number(.nan)]) }
        trackerError(text) { try values.prepend(contentsOf: [.number(.infinity)]) }
        trackerError(text) { _ = try values.splice(1, deleteCount: 1, insert: [.number(.nan)]) }
        #expect(try root.snapshot() == base)
        #expect(tracker.value == base)
        change.abort()
        for primitive in [JSONValue.null, true, 1, "text"] {
            #expect(throws: TrackerError.self) { _ = try Delta.track(primitive) }
        }
    }

    @Test func enumeratesWideObjectsWithoutDuplicateKeys() throws {
        let tracker = try Delta.track(["values": [:]])
        let change = tracker.beginChange()
        let values = try trackerChild(change.state, "values")
        for index in 0..<20_000 { try values.set("field\(index)", .number(Double(index))) }
        let keys = try values.keys()
        #expect(keys.count == 20_000)
        #expect(Set(keys).count == keys.count)
        #expect(keys.first == "field0")
        #expect(keys.last == "field19999")
        change.abort()
    }

    @Test func documentFieldsDoNotConflictWithDraftStorage() throws {
        let tracker = try Delta.track(["object": ["context": 1, "base": 2, "parent": 3, "dirty": 4, "target": 5, "proxy": 6]])
        let change = tracker.beginChange()
        let object = try trackerChild(change.state, "object")
        try object.set("context", 7); try object.set("proxy", 8)
        #expect(try object.keys() == ["context", "base", "parent", "dirty", "target", "proxy"])
        let prepared = try change.prepare()
        #expect(prepared.value["object"] == ["context": 7, "base": 2, "parent": 3, "dirty": 4, "target": 5, "proxy": 8])
        try tracker.adopt(prepared)
    }

    @Test func detachedOperationMetadataDoesNotChangeAdoption() throws {
        let tracker = try Delta.track(["values": [3, 1, 2]])
        let change = tracker.beginChange()
        try trackerChild(change.state, "values").reverse()
        let prepared = try change.prepare()
        var detached = prepared.ops
        detached = [.move(["values"], permutation: [0, 1, 2])]
        #expect(detached != prepared.ops)
        try tracker.adopt(prepared)
        #expect(tracker.value == ["values": [2, 1, 3]])
    }

    @Test func arrayReadsMatchEnumerableKeysAndDoNotDirty() throws {
        let tracker = try Delta.track([1, ["nested": true], nil])
        let change = tracker.beginChange()
        let draft = try change.state
        #expect(try draft.kind == .array)
        #expect(try draft.keys() == ["0", "1", "2"])
        #expect(try draft.count() == 3)
        #expect(try draft.get("length") == 3)
        #expect(try draft.get(0) == 1)
        #expect(try draft.get(3) == nil)
        #expect(try draft.get(-1) == nil)
        #expect(try draft.contains("length"))
        #expect(try draft.contains("1"))
        #expect(try draft.contains("3") == false)
        #expect(try draft.child(0) == nil)
        #expect(try draft.child(1)?.snapshot() == ["nested": true])
        trackerError("Only array indices and length can be written") { try draft.set(-1, 0) }
        trackerError("Only array indices and length can be written") { try draft.set(4_294_967_295, 0) }
        #expect(try change.prepare().ops.isEmpty)
    }

}
