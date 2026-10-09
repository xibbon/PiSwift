import Testing
import PiSwiftChord

private struct TrackerRandom {
    var seed: UInt32
    mutating func next() -> Double {
        seed &+= 0x6d2b79f5
        var value = (seed ^ (seed >> 15)) &* (1 | seed)
        value = (value &+ ((value ^ (value >> 7)) &* (61 | value))) ^ value
        return Double(value ^ (value >> 14)) / 4_294_967_296
    }
}
private struct TrackerReferenceItem {
    var id: Int
    var text: String
    var score: Int
    func json(includeText: Bool) -> JSONValue {
        if includeText { ["id": .number(Double(id)), "text": .string(text), "score": .number(Double(score))] }
        else { ["id": .number(Double(id)), "score": .number(Double(score))] }
    }
}
private struct TrackerReferenceDocument {
    var items = (0..<4).map { TrackerReferenceItem(id: $0, text: "item-\($0)", score: 0) }
    var text = "start"
    var revision = 0
    var label: String?
    let fuzz: Bool
    var key: String { fuzz ? "items" : "values" }
    var json: JSONValue {
        var meta: JSONObject = ["revision": .number(Double(revision))]
        if let label { meta["label"] = .string(label) }
        return .object([key: .array(items.map { $0.json(includeText: fuzz) }), "text": .string(text), "meta": .object(meta)])
    }
    mutating func mutate(_ draft: JSONDraft, choice: Int, value: Int) throws {
        let array = try #require(try draft.child(key))
        let meta = try #require(try draft.child("meta"))
        let item = TrackerReferenceItem(id: value, text: "item-\(value)", score: value % 7)
        // Preserve the upstream draws. The optional sort operation is not in this API.
        let action: Int
        if fuzz { action = choice }
        else { action = [0, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11][choice] }
        switch action {
        case 0:
            text += "-\(value)"; try draft.set("text", .string(text))
        case 1:
            text = String(text.dropFirst(min(2, text.count))) + String(value)
            try draft.set("text", .string(text))
        case 2:
            items.append(item); try array.append(item.json(includeText: fuzz))
        case 3:
            items.insert(item, at: 0); try array.prepend(contentsOf: [item.json(includeText: fuzz)])
        case 4:
            if !items.isEmpty { items.removeFirst(); _ = try array.popFirst() }
        case 5:
            if !items.isEmpty { items.removeLast(); _ = try array.popLast() }
        case 6:
            let index = items.isEmpty ? 0 : value % (items.count + 1)
            let remove = items.isEmpty ? 0 : min(value % 2, items.count - index)
            items.replaceSubrange(index..<(index + remove), with: [item])
            _ = try array.splice(index, deleteCount: remove, insert: [item.json(includeText: fuzz)])
        case 7: items.reverse(); try array.reverse()
        case 8: break
        case 9:
            if !items.isEmpty {
                let index = value % items.count
                items[index].score = value
                let row = try #require(try array.child(index))
                try row.set("score", .number(Double(value)))
            }
        case 10:
            revision += 1
            label = fuzz ? "revision-\(value)" : "r-\(value)"
            try meta.set("revision", .number(Double(revision)))
            try meta.set("label", .string(try #require(label)))
        case 11: label = nil; try meta.remove("label")
        case 12:
            if items.count > 1 {
                items[1] = items[0]
                try array.set(1, items[0].json(includeText: fuzz))
            }
        default:
            for index in 0..<min(2, items.count) {
                items[index] = item
                try array.set(index, item.json(includeText: fuzz))
            }
        }
    }
}

@Suite struct TrackerRandomizedTests {
    @Test func matchesPolicyReplayAndAdoptionForMultiOperationTransactions() throws {
        for seed in 1...40 {
            var rng = TrackerRandom(seed: UInt32(seed))
            var expected = TrackerReferenceDocument(fuzz: false)
            let tracker = try Delta.track(expected.json)
            for transaction in 0..<25 {
                let base = tracker.value
                let change = tracker.beginChange()
                let root = try change.state
                for operation in 0..<5 {
                    let choice = Int(rng.next() * 11)
                    let value = seed * 10_000 + transaction * 10 + operation
                    try expected.mutate(root, choice: choice, value: value)
                }
                let prepared = try change.prepare()
                #expect(tracker.value == base, "seed \(seed), transaction \(transaction)")
                #expect(prepared.value == expected.json, "seed \(seed), transaction \(transaction)")
                #expect(try Delta.applyImmutable(base, prepared.ops) == prepared.value)
                try tracker.adopt(prepared)
                #expect(tracker.value == expected.json)
            }
        }
    }

    @Test func convergesAcrossRandomizedPreparedRevisions() throws {
        for seed in 1...100 {
            var rng = TrackerRandom(seed: UInt32(seed))
            var expected = TrackerReferenceDocument(fuzz: true)
            let tracker = try Delta.track(expected.json)
            var replica: JSONValue? = tracker.value
            for step in 0..<100 {
                let choice = Int(rng.next() * 14)
                let value = seed * 1_000 + step
                let base = tracker.value
                let change = tracker.beginChange()
                try expected.mutate(change.state, choice: choice, value: value)
                let prepared = try change.prepare()
                #expect(tracker.value == base, "seed \(seed), step \(step)")
                #expect(prepared.base == base)
                replica = try Delta.applyImmutable(replica, prepared.ops)
                #expect(replica == prepared.value, "seed \(seed), step \(step)")
                try tracker.adopt(prepared)
                #expect(tracker.value == expected.json, "seed \(seed), step \(step), choice \(choice)")
                #expect(replica == expected.json)
            }
        }
    }
}
