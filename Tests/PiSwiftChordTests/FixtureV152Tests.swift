import CryptoKit
import Foundation
import Testing
import PiSwiftChord

@Suite struct FixtureV152Tests {
    private func load(_ name: String) throws -> JSONValue {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
        return try JSONValue(jsonData: Data(contentsOf: url))
    }

    @Test func v152PayloadsMatchFrozenV140Payloads() throws {
        // The tagged code regenerates these manifests; frozen inputs and tests stay intact.
        for name in ["json-v152-fixtures", "delta-v152-fixtures", "tracker-v152-fixtures"] {
            let manifest = try load(name)
            #expect(manifest["upstream"] == "pi-mono v1.5.2")
            #expect(manifest["sameAsV140"] == true)
            #expect(manifest["payloadSha256"]?.stringValue?.count == 64)
        }
    }

    @Test func pendingCorpusRecordsTwoThousandTaggedSequences() throws {
        let manifest = try load("pending-v152-fixtures")
        #expect(manifest["upstream"] == "pi-mono v1.5.2")
        #expect(manifest["seeds"] == 2_000)
        #expect(manifest["operations"]?.intValue ?? 0 >= 20_000)
        #expect(manifest["splitPairs"]?.intValue ?? 0 > 0)
        #expect(manifest["replacements"] == 2)
        #expect(manifest["sha256"]?.stringValue?.count == 64)
    }

    @Test func pendingScalarCorpusMatchesTaggedFoldedOpsAndValues() throws {
        // The first 1,000 tagged seeds contain well-formed UTF-16 only. The
        // other 1,000 include lone halves, which JSONValue rejects by design.
        let manifest = try load("pending-v152-fixtures")
        let base: JSONValue = ["text": "", "n": 0, "arr": [0, 1, 2], "nested": ["v": 0], "flag": true, "map": [:]]
        var hash = SHA256()
        for seed in 0..<1_000 {
            var word = UInt32(seed)
            func next() -> UInt32 { word = word &* 1_664_525 &+ 1_013_904_223; return word }
            let count = 4 + Int(next() % 9)
            var batches: [[Delta.Op]] = []
            for _ in 0..<count {
                let number = next() % 8
                let digit = Int(next() % 10)
                let batch: [Delta.Op]
                switch number {
                case 0: batch = [.append(["text"], ["a", "😀", "é"][digit % 3])]
                case 1: batch = [.set(["n"], .number(Double(digit)))]
                case 2: batch = [.append(["text"], "😀")]
                case 3: batch = [.append(["text"], "x"), .trim(["text"], 1)]
                case 4: batch = [.splice(["arr"], index: 1, remove: 1, items: [.number(Double(digit))])]
                case 5: batch = [.move(["arr"], permutation: [2, 0, 1])]
                case 6: batch = [.set(["nested"], ["v": .number(Double(digit))]),
                                 .set(["nested", "v"], .number(Double(digit + 1)))]
                default: batch = [.set(["flag"], true), .delete(["flag"]), .set(["flag"], false)]
                }
                batches.append(batch)
            }
            if seed % 19 == 0 { batches.insert([.replace(base)], at: 2) }
            let queue = PendingOps()
            for batch in batches { queue.push(batch) }
            let taken = queue.take()
            let original = try #require(try Delta.applyImmutable(base, batches.flatMap { $0 }))
            let folded: JSONValue
            let takenJSON: JSONValue
            switch taken {
            case .replace:
                folded = original
                takenJSON = ["kind": "replace"]
            case .ops(let ops):
                folded = try #require(try Delta.applyImmutable(base, ops))
                takenJSON = ["kind": "ops", "ops": .array(ops.map(\.json))]
            }
            #expect(original == folded)
            let record: JSONValue = [.number(Double(seed)), takenJSON, original, folded]
            hash.update(data: Data((try record.jsonText() + "\n").utf8))
        }
        let digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
        #expect(digest == manifest["scalarSha256"]?.stringValue)
    }
}
