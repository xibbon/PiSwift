import CryptoKit
import Foundation
import Testing
import PiSwiftChord

private enum DeltaFixtureText: Decodable {
    case text(String)
    case digest(sha256: String, length: Int)

    private struct Digest: Decodable { let sha256: String; let length: Int }
    init(from decoder: any Decoder) throws {
        let value = try decoder.singleValueContainer()
        if let text = try? value.decode(String.self) { self = .text(text) }
        else {
            let digest = try value.decode(Digest.self)
            self = .digest(sha256: digest.sha256, length: digest.length)
        }
    }
}

private func checkDeltaFixtureValue(_ value: JSONValue?, expected: DeltaFixtureText?, name: String) throws {
    guard let expected else {
        #expect(value == nil, "case: \(name)")
        return
    }
    let text = try #require(try value?.jsonText())
    switch expected {
    case .text(let expectedText):
        #expect(value == (try JSONValue(jsonText: expectedText)), "case: \(name)")
        #expect(Array(text.utf8) == Array(expectedText.utf8), "case: \(name)")
    case .digest(let sha256, let length):
        let bytes = Array(text.utf8)
        let digest = SHA256.hash(data: Data(bytes)).map { String(format: "%02x", $0) }.joined()
        #expect(bytes.count == length, "case: \(name)")
        #expect(digest == sha256, "case: \(name)")
    }
}

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
        let resultText: DeltaFixtureText?
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
                try checkDeltaFixtureValue(value, expected: entry.resultText, name: entry.name)
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
                try checkDeltaFixtureValue(value, expected: entry.resultText, name: entry.name)
                #expect(initial == (try entry.initialText.map { try JSONValue(jsonText: $0) }), "case: \(entry.name), input must stay unchanged")
            } catch let error as DeltaError {
                #expect(fixtureErrorKind(error) == entry.errorKind, "case: \(entry.name), error: \(error)")
                #expect(error.description == entry.errorText, "case: \(entry.name)")
                #expect(initial == (try entry.initialText.map { try JSONValue(jsonText: $0) }), "case: \(entry.name), input must stay unchanged after an error")
            }
        }
    }
}
