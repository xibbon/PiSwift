import Foundation
import Testing
import PiSwiftChord

@Suite(.serialized) struct TrackerPerformanceTests {
    private func elapsed(_ name: String, _ action: () throws -> Void) throws {
        let clock = ContinuousClock()
        let start = clock.now
        try action()
        let duration = start.duration(to: clock.now)
        print("Tracker timing \(name): \(duration)")
        #expect(duration < .seconds(10), "\(name) exceeded 10 seconds")
    }

    @Test(arguments: [false, true]) func insertsOneHundredThousandItems(prepend: Bool) throws {
        try elapsed(prepend ? "100000 prepend" : "100000 splice") {
            let tracker = try Delta.track(["values": [-1]])
            let change = tracker.beginChange()
            let values = try #require(try change.state.child("values"))
            let items: [JSONValue] = (0..<100_000).map { .number(Double($0)) }
            if prepend { try values.prepend(contentsOf: items) }
            else { _ = try values.splice(1, deleteCount: 0, insert: items) }
            let prepared = try change.prepare()
            #expect(prepared.value["values"]?.arrayValue?.count == 100_001)
            #expect(prepared.value["values"]?[prepend ? 0 : 1] == 0)
            #expect(prepared.value["values"]?[prepend ? 99_999 : 100_000] == 99_999)
            #expect(try Delta.applyImmutable(prepared.base, prepared.ops) == prepared.value)
            try tracker.adopt(prepared)
        }
    }

    @Test func queueTransactionFoldsTwentyThousandEditsToTwoOps() throws {
        try elapsed("20000 queue operations") {
            let tracker = try Delta.track(["values": .array((0..<20_000).map { ["value": .number(Double($0))] })])
            let change = tracker.beginChange()
            let values = try #require(try change.state.child("values"))
            for index in 0..<10_000 {
                _ = try values.popFirst()
                try values.append(["value": .number(Double(20_000 + index))])
            }
            let prepared = try change.prepare()
            #expect(prepared.ops.count == 2)
            #expect(prepared.value["values"]?[0]?["value"] == 10_000)
            #expect(prepared.value["values"]?[19_999]?["value"] == 29_999)
            #expect(try Delta.applyImmutable(prepared.base, prepared.ops) == prepared.value)
            try tracker.adopt(prepared)
        }
    }

    @Test func adversarialFragmentationKeepsHeldHandles() throws {
        try elapsed("20000 fragmented slots") {
            let tracker = try Delta.track(["values": .array((0..<20_000).map { ["value": .number(Double($0))] })])
            let change = tracker.beginChange()
            let values = try #require(try change.state.child("values"))
            let indices = [1, 1_001, 5_001, 10_001, 15_001, 19_999]
            let held = try indices.map { try #require(try values.child($0)) }
            for index in stride(from: 0, to: 20_000, by: 2) {
                _ = try values.splice(index, deleteCount: 1, insert: [["value": .number(Double(-index - 1))]])
            }
            for (index, handle) in zip(indices, held) { try handle.set("value", .number(Double(index + 100_000))) }
            let prepared = try change.prepare()
            for index in 0..<20_000 {
                let expected = indices.contains(index) ? index + 100_000 : (index.isMultiple(of: 2) ? -index - 1 : index)
                #expect(prepared.value["values"]?[index]?["value"] == .number(Double(expected)))
            }
            #expect(try Delta.applyImmutable(prepared.base, prepared.ops) == prepared.value)
            try tracker.adopt(prepared)
        }
    }

    @Test func tenThousandWideObjectWrites() throws {
        try elapsed("10000 wide object writes") {
            var base = JSONObject()
            for index in 0..<10_000 { base["field\(index)"] = 0 }
            let tracker = try Delta.track(.object(base))
            let change = tracker.beginChange()
            let draft = try change.state
            for index in 0..<10_000 { try draft.set("field\(index)", .number(Double(index + 1))) }
            #expect(try draft.keys().count == 10_000)
            let prepared = try change.prepare()
            #expect(prepared.ops == [.replace(prepared.value)])
            #expect(prepared.value["field0"] == 1)
            #expect(prepared.value["field9999"] == 10_000)
            #expect(try Delta.applyImmutable(prepared.base, prepared.ops) == prepared.value)
        }
    }
}
