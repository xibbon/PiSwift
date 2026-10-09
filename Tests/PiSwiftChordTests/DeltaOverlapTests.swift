import Foundation
import Testing
import PiSwiftChord

private struct DeltaFixtures: Decodable {
    struct OverlapCase: Decodable {
        let name: String
        let a: String
        let b: String
        let scan: Int
        let probe: Int
        let maxCandidates: Int
        let expected: Int
    }
    struct ApplyCase: Decodable {
        let name: String
        let initialText: String?
        let ops: [JSONValue]
        let resultText: String?
        let errorKind: String?
        let errorText: String?
    }
    let overlap: [OverlapCase]
    let apply: [ApplyCase]
}

private func deltaFixtures() throws -> DeltaFixtures {
    let url = try #require(Bundle.module.url(forResource: "overlap-fixtures", withExtension: "json", subdirectory: "Fixtures"))
    // The chord parser keeps property order and distinct Unicode scalar keys.
    return try JSONValue(jsonData: Data(contentsOf: url)).decode(DeltaFixtures.self)
}

private func fixtureErrorKind(_ error: DeltaError) -> String {
    switch error {
    case .unresolvablePath: "PathError"
    case .unsafeSegment: "UnsafePathError"
    case .invalidOperation: "TypeError"
    }
}

@Suite struct DeltaOverlapTests {
    // Upstream delta.test.ts: "finds bounded overlaps".
    @Test func findsBoundedOverlaps() {
        #expect(Delta.overlap("abcdefgh", "defghxyz", scan: 65_536) == 5)
        #expect(Delta.overlap("abcdef", "defghi", scan: 0) == 0)
        #expect(Delta.overlap(String(repeating: "a", count: 100) + "b", String(repeating: "a", count: 50) + "bX", scan: 65_536) == 0)
        #expect(Delta.overlap("head😀e\u{301}", "😀e\u{301}tail", scan: 65_536) == 4)
    }

    @Test func allOverlapFixturesMatchNode() throws {
        let entries = try deltaFixtures().overlap
        #expect(entries.count >= 2_000)
        for entry in entries {
            let result = Delta.overlap(entry.a, entry.b, scan: entry.scan, probe: entry.probe, maxCandidates: entry.maxCandidates)
            #expect(result == entry.expected, "case: \(entry.name), scan: \(entry.scan), probe: \(entry.probe), candidates: \(entry.maxCandidates)")
        }
    }

    @Test func allMutableApplyFixturesMatchNode() throws {
        for entry in try deltaFixtures().apply {
            do {
                let ops = try entry.ops.map { try Delta.Op(json: $0) }
                var value = try entry.initialText.map { try JSONValue(jsonText: $0) }
                try Delta.apply(ops, to: &value)
                #expect(entry.errorKind == nil, "case: \(entry.name), expected error: \(entry.errorText ?? "none")")
                let expected = try entry.resultText.map { try JSONValue(jsonText: $0) }
                #expect(value == expected, "case: \(entry.name)")
                // JSON text also checks object key order and scalar identity.
                let text = try value?.jsonText()
                #expect(text.map { Array($0.utf8) } == entry.resultText.map { Array($0.utf8) }, "case: \(entry.name)")
            } catch let error as DeltaError {
                #expect(fixtureErrorKind(error) == entry.errorKind, "case: \(entry.name), error: \(error)")
                #expect(error.description == entry.errorText, "case: \(entry.name)")
            }
        }
    }

    @Test func allImmutableApplyFixturesMatchNode() throws {
        for entry in try deltaFixtures().apply {
            let initial = try entry.initialText.map { try JSONValue(jsonText: $0) }
            do {
                let ops = try entry.ops.map { try Delta.Op(json: $0) }
                let value = try Delta.applyImmutable(initial, ops)
                #expect(entry.errorKind == nil, "case: \(entry.name), expected error: \(entry.errorText ?? "none")")
                let expected = try entry.resultText.map { try JSONValue(jsonText: $0) }
                #expect(value == expected, "case: \(entry.name)")
                let text = try value?.jsonText()
                #expect(text.map { Array($0.utf8) } == entry.resultText.map { Array($0.utf8) }, "case: \(entry.name)")
                #expect(initial == (try entry.initialText.map { try JSONValue(jsonText: $0) }), "case: \(entry.name), input must stay unchanged")
            } catch let error as DeltaError {
                #expect(fixtureErrorKind(error) == entry.errorKind, "case: \(entry.name), error: \(error)")
                #expect(error.description == entry.errorText, "case: \(entry.name)")
                #expect(initial == (try entry.initialText.map { try JSONValue(jsonText: $0) }), "case: \(entry.name), input must stay unchanged after an error")
            }
        }
    }
}
