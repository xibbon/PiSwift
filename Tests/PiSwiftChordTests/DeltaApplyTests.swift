import Foundation
import Testing
import PiSwiftChord

@Suite struct DeltaApplyTests {
    private func applied(_ value: JSONValue?, _ ops: [Delta.Op]) throws -> JSONValue? {
        var result = value
        try Delta.apply(ops, to: &result)
        return result
    }

    @Test func appliesMutableAndImmutableOperations() throws {
        let base: JSONValue = ["text": "a", "values": [1, 2], "nested": ["value": 1], "stable": ["value": 9]]
        let ops: [Delta.Op] = [.append(["text"], "b"), .splice(["values"], index: 1, remove: 1, items: [3, 4]), .set(["nested", "value"], 2)]
        let result = try Delta.applyImmutable(base, ops)
        #expect(result == ["text": "ab", "values": [1, 3, 4], "nested": ["value": 2], "stable": ["value": 9]])
        #expect(base == ["text": "a", "values": [1, 2], "nested": ["value": 1], "stable": ["value": 9]])
        #expect(result?["stable"] == base["stable"])
        #expect(try applied(base, ops) == result)
    }

    @Test func supportsRootReplacementSpliceAndPermutation() throws {
        let ops: [Delta.Op] = [.replace([1, 2, 3]), .splice([], index: 1, remove: 1, items: [4]), .move([], permutation: [2, 0, 1])]
        #expect(try applied(nil, ops) == [3, 1, 4])
        #expect(try applied([1, 2, 3], [.splice([], index: 10, remove: 5, items: [4, 5])]) == [1, 2, 3, 4, 5])
        #expect(try applied(nil, []) == nil)
        #expect(try Delta.applyImmutable(nil, []) == nil)
        #expect(throws: DeltaError.unresolvablePath([])) { try applied([1], [.move([], permutation: [])]) }
    }

