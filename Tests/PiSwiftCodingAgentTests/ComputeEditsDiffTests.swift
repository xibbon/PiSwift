import Foundation
import Testing
import PiSwiftAI
import PiSwiftCodingAgent

@Suite struct ComputeEditsDiffTests {
    private func withFile(
        _ content: String?,
        body: (String, String) async throws -> Void
    ) async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("compute-edits-diff-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = "sample.txt"
        let file = directory.appendingPathComponent(path)
        let original = content.map { Data($0.utf8) }
        if let original {
            try original.write(to: file)
        }
        try await body(directory.path, path)
        if let original {
            #expect(try Data(contentsOf: file) == original)
        } else {
            #expect(!FileManager.default.fileExists(atPath: file.path))
        }
    }

    private func success(_ outcome: EditDiffOutcome) -> EditDiffResult? {
        guard case .success(let result) = outcome else { return nil }
        return result
    }

    private func message(_ outcome: EditDiffOutcome) -> String? {
        guard case .error(let error) = outcome else { return nil }
        return error.error
    }

    private func toolError(path: String, edits: [EditReplacement], cwd: String) async -> String? {
        do {
            _ = try await createEditTool(cwd: cwd).execute("preview-error", [
                "path": AnyCodable(path),
                "edits": AnyCodable(edits.map { ["oldText": $0.oldText, "newText": $0.newText] }),
            ], nil, nil)
            Issue.record("Expected an edit tool error.")
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    @Test func twoEditsProduceOneDiff() async throws {
        let original = "header\nfirst\nmiddle\nsecond\ntail\n"
        try await withFile(original) { cwd, path in
            let result = try #require(success(computeEditsDiff(path: path, edits: [
                EditReplacement(oldText: "first", newText: "FIRST"),
                EditReplacement(oldText: "second", newText: "SECOND"),
            ], cwd: cwd)))
            let expected = generateDiffString(original, "header\nFIRST\nmiddle\nSECOND\ntail\n")
            #expect(result.diff == expected.diff)
            #expect(result.diff.contains("first"))
            #expect(result.diff.contains("FIRST"))
            #expect(result.diff.contains("second"))
            #expect(result.diff.contains("SECOND"))
            #expect(result.firstChangedLine == 2)
        }
    }

    @Test func missingFile() async throws {
        try await withFile(nil) { cwd, path in
            let edits = [EditReplacement(oldText: "old", newText: "new")]
            let error = message(computeEditsDiff(path: path, edits: edits, cwd: cwd))
            #expect(error == "File not found: \(path)")
            let reportedError = await toolError(path: path, edits: edits, cwd: cwd)
            #expect(error == reportedError)
        }
    }

    @Test(arguments: [false, true]) func absentTextMatchesTool(multiple: Bool) async throws {
        try await withFile("first\nsecond\n") { cwd, path in
            var edits = [EditReplacement(oldText: "absent", newText: "new")]
            if multiple { edits.insert(EditReplacement(oldText: "first", newText: "FIRST"), at: 0) }
            let error = message(computeEditsDiff(path: path, edits: edits, cwd: cwd))
            let expected = multiple
                ? "Could not find edits[1] in \(path). The oldText must match exactly including all whitespace and newlines."
                : "Could not find the exact text in \(path). The old text must match exactly including all whitespace and newlines."
            #expect(error == expected)
            let reportedError = await toolError(path: path, edits: edits, cwd: cwd)
            #expect(error == reportedError)
        }
    }

    @Test(arguments: [false, true]) func ambiguousTextMatchesTool(multiple: Bool) async throws {
        try await withFile("first\nrepeat\nrepeat\n") { cwd, path in
            var edits = [EditReplacement(oldText: "repeat", newText: "new")]
            if multiple { edits.insert(EditReplacement(oldText: "first", newText: "FIRST"), at: 0) }
            let error = message(computeEditsDiff(path: path, edits: edits, cwd: cwd))
            let expected = multiple
                ? "Found 2 occurrences of edits[1] in \(path). Each oldText must be unique. Please provide more context to make it unique."
                : "Found 2 occurrences of the text in \(path). The text must be unique. Please provide more context to make it unique."
            #expect(error == expected)
            let reportedError = await toolError(path: path, edits: edits, cwd: cwd)
            #expect(error == reportedError)
        }
    }

    @Test(arguments: [false, true]) func emptyTextMatchesTool(multiple: Bool) async throws {
        try await withFile("first\n") { cwd, path in
            var edits = [EditReplacement(oldText: "", newText: "new")]
            if multiple { edits.insert(EditReplacement(oldText: "first", newText: "FIRST"), at: 0) }
            let error = message(computeEditsDiff(path: path, edits: edits, cwd: cwd))
            #expect(error == (multiple
                ? "edits[1].oldText must not be empty in \(path)."
                : "oldText must not be empty in \(path)."))
            let reportedError = await toolError(path: path, edits: edits, cwd: cwd)
            #expect(error == reportedError)
        }
    }

    @Test func overlapMatchesTool() async throws {
        try await withFile("first second\n") { cwd, path in
            let edits = [
                EditReplacement(oldText: "first second", newText: "new"),
                EditReplacement(oldText: "second", newText: "SECOND"),
            ]
            let error = message(computeEditsDiff(path: path, edits: edits, cwd: cwd))
            #expect(error == "edits[0] and edits[1] overlap in \(path). Merge them into one edit or target disjoint regions.")
            let reportedError = await toolError(path: path, edits: edits, cwd: cwd)
            #expect(error == reportedError)
        }
    }

    @Test(arguments: [false, true]) func identicalReplacement(multiple: Bool) async throws {
        try await withFile("first\nsecond\n") { cwd, path in
            var edits = [EditReplacement(oldText: "first", newText: "first")]
            if multiple { edits.append(EditReplacement(oldText: "second", newText: "second")) }
            let error = message(computeEditsDiff(path: path, edits: edits, cwd: cwd))
            #expect(error == ApplyEditsError.noChange(path: path, totalEdits: edits.count).localizedDescription)
            if !multiple {
                #expect(message(computeEditDiff(path: path, oldText: "first", newText: "first", cwd: cwd)) == error)
            }
        }
    }

    @Test func crlfAndBomKeepPreviousSingleEditResult() async throws {
        try await withFile("\u{FEFF}header\r\nold line\r\ntail\r\n") { cwd, path in
            let oldText = "old line\r\n"
            let newText = "new line\r\n"
            let single = try #require(success(computeEditDiff(path: path, oldText: oldText, newText: newText, cwd: cwd)))
            let batch = try #require(success(computeEditsDiff(path: path, edits: [
                EditReplacement(oldText: oldText, newText: newText),
            ], cwd: cwd)))
            // This result was captured from the previous single-edit function.
            #expect(single.diff == " 1 tail\n-2 old line\n+2 new line\n 3 header")
            #expect(single.firstChangedLine == 2)
            #expect(batch.diff == single.diff)
            #expect(batch.firstChangedLine == single.firstChangedLine)
            #expect(!batch.diff.contains("\r"))
            #expect(!batch.diff.contains("\u{FEFF}"))
        }
    }

    @Test func singleEditKeepsEmptyTextError() async throws {
        try await withFile("first\n") { cwd, path in
            let error = message(computeEditDiff(path: path, oldText: "", newText: "new", cwd: cwd))
            #expect(error == "Could not find the exact text in \(path). The old text must match exactly including all whitespace and newlines.")
        }
    }

    @Test func emptyBatchMakesNoChanges() async throws {
        try await withFile("first\n") { cwd, path in
            #expect(message(computeEditsDiff(path: path, edits: [], cwd: cwd))
                == ApplyEditsError.noChange(path: path, totalEdits: 0).localizedDescription)
        }
    }

    @Test func fuzzyAndExactEditsUseToolBaseContent() async throws {
        let original = "header\nsmart “quote”\nplain\ntail\n"
        try await withFile(original) { cwd, path in
            let edits = [
                EditReplacement(oldText: "smart \"quote\"", newText: "new quote"),
                EditReplacement(oldText: "plain", newText: "new plain"),
            ]
            let applied = try applyEditsToNormalizedContent(original, edits: edits, path: path)
            let expected = generateDiffString(applied.baseContent, applied.newContent)
            let result = try #require(success(computeEditsDiff(path: path, edits: edits, cwd: cwd)))
            #expect(result.diff == expected.diff)
            #expect(result.firstChangedLine == expected.firstChangedLine)
        }
    }
}
