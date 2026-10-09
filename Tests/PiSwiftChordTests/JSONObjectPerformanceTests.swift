import Foundation
import Testing
import PiSwiftChord

@Suite(.serialized) struct JSONObjectPerformanceTests {
    @Test func nestedArrayWritesStayWithinTimeBound() throws {
        var value: JSONValue? = ["outer": ["inner": .array((0..<100_000).map { .number(Double($0)) })]]
        var state: UInt64 = 0x434833
        let ops: [Delta.Op] = (0..<10_000).map { step in
            state = state &* 6_364_136_223_846_793_005 &+ 1
            let index = Int((state >> 32) % 100_000)
            return .set(["outer", "inner", .index(index)], .number(Double(-step)))
        }
        let clock = ContinuousClock()
        let start = clock.now
        try Delta.apply(ops, to: &value)
        let elapsed = start.duration(to: clock.now)
        print("CH3 timing: 10,000 nested array writes: \(elapsed)")
        #expect(elapsed < .milliseconds(900))
        #expect(value?["outer"]?["inner"]?.arrayValue?.count == 100_000)
        if case .set(let path, let lastValue) = try #require(ops.last), case .index(let index) = try #require(path.last) {
            #expect(value?["outer"]?["inner"]?[index] == lastValue)
        }
    }

    @Test func repeatedImmutableWritesCopyWideObjectOnce() throws {
        let object = JSONObject((0..<100_000).map { ("field\($0)", .number(Double($0))) })
        let base = JSONValue.object(object)
        let ops: [Delta.Op] = (0..<10_000).map { .set([.key("field\($0)")], .number(Double(-$0))) }
        // A payload switch must finish before mutation. Its enum reference can
        // otherwise cause a full copy for each write in a debug build.
        let clock = ContinuousClock()
        let start = clock.now
        let result = try Delta.applyImmutable(base, ops)
        let elapsed = start.duration(to: clock.now)
        print("CH3 timing: 10,000 immutable writes in 100,000-member object: \(elapsed)")
        #expect(elapsed < .milliseconds(900))
        #expect(result?["field9999"] == -9999)
        #expect(base["field9999"] == 9999)
    }

    @Test func buildsAndIteratesOneHundredThousandKeysWithinTimeBound() throws {
        let clock = ContinuousClock()
        let start = clock.now
        var object = JSONObject()
        // Mix index keys and other keys. Index keys arrive in ascending order.
        for index in 0..<100_000 {
            let key = index.isMultiple(of: 2) ? String(index) : "field\(index)"
            object[key] = .number(Double(index))
        }
        let built = clock.now
        var sum = 0.0
        for _ in 0..<20 {
            for (_, value) in object {
                if case .number(let number) = value { sum += number }
            }
        }
        let finished = clock.now
        print("CH3 timing: build 100,000-member object: \(start.duration(to: built)); 20 iterations: \(built.duration(to: finished)); total: \(start.duration(to: finished))")
        #expect(start.duration(to: finished) < .seconds(5))
        #expect(sum == 99_999_000_000)
        #expect(object.keys.prefix(3) == ["0", "2", "4"])
        #expect(object.keys.suffix(3) == ["field99995", "field99997", "field99999"])
    }
}