    @Test func rejectsUnsafeAndMalformedPaths() throws {
        #expect(throws: DeltaError.unsafeSegment("constructor")) {
            try applied([:], [.set(["constructor", "prototype", "x"], true)])
        }
        #expect(throws: DeltaError.unsafeSegment(3)) { try applied(["values": [1]], [.set(["values", 3], 2)]) }
        #expect(throws: DeltaError.unresolvablePath(["value"])) { try applied(["value": 1], [.append(["value"], "x")]) }
        #expect(throws: DeltaError.invalidOperation("path is not an array")) { try Delta.Op(json: ["s", "value", 1]) }
        #expect(throws: DeltaError.invalidOperation("m permutation is not a bijection")) { try Delta.Op(json: ["m", [], [0, 0]]) }
        for key in ["__proto__", "constructor", "prototype"] {
            #expect(throws: DeltaError.unsafeSegment(.key(key))) { try Delta.assertSafePath([.key(key)]) }
        }
        #expect(throws: DeltaError.unsafeSegment(-1)) { try Delta.assertSafePath([-1]) }
        try Delta.assertSafePath([0, "ordinary", "0"])
        #expect(Delta.reservedSegments == ["__proto__", "constructor", "prototype"])
    }

    @Test func validatesImmutableOperationsBeforeTraversal() throws {
        #expect(throws: DeltaError.invalidOperation("path is empty")) { try Delta.applyImmutable(nil, [.set([], 1)]) }
        #expect(throws: DeltaError.invalidOperation("t shape")) { try Delta.applyImmutable(nil, [.trim(["missing"], -1)]) }
        #expect(throws: DeltaError.invalidOperation("m permutation is not a bijection")) {
            try Delta.applyImmutable(nil, [.move(["missing"], permutation: [0, 0])])
        }
        #expect(throws: DeltaError.invalidOperation("path is not an array")) { try Delta.Op(json: ["s", "bad-path", 1]) }
    }

    @Test func decodedVocabularyRoundTripsThroughJSONAndCodable() throws {
        let ops: [Delta.Op] = [.replace(["value": 1]), .set(["value", 0], 1), .delete(["value"]), .append(["value"], "x"), .trim(["value"], 2), .splice(["value"], index: 0, remove: 0, items: []), .move(["value"], permutation: [0])]
        let tuples: [JSONValue] = [["r", ["value": 1]], ["s", ["value", 0], 1], ["d", ["value"]], ["a", ["value"], "x"], ["t", ["value"], 2], ["p", ["value"], 0, 0, []], ["m", ["value"], [0]]]
        for (op, tuple) in zip(ops, tuples) {
            #expect(op.json == tuple)
            #expect(try Delta.Op(json: tuple) == op)
            let data = try JSONEncoder().encode(op)
            #expect(try JSONValue(jsonData: data) == tuple)
            #expect(try JSONDecoder().decode(Delta.Op.self, from: data) == op)
        }
        let wireOnly: [JSONValue] = [["s", 1], ["d"], ["a", "x"], ["t", 2], ["p", 0, 0, []], ["#", 0, ["value"]], ["s", 0, 1]]
        for tuple in wireOnly {
            #expect(throws: DeltaError.self) { try Delta.Op(json: tuple) }
        }
    }

    @Test func invalidTuplesKeepUpstreamErrorText() throws {
        let cases: [(JSONValue, String)] = [
            (.null, "op is not a tuple"), ([:], "op is not a tuple"), ([], "op is not a tuple"),
            (["r"], "r arity"), (["r", 1, 2], "r arity"), (["s", 1], "s arity"), (["d"], "d arity"),
            (["a", ["x"]], "a shape"), (["a", ["x"], 3], "a shape"), (["t", ["x"], -1], "t shape"), (["t", ["x"], 1.5], "t shape"),
            (["s", "x", 1], "path is not an array"), (["s", [], 1], "path is empty"), (["d", []], "path is empty"), (["a", [], "x"], "path is empty"), (["t", [], 0], "path is empty"),
            (["p", []], "p arity"), (["p", [], -1, 0, []], "p index"), (["p", [], 1.5, 0, []], "p index"), (["p", [], 0, -1, []], "p remove"), (["p", [], 0, 1.5, []], "p remove"), (["p", [], 0, 0, "not-an-array"], "p items"),
            (["m", []], "m arity"), (["m", [], "x"], "m permutation is not an array"), (["m", [], [0, 0]], "m permutation is not a bijection"), (["m", [], [1]], "m permutation is not a bijection"), (["m", [], [-1]], "m permutation is not a bijection"), (["m", [], [0.5]], "m permutation is not a bijection"),
            (["x"], "unknown op verb: x"), (["ZZZ", ["value"], 9], "unknown op verb: ZZZ"), ([true], "unknown op verb: true"), ([nil], "unknown op verb: null")
        ]
        for (tuple, message) in cases {
            #expect(throws: DeltaError.invalidOperation(message)) { try Delta.Op(json: tuple) }
            #expect(DeltaError.invalidOperation(message).description == message)
        }
        #expect(DeltaError.unresolvablePath(["nested", 0]).description == "unresolvable path: [\"nested\",0]")
        #expect(DeltaError.unsafeSegment("constructor").description == "unsafe path segment: constructor")
        #expect(DeltaError.unsafeSegment(-1).description == "unsafe path segment: -1")
        let invalidSegments: [(JSONValue, Delta.PathSegment)] = [(-1, -1), (0.5, "0.5"), (true, "true"), (.null, "null"), ([], ""), ([:], "[object Object]")]
        for (segment, expected) in invalidSegments {
            #expect(throws: DeltaError.unsafeSegment(expected)) { try Delta.Op(json: ["s", .array([segment]), 1]) }
        }
    }

    @Test func rejectsMetadataOutsideSwiftJSONIntegerDomain() throws {
        let inexact = 9_007_199_254_740_993
        #expect(throws: DeltaError.unsafeSegment(.index(inexact))) {
            try Delta.assertSafePath([.index(inexact)])
        }
        #expect(throws: DeltaError.invalidOperation("t shape")) {
            try applied(["text": "abc"], [.trim(["text"], Int.max)])
        }
        #expect(throws: DeltaError.invalidOperation("p index")) {
            try applied([], [.splice([], index: Int.max, remove: 0, items: [])])
        }
        #expect(throws: DeltaError.invalidOperation("p remove")) {
            try applied([], [.splice([], index: 0, remove: Int.max, items: [])])
        }
        #expect(throws: DeltaError.unsafeSegment(.index(inexact))) {
            try JSONEncoder().encode(Delta.Op.set([.index(inexact)], 1))
        }
        let largeExact = 9_007_199_254_740_992
        let ops: [Delta.Op] = [.trim(["text"], largeExact), .splice([], index: largeExact, remove: 0, items: [1])]
        for op in ops { #expect(try Delta.Op(json: op.json) == op) }
        #expect(try applied(["text": "abc"], [ops[0]]) == ["text": ""])
        #expect(try applied([], [ops[1]]) == [1])
        #expect(throws: DeltaError.invalidOperation("t shape")) { try Delta.Op(json: ["t", ["text"], 1e20]) }
        #expect(throws: DeltaError.invalidOperation("p index")) { try Delta.Op(json: ["p", [], 1e20, 0, []]) }
        #expect(throws: DeltaError.invalidOperation("p remove")) { try Delta.Op(json: ["p", [], 0, 1e20, []]) }
        #expect(throws: DeltaError.unsafeSegment("100000000000000000000")) {
            try Delta.Op(json: ["s", [1e20], 1])
        }
        #expect(Delta.PathSegment.key("é") != .key("e\u{301}"))
        #expect(Delta.Op.append(["text"], "é") != .append(["text"], "e\u{301}"))
    }

    @Test func acceptsPayloadsWithoutRecursiveValidation() throws {
        let payload: JSONValue = ["__proto__": ["z": 1], "constructor": ["prototype": true], "number": .number(.infinity)]
        let op = try Delta.Op(json: ["s", ["value"], payload])
        #expect(op == .set(["value"], payload))
        #expect(try applied([:], [op])?["value"] == payload)
        #expect(try Delta.Op(json: ["r", payload]) == .replace(payload))
    }

    @Test func preservesReplacementPayloadBeforeLaterWrite() throws {
        let payload: JSONValue = ["nested": ["value": 1]]
        let result = try Delta.applyImmutable(nil, [.replace(payload), .set(["nested", "value"], 2)])
        #expect(payload["nested"]?["value"] == 1)
        #expect(result?["nested"]?["value"] == 2)
    }

    @Test func rejectsConstructorWalksAndAllowsReservedNamesInValues() throws {
        let tuple = try JSONValue(jsonText: #"["s",["constructor","prototype","gadget"],true]"#)
        #expect(throws: DeltaError.unsafeSegment("constructor")) { try Delta.Op(json: tuple) }
        let payload = try JSONValue(jsonText: #"{"__proto__":{"z":1}}"#)
        let result = try applied([:], [.set(["value"], payload)])
        #expect(result?["value"]?.objectValue?.contains("__proto__") == true)
        #expect(result?["value"]?["__proto__"]?["z"] == 1)
    }

    @Test func writesExistingArrayIndexAndAppendsAtTheEnd() throws {
        #expect(try applied(["values": [1, 2, 3]], [.set(["values", 1], 9)]) == ["values": [1, 9, 3]])
        #expect(try applied(["values": [1, 2, 3]], [.set(["values", 3], 9)]) == ["values": [1, 2, 3, 9]])
        #expect(try applied([:], [.set([0], "zero"), .set(["nested"], ["0": 1]), .set(["nested", 0], 2)]) == ["0": "zero", "nested": ["0": 2]])
    }

    @Test func rejectsArrayGapsHugeIndicesAndStringIndices() throws {
        #expect(throws: DeltaError.unsafeSegment(5)) { try applied(["values": [1, 2, 3]], [.set(["values", 5], 9)]) }
        #expect(throws: DeltaError.unsafeSegment(4_294_967_290)) { try applied(["values": []], [.set(["values", 4_294_967_290], 1)]) }
        #expect(throws: DeltaError.unsafeSegment("0")) { try applied(["values": [1]], [.set(["values", "0"], 9)]) }
        #expect(throws: DeltaError.unsafeSegment("0")) { try applied(["values": ["a"]], [.append(["values", "0"], "b")]) }
    }

    @Test func allowsExplicitGrowthAndRejectsDeletionPastTheEnd() throws {
        #expect(try applied(["values": [1]], [.splice(["values"], index: 1, remove: 0, items: [nil, nil, 9])]) == ["values": [1, nil, nil, 9]])
        #expect(throws: DeltaError.unresolvablePath(["values", 1])) { try applied(["values": [1]], [.delete(["values", 1])]) }
        #expect(throws: DeltaError.unsafeSegment(2)) { try applied(["values": [1]], [.delete(["values", 2])]) }
        #expect(try applied(["value": 1], [.delete(["missing"])]) == ["value": 1])
        #expect(try applied([1, 2, 3], [.delete([1])]) == [1, 3])
    }

    @Test func appliesLargeSplicePayload() throws {
        let items = [JSONValue](repeating: .null, count: 300_000)
        let result = try applied(["values": []], [.splice(["values"], index: 0, remove: 0, items: items)])
        #expect(result?["values"]?.arrayValue?.count == items.count)
    }

    @Test func rejectsInvalidAppendAndTrimAndClampsSpliceRemoval() throws {
        #expect(throws: DeltaError.unresolvablePath(["missing"])) { try applied(["value": 1], [.append(["missing"], "x")]) }
        #expect(throws: DeltaError.unresolvablePath(["value"])) { try applied(["value": 1], [.append(["value"], "x")]) }
        #expect(throws: DeltaError.invalidOperation("t shape")) { try applied(["value": "abc"], [.trim(["value"], -1)]) }
        #expect(try applied(["values": [1, 2]], [.splice(["values"], index: 0, remove: 1_000_000_000, items: [])]) == ["values": []])
        let emptyPathOps: [Delta.Op] = [.set([], 1), .delete([]), .append([], "x"), .trim([], 1)]
        for op in emptyPathOps {
            #expect(throws: DeltaError.invalidOperation("path is empty")) { try applied([:], [op]) }
        }
        #expect(throws: DeltaError.invalidOperation("p index")) { try applied([], [.splice([], index: -1, remove: 0, items: [])]) }
        #expect(throws: DeltaError.invalidOperation("p remove")) { try applied([], [.splice([], index: 0, remove: -1, items: [])]) }
        #expect(throws: DeltaError.unsafeSegment(-1)) { try applied([], [.set([-1], 1)]) }
        #expect(throws: DeltaError.invalidOperation("m permutation is not a bijection")) { try applied([], [.move([], permutation: [0, 0])]) }
    }

    @Test func trimCountsUTF16AndRejectsSplitSurrogatePairs() throws {
        #expect(try applied(["text": "😀e\u{301}x"], [.trim(["text"], 2)]) == ["text": "e\u{301}x"])
        #expect(try applied(["text": "😀e\u{301}x"], [.trim(["text"], 3)]) == ["text": "\u{301}x"])
        #expect(try applied(["text": "😀"], [.trim(["text"], 20)]) == ["text": ""])
        #expect(throws: DeltaError.invalidOperation("t splits a surrogate pair")) { try applied(["text": "😀x"], [.trim(["text"], 1)]) }
    }

    @Test func mutableFailureKeepsEarlierChangesAndImmutableFailureProtectsInput() throws {
        let base: JSONValue = ["value": 1, "text": "a"]
        let ops: [Delta.Op] = [.set(["value"], 2), .append(["missing"], "x")]
        var mutable: JSONValue? = base
        #expect(throws: DeltaError.self) { try Delta.apply(ops, to: &mutable) }
        #expect(mutable == ["value": 2, "text": "a"])
        #expect(throws: DeltaError.self) { try Delta.applyImmutable(base, ops) }
        #expect(base == ["value": 1, "text": "a"])
    }

    @Test func immutableApplicationProtectsInputAndPlacedPayloads() throws {
        let shared: JSONValue = ["nested": ["value": 1]]
        let untouched: JSONValue = ["value": 9]
        let row: JSONValue = ["id": 4, "label": "placed"]
        let base: JSONValue = ["text": "abcdef", "stable": ["value": 7], "branch": ["value": 1], "copy": nil, "placed": nil, "untouched": nil, "left": nil, "right": nil, "meta": ["count": 0, "obsolete": true], "rows": [["id": 1, "label": "one"], ["id": 2, "label": "two"], ["id": 3, "label": "three"]]]
        let ops: [Delta.Op] = [.trim(["text"], 2), .append(["text"], "!"), .set(["meta", "count"], 1), .set(["meta", "count"], 2), .delete(["meta", "obsolete"]), .set(["copy"], try #require(base["branch"])), .set(["copy", "value"], 2), .set(["placed"], shared), .set(["placed", "nested", "value"], 2), .set(["untouched"], untouched), .set(["left"], shared), .set(["right"], shared), .set(["left", "nested", "value"], 3), .splice(["rows"], index: 1, remove: 1, items: [row]), .set(["rows", 1, "label"], "edited"), .move(["rows"], permutation: [1, 0, 2]), .set(["rows", 0, "label"], "moved")]
        let result = try Delta.applyImmutable(base, ops)
        #expect(result == (try applied(base, ops)))
        #expect(result?["text"] == "cdef!")
        #expect(result?["stable"] == base["stable"])
        #expect(result?["untouched"] == untouched)
        #expect(result?["copy"] == ["value": 2])
        #expect(result?["placed"] == ["nested": ["value": 2]])
        #expect(result?["left"] == ["nested": ["value": 3]])
        #expect(result?["right"] == shared)
        #expect(result?["rows"]?[0] == ["id": 4, "label": "moved"])
        #expect(base["branch"]?["value"] == 1)
        #expect(shared["nested"]?["value"] == 1)
        #expect(row["label"] == "placed")
    }

    @Test func immutableBatchesProtectRootReplacementAndRootArrays() throws {
        let payload: JSONValue = ["nested": ["value": 1], "values": [1, 2, 3]]
        let batches: [[Delta.Op]] = [[.replace(payload)], [.set(["nested", "value"], 2)], [.splice(["values"], index: 1, remove: 1, items: [4, 5]), .move(["values"], permutation: [3, 0, 1, 2])]]
        #expect(try Delta.applyImmutableBatches(nil, batches) == ["nested": ["value": 2], "values": [3, 1, 4, 5]])
        #expect(payload == ["nested": ["value": 1], "values": [1, 2, 3]])
        let array: JSONValue = [1, 2, 3]
        #expect(try Delta.applyImmutable(array, [.splice([], index: 1, remove: 1, items: [4, 5]), .move([], permutation: [3, 0, 1, 2]), .delete([1])]) == [3, 4, 5])
        #expect(array == [1, 2, 3])
    }

    @Test func immutableBatchesEqualSequentialAndFlattenedReplay() throws {
        let base: JSONValue = ["text": "abcdef", "meta": ["count": 0], "values": [["id": 1, "value": 1], ["id": 2, "value": 2], ["id": 3, "value": 3]]]
        let batches: [[Delta.Op]] = [[.set(["meta", "count"], 1), .splice(["values"], index: 1, remove: 1, items: [["id": 4, "value": 4]])], [], [.move(["values"], permutation: [2, 0, 1]), .set(["values", 2, "value"], 40)], [.trim(["text"], 2), .append(["text"], "!")]]
        let intermediate = try Delta.applyImmutable(base, batches[0])
        let snapshot = intermediate
        var sequential = intermediate
        for batch in batches.dropFirst() { sequential = try Delta.applyImmutable(sequential, batch) }
        let streamed = try Delta.applyImmutableBatches(base, batches)
        #expect(streamed == sequential)
        #expect(streamed == (try Delta.applyImmutable(base, batches.flatMap { $0 })))
        #expect(intermediate == snapshot)
        #expect(base["meta"]?["count"] == 0)
        #expect(base["values"]?[1]?["id"] == 2)
    }

    @Test func handWrittenRevisionBatchesReplayAcrossBoundaries() throws {
        let rows: [JSONValue] = (0..<8).map { ["id": .number(Double($0)), "score": 0] }
        let initial: JSONValue = ["text": "start", "values": .array(rows), "revision": 0]
        var batches: [[Delta.Op]] = []
        var expected = initial
        var currentRows = rows
        var text = "start"
        for revision in 1...40 {
            text = String(text.dropFirst()) + String(revision)
            var batch: [Delta.Op] = [.set(["revision"], .number(Double(revision))), .trim(["text"], 1), .append(["text"], String(revision))]
            let row: JSONValue = ["id": .number(Double(100 + revision)), "score": .number(Double(revision))]
            switch revision % 5 {
            case 0:
                batch.append(.move(["values"], permutation: Array(currentRows.indices.reversed())))
                currentRows.reverse()
            case 1:
                batch.append(.splice(["values"], index: currentRows.count, remove: 0, items: [row]))
                currentRows.append(row)
            case 2:
                batch.append(.delete(["values", 0]))
                currentRows.removeFirst()
            case 3:
                let index = revision % currentRows.count
                batch.append(.set(["values", .index(index), "score"], .number(Double(revision))))
                var object = try #require(currentRows[index].objectValue)
                object["score"] = .number(Double(revision))
                currentRows[index] = .object(object)
            default:
                let replacement: JSONValue = ["id": .number(Double(200 + revision)), "score": .number(Double(revision))]
                batch.append(.splice(["values"], index: 1, remove: 1, items: [replacement]))
                currentRows[1] = replacement
            }
            batches.append(batch)
            expected = ["text": .string(text), "values": .array(currentRows), "revision": .number(Double(revision))]
        }
        #expect(try Delta.applyImmutableBatches(initial, batches) == expected)
        for boundary in [0, 1, 7, 20, 39, 40] {
            let prefix = try Delta.applyImmutableBatches(initial, batches.prefix(boundary))
            #expect(try Delta.applyImmutableBatches(prefix, batches.dropFirst(boundary)) == expected)
        }
        #expect(initial["revision"] == 0)
    }

    @Test func failedImmutableBatchStopsIterationAndProtectsInput() throws {
        final class State { var requested = 0 }
        struct Batches: Sequence, IteratorProtocol {
            let state: State
            mutating func next() -> [Delta.Op]? {
                state.requested += 1
                switch state.requested {
                case 1: return [.set(["nested", "value"], 4)]
                case 2: return [.set(["__proto__", "polluted"], true)]
                default: return nil
                }
            }
            func makeIterator() -> Self { self }
        }
        let state = State()
        let base: JSONValue = ["nested": ["value": 1]]
        #expect(throws: DeltaError.unsafeSegment("__proto__")) { try Delta.applyImmutableBatches(base, Batches(state: state)) }
        #expect(state.requested == 2)
        #expect(base["nested"]?["value"] == 1)
        #expect(throws: DeltaError.unresolvablePath(["values", "missing"])) { try Delta.applyImmutable(["values": []], [.set(["values", "missing", "value"], 1)]) }
        #expect(throws: DeltaError.unsafeSegment("0")) { try Delta.applyImmutable(["values": [[:]]], [.set(["values", "0", "value"], 1)]) }
        #expect(throws: DeltaError.invalidOperation("path is empty")) { try Delta.applyImmutableBatches(nil, [[.set([], 1)]]) }
    }

    @Test func immutableBatchFanOutProtectsSharedPayloads() throws {
        let payload: JSONValue = ["nested": ["value": 1]]
        let ops: [Delta.Op] = [.set(["placed"], payload), .set(["placed", "nested", "value"], 2)]
        let base: JSONValue = ["placed": nil]
        let first = try Delta.applyImmutable(base, ops)
        let second = try Delta.applyImmutable(base, ops)
        #expect(first == second)
        #expect(first?["placed"] == ["nested": ["value": 2]])
        #expect(payload["nested"]?["value"] == 1)
        #expect(base["placed"] == .null)
    }
}
