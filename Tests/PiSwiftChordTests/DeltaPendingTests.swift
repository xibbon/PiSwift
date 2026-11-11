import Testing
import PiSwiftChord

@Suite struct DeltaPendingTests {
    private func folded(_ batches: [[Delta.Op]]) -> PendingTake {
        let queue = PendingOps()
        for batch in batches { queue.push(batch) }
        return queue.take()
    }

    private func sameResult(_ base: JSONValue, _ batches: [[Delta.Op]]) throws {
        let original = batches.flatMap { $0 }
        let queue = PendingOps()
        for batch in batches { queue.push(batch) }
        guard case .ops(let ops) = queue.take() else { Issue.record("Unexpected overflow"); return }
        #expect(try Delta.applyImmutable(base, original) == Delta.applyImmutable(base, ops))
    }

    @Test func joinsAppendsFoldsIntoStringSetAndKeepsOrder() throws {
        // Upstream: "joins appends, folds appends into a string set, and keeps split surrogates".
        let base: JSONValue = ["s": "", "t": 0]
        let batches: [[Delta.Op]] = [[.set(["s"], "ab")], [.append(["s"], "c"), .set(["t"], 1)], [.append(["s"], "d")]]
        #expect(folded(batches) == .ops([.set(["s"], "abcd"), .set(["t"], 1)]))
        try sameResult(base, batches)
        #expect(folded([[.append(["s"], "😀")], [.set(["t"], 1), .append(["s"], "é")]]) ==
                .ops([.append(["s"], "😀é"), .set(["t"], 1)]))
    }

    @Test func rootReplacementAndStructuralBarriers() throws {
        // Upstream: "r drops everything before it"; "interleaved leaves, a structural op, then the same leaves again".
        let base: JSONValue = ["a": "", "b": "", "list": [0]]
        let batches: [[Delta.Op]] = [
            [.append(["a"], "1"), .append(["b"], "1")],
            [.append(["a"], "2"), .splice(["list"], index: 1, remove: 0, items: [1])],
            [.append(["b"], "2"), .append(["a"], "3")],
        ]
        #expect(folded(batches) == .ops([.append(["a"], "12"), .append(["b"], "1"),
                                        .splice(["list"], index: 1, remove: 0, items: [1]),
                                        .append(["b"], "2"), .append(["a"], "3")]))
        try sameResult(base, batches)
        #expect(folded([[.set(["a"], "x")], [.replace(["a": "y"]), .append(["a"], "z")]]) ==
                .ops([.replace(["a": "y"]), .append(["a"], "z")]))
        #expect(folded([[.set(["a"], "x")], [.set(["b"], "y"), .replace(["a": "z"])]] ) ==
                .ops([.replace(["a": "z"])]))
    }

    @Test func leafPathsDoNotCollideAndArrayEditsBlockFolding() throws {
        // Upstream: "keys of one parent never collide"; "deletes, moves and splices shift what a path names".
        let base: JSONValue = ["a": ["b": "x"], "a.b": "z", "arr": ["a", "b", "c"]]
        let batches: [[Delta.Op]] = [
            [.append(["a", "b"], "1"), .set(["a.b"], "y"), .set(["arr", 2], "C")],
            [.append(["a", "b"], "2"), .delete(["arr", 0]), .set(["arr", 1], "Z")],
        ]
        try sameResult(base, batches)
        guard case .ops(let ops) = folded(batches) else { Issue.record("Unexpected overflow"); return }
        #expect(ops[0] == .append(["a", "b"], "12"))
        #expect(ops.count == 5)
        try sameResult(["o": ["1": "a"], "arr": ["x", "y"]],
                       [[.set(["o", "1"], "b"), .set(["arr", 1], "z")],
                        [.set(["o", "1"], "c"), .set(["arr", 1], "w")]])
        try sameResult(["arr": [1, 2, 3]], [[.set(["arr", 0], 10)], [.move(["arr"], permutation: [2, 1, 0]), .set(["arr", 0], 20)]])
    }

    @Test func trimAndAncestorSetsPreserveUnsafeMerges() throws {
        // Upstream: "t then a, and appends around a trim"; "an ancestor primitive s between leaf ops below it".
        try sameResult(["s": "hello"], [[.trim(["s"], 2)], [.append(["s"], "!")]])
        #expect(folded([[.append(["s"], "AB")], [.trim(["s"], 3), .append(["s"], "C")]]) ==
                .ops([.append(["s"], "AB"), .trim(["s"], 3), .append(["s"], "C")]))
        let base: JSONValue = ["o": ["a": "x", "b": "y"]]
        let batches: [[Delta.Op]] = [[.append(["o", "a"], "1")], [.set(["o", "b"], "q"), .set(["o"], "flat"), .append(["o"], "!")]]
        #expect(folded(batches) == .ops([.append(["o", "a"], "1"), .set(["o", "b"], "q"), .set(["o"], "flat!")]))
        try sameResult(base, batches)
    }

    @Test func arrayLeafSpliceAndLaterSamePathSet() throws {
        // Upstream: "a leaf set in an array element, a splice before it, the same path set again".
        let base: JSONValue = ["arr": [["x": 0], ["x": 0], ["x": 0]]]
        let batches: [[Delta.Op]] = [[.set(["arr", 2, "x"], 1)],
                                     [.splice(["arr"], index: 0, remove: 0, items: [["x": 9]])],
                                     [.set(["arr", 2, "x"], 2)]]
        try sameResult(base, batches)
        #expect(folded(batches) == .ops(batches.flatMap { $0 }))
    }

    @Test func objectSetAtParentAndArraySetAtEnd() throws {
        // Upstream: "an object s at a parent, then leaf sets below it";
        // "an array set at the end appends, and a later set of that index folds into it".
        let base: JSONValue = ["x": ["s": "a"]]
        let objectBatches: [[Delta.Op]] = [[.set(["x"], ["s": "b"])],
                                           [.append(["x", "s"], "c"), .set(["x", "s"], "d")]]
        try sameResult(base, objectBatches)
        #expect(folded(objectBatches) == .ops([.set(["x"], ["s": "b"]), .set(["x", "s"], "d")]))
        let arrayBatches: [[Delta.Op]] = [[.set(["arr", 1], 2)], [.set(["arr", 0], 9)], [.set(["arr", 1], 3)]]
        try sameResult(["arr": [1]], arrayBatches)
        #expect(folded(arrayBatches) == .ops([.set(["arr", 1], 3), .set(["arr", 0], 9)]))
    }

    @Test func rootArrayAndListElementSequencesRemainReplayable() throws {
        // Upstream: "is invisible to a replica: a root array" and
        // "is invisible to a replica: leaf edits of list elements between splices and reorders of the list".
        try sameResult([1, 2, 3], [[.splice([], index: 1, remove: 1, items: [4])],
                                   [.move([], permutation: [2, 0, 1])], [.set([0], 5)]])
        let base: JSONValue = ["list": [["x": "a", "n": 0], ["x": "b", "n": 1]]]
        try sameResult(base, [[.append(["list", 0, "x"], "1")],
                              [.splice(["list"], index: 1, remove: 0, items: [["x": "c", "n": 2]])],
                              [.move(["list"], permutation: [2, 1, 0])],
                              [.set(["list", 0, "n"], 3)]])
    }

    @Test func trackerEditsAnywhereRemainInvisibleToReplica() throws {
        // Upstream: "is invisible to a replica: tracker edits anywhere, appendText, splices and reorders".
        let base: JSONValue = ["text": "", "n": 0, "arr": [0, 1, 2], "nested": ["v": 0]]
        for seed in 0..<200 {
            let tracker = try Delta.track(base)
            let queue = PendingOps()
            var original: [Delta.Op] = []
            var word = UInt32(seed)
            func next() -> Int { word = word &* 1_664_525 &+ 1_013_904_223; return Int(word % 5) }
            for commit in 0..<12 {
                let prepared: Prepared
                if commit == 5 && seed.isMultiple(of: 17) {
                    prepared = try tracker.prepareReplace(base)
                } else {
                    let change = tracker.beginChange()
                    let root = try change.state
                    switch next() {
                    case 0: try root.appendText("text", "😀")
                    case 1: try root.set("n", .number(Double(next())))
                    case 2:
                        let arr = try #require(try root.child("arr"))
                        try arr.reverse()
                    case 3:
                        let arr = try #require(try root.child("arr"))
                        _ = try arr.splice(1, deleteCount: 1, insert: [.number(Double(next()))])
                    default:
                        let nested = try #require(try root.child("nested"))
                        try nested.set("v", .number(Double(next())))
                    }
                    prepared = try change.prepare()
                }
                original += prepared.ops
                queue.push(prepared.ops)
                try tracker.adopt(prepared)
            }
            guard case .ops(let ops) = queue.take() else { Issue.record("Unexpected overflow"); return }
            #expect(try Delta.applyImmutable(base, original) == tracker.value)
            #expect(try Delta.applyImmutable(base, ops) == tracker.value)
        }
    }

    @Test func capCountsAfterFoldingAndSingleBatchKeepsItsSize() {
        // Upstream: "keeps 10000 pending ops and replaces past them"; "counts ops after folding".
        let queue = PendingOps()
        let many = (0..<10_001).map { Delta.Op.set(["k", .index($0)], .number(Double($0))) }
        queue.push(Array(many.prefix(10_000)))
        #expect(queue.size == 10_000)
        #expect(queue.take() == .ops(Array(many.prefix(10_000))))
        queue.push(many)
        #expect(queue.size == 10_001) // One batch is retained whole.
        queue.push([.set(["n"], 1)])
        #expect(queue.size == 1)
        #expect(queue.take() == .replace)
        for _ in 0..<30_000 { queue.push([.append(["text"], "x")]) }
        #expect(queue.size == 1)
        #expect(queue.take() == .ops([.append(["text"], String(repeating: "x", count: 30_000))]))
    }

    @Test func overflowRecoveryTakeAndOwnership() {
        // Upstream: "accumulates nothing once replaced"; "hands over a received batch by identity";
        // "counts pending ops after folding, the replacement once overflowed, and nothing once taken".
        let queue = PendingOps()
        #expect(queue.take() == .ops([]))
        queue.push([])
        #expect(queue.size == 0)
        let first: [Delta.Op] = [.append(["s"], "1")]
        queue.push(first)
        #expect(queue.take() == .ops(first))
        queue.push(first)
        queue.push([.append(["s"], "2")])
        #expect(queue.take() == .ops([.append(["s"], "12")]))
        #expect(first == [.append(["s"], "1")])
        let many = (0..<10_001).map { Delta.Op.set(["k", .index($0)], .number(Double($0))) }
        queue.push([.set(["n"], 1)])
        queue.push(many)
        queue.push([.set(["n"], 2)])
        #expect(queue.take() == .replace)
        #expect(queue.size == 0)
        queue.push([.set(["n"], 1)])
        queue.push(many)
        queue.push([.replace(["s": "new"])])
        #expect(queue.take() == .ops([.replace(["s": "new"])]))
    }

    @Test func twentyThousandSeededSequencesHaveSameAppliedValue() throws {
        // Upstream: four "is invisible to a replica" randomized families, adapted to Swift op values.
        let base: JSONValue = ["text": "", "n": 0, "arr": [1, 2, 3], "o": ["x": 0], "temp": 0]
        for seed in 0..<20_000 {
            var x = UInt32(truncatingIfNeeded: seed)
            func next() -> Int { x = x &* 1_664_525 &+ 1_013_904_223; return Int(x % 6) }
            var batches: [[Delta.Op]] = []
            for _ in 0..<(2 + next()) {
                let op: Delta.Op
                switch next() {
                case 0: op = .append(["text"], "a")
                case 1: op = .set(["n"], .number(Double(next())))
                case 2: op = .set(["o", "x"], .number(Double(next())))
                case 3: op = .splice(["arr"], index: 1, remove: 1, items: [.number(Double(next()))])
                case 4: op = .move(["arr"], permutation: [2, 0, 1])
                default: op = .set(["temp"], .number(Double(next())))
                }
                batches.append([op])
            }
            try sameResult(base, batches)
        }
    }
}
