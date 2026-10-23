import Foundation
import Testing
import PiSwiftChord

@Suite struct OrderedArrayPlanTests {
    @Test func appendToTenThousandItemsEmitsOneInsert() throws {
        let base: JSONValue = ["values": .array((0..<10_000).map { .number(Double($0)) })]
        let tracker = try Delta.track(base)
        let change = tracker.beginChange()
        let values = try #require(try change.state.child("values"))
        try values.append(-1)
        let prepared = try change.prepare()
        #expect(prepared.ops == [.splice(["values"], index: 10_000, remove: 0, items: [-1])])
        #expect(try Delta.applyImmutable(base, prepared.ops) == prepared.value)
        try tracker.adopt(prepared)
        #expect(tracker.value["values"]?.arrayValue?.count == 10_001)
        #expect(tracker.value["values"]?[10_000] == -1)
    }

    // chord v1.3.0 delta-tracker/tracker.test.ts:939.
    @Test func orderedEditsEmitExactlySixOperations() throws {
        let base: JSONValue = ["values": [0, 1, 2, 3, 4, 5, 6, 7, 8, 9]]
        let tracker = try Delta.track(base)
        let change = tracker.beginChange()
        let values = try #require(try change.state.child("values"))
        _ = try values.popFirst()
        try values.splice(1, deleteCount: 2, insert: [20])
        try values.splice(5, deleteCount: 1)
        _ = try values.popLast()
        try values.append(30)
        let prepared = try change.prepare()
        #expect(prepared.ops == [
            .splice(["values"], index: 9, remove: 1, items: []),
            .splice(["values"], index: 7, remove: 1, items: []),
            .splice(["values"], index: 2, remove: 2, items: []),
            .splice(["values"], index: 0, remove: 1, items: []),
            .splice(["values"], index: 1, remove: 0, items: [20]),
            .splice(["values"], index: 6, remove: 0, items: [30]),
        ])
        #expect(prepared.value == ["values": [1, 20, 4, 5, 6, 8, 30]])
        #expect(try Delta.applyImmutable(base, prepared.ops) == prepared.value)
        try tracker.adopt(prepared)
        #expect(tracker.value == prepared.value)
    }

    @Test(arguments: [false, true]) func reorderedElementsUsePermutation(remove: Bool) throws {
        let tracker = try Delta.track(["values": [0, 1, 2, 3, 4]])
        let change = tracker.beginChange()
        let values = try #require(try change.state.child("values"))
        try values.reverse()
        if remove { try values.splice(1, deleteCount: 1, insert: [9]) }
        let prepared = try change.prepare()
        #expect(prepared.ops.contains { if case .move = $0 { true } else { false } })
        #expect(prepared.value == (remove ? ["values": [4, 9, 2, 1, 0]] : ["values": [4, 3, 2, 1, 0]]))
        #expect(try Delta.applyImmutable(prepared.base, prepared.ops) == prepared.value)
    }

    @Test func reversedRangesCanReturnToOrderedPlan() throws {
        let tracker = try Delta.track([0, 1, 2, 3])
        let change = tracker.beginChange()
        let values = try change.state
        try values.reverse()
        try values.splice(1, deleteCount: 1, insert: [9, 8])
        try values.reverse()
        let prepared = try change.prepare()
        #expect(prepared.ops == [.splice([], index: 2, remove: 1, items: []), .splice([], index: 2, remove: 0, items: [8, 9])])
        #expect(try Delta.applyImmutable(prepared.base, prepared.ops) == [0, 1, 8, 9, 3])
    }

    // Swift has no draft sort operation. Reverse exercises the retained-element
    // permutation fallback from the reverse/sort upstream case at line 967.
    @Test func removingAllBaseElementsKeepsInsertedRuns() throws {
        let tracker = try Delta.track([0, 1, 2])
        let change = tracker.beginChange()
        try change.state.splice(0, deleteCount: 3, insert: [9])
        try change.state.append(8)
        let prepared = try change.prepare()
        #expect(prepared.ops == [.splice([], index: 0, remove: 3, items: []), .splice([], index: 0, remove: 0, items: [9, 8])])
        #expect(try Delta.applyImmutable(prepared.base, prepared.ops) == [9, 8])
    }

    @Test func immutableAppendPreservesInputAndSharedArrays() throws {
        let entries: [JSONValue] = (0..<1_000).map { ["index": .number(Double($0)), "stable": [1, 2]] }
        let base: JSONValue = ["log": ["entries": .array(entries), "meta": [1_000]], "other": [1]]
        let result = try #require(try Delta.applyImmutable(base, [
            .splice(["log", "entries"], index: 1_000, remove: 0, items: [["index": 1_000]]),
            .splice(["log", "entries"], index: 1_001, remove: 0, items: [["index": 1_001]])
        ]))
        #expect(result["log"]?["entries"]?.arrayValue?.count == 1_002)
        #expect(result["log"]?["entries"]?[1_001] == ["index": 1_001])
        #expect(base["log"]?["entries"]?.arrayValue?.count == 1_000)
        for path in [["other"], ["log", "meta"], ["log", "entries", "0", "stable"]] {
            func array(_ root: JSONValue) throws -> [JSONValue] {
                var value = root
                for key in path { value = try #require(Int(key).map { value[$0] } ?? value[key]) }
                return try #require(value.arrayValue)
            }
            let before = try array(base), after = try array(result)
            #expect(before.withUnsafeBufferPointer { left in after.withUnsafeBufferPointer { right in left.baseAddress == right.baseAddress } })
        }
        let root: JSONValue = [1, 2]
        #expect(try Delta.applyImmutable(root, [.splice([], index: 2, remove: 0, items: [[3, 4]])]) == [1, 2, [3, 4]])
        #expect(try Delta.applyImmutable(root, [.splice([], index: 1, remove: 0, items: [9])]) == [1, 9, 2])
        #expect(root == [1, 2])
    }

    @Test func measureImmutableAppendBatches() throws {
        let base: JSONValue = ["entries": .array((0..<100_000).map { .number(Double($0)) })]
        for count in [2, 200] {
            let ops: [Delta.Op] = (0..<count).map { .splice(["entries"], index: 100_000 + $0, remove: 0, items: [-1]) }
            let clock = ContinuousClock()
            let start = clock.now
            for _ in 0..<10 {
                let result = try Delta.applyImmutable(base, ops)
                #expect(result?["entries"]?.arrayValue?.count == 100_000 + count)
            }
            print("D1 immutable append: 100000 base, \(count) ops x 10: \(start.duration(to: clock.now))")
        }
        #expect(base["entries"]?.arrayValue?.count == 100_000)
    }
}
