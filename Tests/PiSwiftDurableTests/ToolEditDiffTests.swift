import Foundation
import Testing
@testable import PiSwiftDurable

private struct DurableEditFixtures: Decodable {
    struct ReplacementCase: Decodable {
        var name: String
        var content: String
        var replacements: [Edit]
        var result: AppliedEditsResult?
        var error: String?
    }
    struct DiffCase: Decodable {
        var name: String
        var path: String
        var oldContent: String
        var newContent: String
        var contextLines: Int
        var diff: String
        var firstChangedLine: Int?
        var patch: String
    }
    struct NormalizationCase: Decodable {
        var content: String
        var bom: String
        var text: String
        var ending: String
        var normalized: String
        var fuzzy: String
        var restored: String
    }
    var tag: String
    var diffVersion: String
    var edits: [ReplacementCase]
    var diffs: [DiffCase]
    var normalization: [NormalizationCase]
}

private func editFixtures() throws -> DurableEditFixtures {
    let url = try #require(Bundle.module.url(forResource: "edit-fixtures", withExtension: "json", subdirectory: "Fixtures"))
    return try JSONDecoder().decode(DurableEditFixtures.self, from: Data(contentsOf: url))
}

@Suite("Durable edit diff v1.1.0")
struct ToolEditDiffTests {
    @Test func upstreamReplacementFixtures() throws {
        let fixture = try editFixtures()
        #expect(fixture.tag == "v1.1.0")
        #expect(fixture.edits.count == 34)
        for row in fixture.edits {
            do {
                let result = try applyEditsToNormalizedContent(normalizeToLF(row.content), edits: row.replacements, path: "fixture.txt")
                let expected = try #require(row.result, Comment(rawValue: row.name))
                #expect(Array(result.baseContent.utf8) == Array(expected.baseContent.utf8), Comment(rawValue: row.name))
                #expect(Array(result.newContent.utf8) == Array(expected.newContent.utf8), Comment(rawValue: row.name))
                #expect(row.error == nil, Comment(rawValue: row.name))
            } catch {
                #expect(String(describing: error) == row.error, Comment(rawValue: row.name))
            }
        }
    }

    @Test func upstreamDiffAndPatchFixturesMatchEveryByte() throws {
        let fixture = try editFixtures()
        #expect(fixture.diffVersion == "8.0.3")
        #expect(fixture.diffs.count == 327)
        for row in fixture.diffs {
            let result = generateDiffString(row.oldContent, newContent: row.newContent, contextLines: row.contextLines)
            #expect(Array(result.diff.utf8) == Array(row.diff.utf8), Comment(rawValue: row.name))
            #expect(result.firstChangedLine == row.firstChangedLine, Comment(rawValue: row.name))
            let patch = generateUnifiedPatch(row.path, oldContent: row.oldContent, newContent: row.newContent, contextLines: row.contextLines)
            #expect(Array(patch.utf8) == Array(row.patch.utf8), Comment(rawValue: row.name))
        }
    }

    @Test func upstreamNormalizationFixtures() throws {
        let fixture = try editFixtures()
        #expect(fixture.normalization.count == 7)
        for row in fixture.normalization {
            let stripped = stripBom(row.content)
            #expect(Array(stripped.bom.utf8) == Array(row.bom.utf8))
            #expect(Array(stripped.text.utf8) == Array(row.text.utf8))
            #expect(detectLineEnding(stripped.text) == row.ending)
            #expect(Array(normalizeToLF(stripped.text).utf8) == Array(row.normalized.utf8))
            #expect(Array(normalizeForFuzzyMatch(stripped.text).utf8) == Array(row.fuzzy.utf8))
            #expect(Array(restoreLineEndings(normalizeToLF(stripped.text), ending: row.ending).utf8) == Array(row.restored.utf8))
        }
    }

    @Test func offsetsUseUTF16AndExactMatchesUseCodeUnits() throws {
        let match = fuzzyFindText("😀e\u{301} — tail", oldText: "tail")
        #expect(match.index == 7)
        #expect(match.matchLength == 4)
        #expect(!match.usedFuzzyMatch)
        let fuzzy = fuzzyFindText("😀e\u{301} — tail", oldText: "😀é - tail")
        #expect(fuzzy.found)
        #expect(fuzzy.usedFuzzyMatch)
        #expect(fuzzy.matchLength == 10)
        let result = try applyEditsToNormalizedContent("é", edits: [.init(oldText: "é", newText: "e\u{301}")], path: "f")
        #expect(Array(result.newContent.utf8) == [0x65, 0xCC, 0x81])
    }

    @Test func preservationUsesRangesWithRepeatedNormalizedLines() throws {
        let content = "same “quote”  \ntarget—one\nsame \"quote\"\n"
        let result = try applyEditsToNormalizedContent(content, edits: [.init(oldText: "target-one", newText: "target+one")], path: "f")
        #expect(Array(result.newContent.utf8) == Array("same “quote”  \ntarget+one\nsame \"quote\"\n".utf8))
        #expect(throws: DurableToolError.self) {
            try applyReplacementsPreservingUnchangedLines("one\n", baseContent: "one\ntwo\n", replacements: [])
        }
        #expect(throws: DurableToolError.self) {
            try applyReplacementsPreservingUnchangedLines("one\n", baseContent: "one\n", replacements: [.init(matchIndex: 10, matchLength: 1, newText: "x")])
        }
    }
}
