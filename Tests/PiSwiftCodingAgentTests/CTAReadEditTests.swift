import Foundation
import Testing
import PiSwiftAI
import PiSwiftAgent
@testable import PiSwiftCodingAgent

private actor CTAReadChunks {
    let bytes: Data
    let size: Int
    let signal: CancellationToken?
    let abortAt: Int?
    var offset = 0
    var pulls = 0

    init(_ bytes: Data, size: Int, signal: CancellationToken? = nil, abortAt: Int? = nil) {
        self.bytes = bytes
        self.size = size
        self.signal = signal
        self.abortAt = abortAt
    }

    func next() -> Data? {
        guard offset < bytes.count else { return nil }
        pulls += 1
        if pulls == abortAt { signal?.cancel() }
        let end = min(offset + size, bytes.count)
        defer { offset = end }
        return bytes.subdata(in: offset..<end)
    }
}

private actor CTAFileReadProbe {
    let handle: FileHandle
    var totalBytes = 0
    var maximumChunk = 0

    init(_ file: URL) throws { handle = try FileHandle(forReadingFrom: file) }
    deinit { try? handle.close() }

    func next() throws -> Data? {
        guard let data = try handle.read(upToCount: 64 * 1024), !data.isEmpty else { return nil }
        totalBytes += data.count
        maximumChunk = max(maximumChunk, data.count)
        return data
    }

    func counts() -> (Int, Int) { (totalBytes, maximumChunk) }
}

private actor CTAReadSnapshotChunks {
    var firstChunk: Data?
    let remaining: LocalReadChunks
    init(firstChunk: Data, remaining: LocalReadChunks) { self.firstChunk = firstChunk; self.remaining = remaining }
    func next() async throws -> Data? {
        if let firstChunk { self.firstChunk = nil; return firstChunk }
        return try await remaining.next()
    }
}

private enum CTAReadEditFailure: Error, Equatable { case unexpectedReadFile; case diffFailed }

private func ctaReadText(_ result: AgentToolResult) -> String {
    result.content.compactMap { if case .text(let block) = $0 { block.text } else { nil } }.joined()
}

private func ctaReadOperations(_ bytes: Data, chunkSize: Int?) -> ReadOperations {
    let createStream: (@Sendable (String, CancellationToken?) throws -> AsyncThrowingStream<Data, Error>)?
    if let size = chunkSize {
        createStream = { _, signal in
            let chunks = CTAReadChunks(bytes, size: size, signal: signal)
            return AsyncThrowingStream(unfolding: { await chunks.next() })
        }
    } else { createStream = nil }
    return ReadOperations(readFile: { _ in bytes }, access: { _ in }, createReadStream: createStream)
}

private func ctaReadOutcome(_ bytes: Data, chunkSize: Int?, offset: Double?, limit: Double?) async -> String {
    let tool = createReadTool(cwd: "/tmp", options: ReadToolOptions(operations: ctaReadOperations(bytes, chunkSize: chunkSize)))
    var params = ["path": AnyCodable("f.txt")]
    if let offset { params["offset"] = AnyCodable(offset) }
    if let limit { params["limit"] = AnyCodable(limit) }
    do {
        let result = try await tool.execute("read", params, nil, nil)
        // JSON object order is not stable in Swift dictionaries. Compare all field values.
        let fields: [String: Any] = ["text": ctaReadText(result), "details": result.details?.value ?? NSNull()]
        let data = try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys, .fragmentsAllowed])
        return String(decoding: data, as: UTF8.self)
    } catch { return "error: \(error.localizedDescription)" }
}

private func ctaTemporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("cta-read-edit-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

@Suite struct CTAReadEditTests {
    // 3a7bb6f48 test/read-streaming.test.ts:149-163.
    @Test("gives the same output as the whole-file algorithm")
    func streamingMatrix() async throws {
        let fiftyKB = Array(repeating: String(repeating: "y", count: 99), count: 512).joined(separator: "\n") + "y"
        let manyLines = (0..<2001).map { "line \($0)" }.joined(separator: "\n")
        let cases = [
            "", "alpha\nbeta\ngamma", "alpha\nbeta\n", "alpha\r\nbeta\r\n\r\ngamma\r\n",
            "\u{FEFF}é€😀\nñ\u{10348}字\n😀😀😀", manyLines, manyLines + "\n\nmore",
            String(repeating: "é", count: DEFAULT_MAX_BYTES / 2 + 1) + "\nsecond",
            "a\nb\n" + String(repeating: "z", count: 60 * 1024) + "\nc",
            fiftyKB + "\n", fiftyKB + "\n\nmore",
            (0..<700).map { "\($0) " + String(repeating: "€😀", count: 13) }.joined(separator: "\n"),
        ]
        for text in cases {
            let bytes = Data(text.utf8)
            let total = Double(text.components(separatedBy: "\n").count)
            for offset in [nil, 2, 3, total, total + 1] as [Double?] {
                for limit in [nil, 0, 1, total] as [Double?] {
                    let expected = await ctaReadOutcome(bytes, chunkSize: nil, offset: offset, limit: limit)
                    for size in [1, 4096] {
                        let actual = await ctaReadOutcome(bytes, chunkSize: size, offset: offset, limit: limit)
                        #expect(actual == expected, "offset=\(String(describing: offset)), limit=\(String(describing: limit)), chunk=\(size), bytes=\(bytes.count)")
                    }
                }
            }
        }
    }

    // 3a7bb6f48 test/read-streaming.test.ts:172-182.
    @Test("decodes multi-byte characters split across chunks and invalid UTF-8 like Buffer.toString")
    func streamingUTF8() async {
        var bytes = Data("aé€😀\n😀b\u{10348}\n".utf8)
        bytes.append(contentsOf: [0x61, 0xc3, 0x0a, 0xe2, 0x82, 0x0a, 0xff, 0xfe, 0x80, 0xf0, 0x9f, 0x98, 0x0a, 0xed, 0xa0, 0x80])
        let expected = await ctaReadOutcome(bytes, chunkSize: nil, offset: nil, limit: nil)
        for size in [1, 2, 3] {
            let actual = await ctaReadOutcome(bytes, chunkSize: size, offset: nil, limit: nil)
            #expect(actual == expected)
        }
    }

    // 3a7bb6f48 test/read-streaming.test.ts:184-203.
    @Test("uses readFile for operations without createReadStream and for fractional or negative ranges")
    func unusualRanges() async throws {
        let bytes = Data("one\ntwo\nthree\nfour".utf8)
        let tool = createReadTool(cwd: "/tmp", options: ReadToolOptions(operations: ReadOperations(
            readFile: { _ in bytes }, access: { _ in },
            createReadStream: { _, _ in throw CTAReadEditFailure.unexpectedReadFile }
        )))
        let cases: [(Double?, Double, String)] = [
            (2.5, 1, "two\n\n[1.5 more lines in file. Use offset=3.5 to continue.]"),
            (nil, -1, "one\ntwo\nthree\n\n[5 more lines in file. Use offset=0 to continue.]"),
            (1, 1.5, "one\n\n[2.5 more lines in file. Use offset=2.5 to continue.]"),
        ]
        for (offset, limit, expected) in cases {
            var params = ["path": AnyCodable("f.txt"), "limit": AnyCodable(limit)]
            if let offset { params["offset"] = AnyCodable(offset) }
            let result = try await tool.execute("unusual", params, nil, nil)
            #expect(ctaReadText(result) == expected)
        }
    }

    // 3a7bb6f48 test/read-streaming.test.ts:205-222.
    @Test("reads local files through the default stream")
    func localFiles() async throws {
        let directory = try ctaTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let text = (0..<3000).map { "\($0) " + String(repeating: "w", count: $0 % 40) }.joined(separator: "\n")
        try Data(text.utf8).write(to: directory.appendingPathComponent("local.txt"))
        let result = try await createReadTool(cwd: directory.path).execute("local", [
            "path": AnyCodable("local.txt"), "offset": AnyCodable(1500), "limit": AnyCodable(10),
        ], nil, nil)
        let expected = text.components(separatedBy: "\n")[1499..<1509].joined(separator: "\n")
            + "\n\n[1491 more lines in file. Use offset=1510 to continue.]"
        #expect(ctaReadText(result) == expected)
        await #expect(throws: (any Error).self) {
            try await createReadTool(cwd: directory.path).execute("directory", ["path": AnyCodable(directory.path)], nil, nil)
        }
    }

    // 3a7bb6f48 test/read-streaming.test.ts:224-238.
    @Test("reads a local file up to its size when opened, like fs.readFile")
    func localFileSnapshot() async throws {
        let directory = try ctaTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("growing.txt")
        try Data(("head\n" + String(repeating: "x", count: 200_000)).utf8).write(to: file)
        let chunks = try LocalReadChunks(path: file.path, signal: nil)
        let firstChunk = try #require(await chunks.next())
        let writer = try FileHandle(forWritingTo: file)
        try writer.seekToEnd()
        try writer.write(contentsOf: Data("\nadded".utf8))
        try writer.close()
        let streamState = CTAReadSnapshotChunks(firstChunk: firstChunk, remaining: chunks)
        let operations = ReadOperations(readFile: { _ in throw CTAReadEditFailure.unexpectedReadFile }, access: { _ in },
            createReadStream: { _, _ in AsyncThrowingStream(unfolding: { try await streamState.next() }) })
        let result = try await createReadTool(cwd: directory.path, options: ReadToolOptions(operations: operations))
            .execute("snapshot", ["path": AnyCodable("growing.txt"), "limit": AnyCodable(1)], nil, nil)
        #expect(ctaReadText(result) == "head\n\n[1 more lines in file. Use offset=2 to continue.]")
    }

    // 3a7bb6f48 test/read-streaming.test.ts:240-262. A sparse file and injected reader prove bounded pulls.
    @Test("reads a 200 MB line with bounded storage")
    func sparse200MBLine() async throws {
        let directory = try ctaTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("big.log")
        #expect(FileManager.default.createFile(atPath: file.path, contents: nil))
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: 200 * 1024 * 1024)
        try handle.close()
        let probe = try CTAFileReadProbe(file)
        let operations = ReadOperations(
            readFile: { _ in throw CTAReadEditFailure.unexpectedReadFile },
            access: { _ in },
            createReadStream: { _, _ in AsyncThrowingStream(unfolding: { try await probe.next() }) }
        )
        let result = try await createReadTool(cwd: directory.path, options: ReadToolOptions(operations: operations))
            .execute("large", ["path": AnyCodable("big.log"), "offset": AnyCodable(1), "limit": AnyCodable(1)], nil, nil)
        #expect(ctaReadText(result) == "[Line 1 is 200.0MB, exceeds 50.0KB limit. Use bash: sed -n '1p' big.log | head -c 51200]")
        let truncation = try #require((result.details?.value as? [String: Any])?["truncation"] as? [String: Any])
        #expect(truncation["totalBytes"] as? Int == 200 * 1024 * 1024)
        #expect(truncation["firstLineExceedsLimit"] as? Bool == true)
        let (totalBytes, maximumChunk) = await probe.counts()
        #expect(totalBytes == 200 * 1024 * 1024)
        #expect(maximumChunk <= 64 * 1024)
    }

    // 3a7bb6f48 test/read-streaming.test.ts:264-291.
    @Test("stops consuming the stream when aborted")
    func abortStopsConsumption() async throws {
        let signal = CancellationToken()
        let chunks = CTAReadChunks(Data(String(repeating: "line\n", count: 100).utf8), size: 5, signal: signal, abortAt: 3)
        let operations = ReadOperations(readFile: { _ in throw CTAReadEditFailure.unexpectedReadFile }, access: { _ in },
            createReadStream: { _, receivedSignal in
                #expect(receivedSignal === signal)
                return AsyncThrowingStream(unfolding: { await chunks.next() })
            })
        let tool = createReadTool(cwd: "/tmp", options: ReadToolOptions(operations: operations))
        do {
            _ = try await tool.execute("abort", ["path": AnyCodable("file")], signal, nil)
            Issue.record("The read must stop when the token is cancelled.")
        } catch { #expect(error.localizedDescription == "Operation aborted") }
        #expect(await chunks.pulls == 3)
    }

    // 9e870f6f0 test/truncate-surrogates.test.ts:12-46.
    @Test("truncateLine does not cut an emoji in half at the limit")
    func truncateLineAtEmoji() {
        let result = truncateLine(String(repeating: "a", count: 499) + "😀tail", maxChars: 500)
        #expect(result.wasTruncated)
        #expect(result.text == String(repeating: "a", count: 499) + "... [truncated]")
        #expect(truncateLine(String(repeating: "a", count: 498) + "😀tail", maxChars: 500).text
            == String(repeating: "a", count: 498) + "😀... [truncated]")
    }

    @Test("sliceHead and sliceTail never split a pair")
    func safeUTF16Slices() {
        let text = "😀x😀"
        for units in 0...(text.utf16.count + 1) {
            let head = sliceHead(text, units)
            let tail = sliceTail(text, units)
            #expect(text.hasPrefix(head))
            #expect(text.hasSuffix(tail))
            #expect(head.utf16.count >= min(units, text.utf16.count) - 1)
            #expect(tail.utf16.count >= min(units, text.utf16.count) - 1)
            #expect(!head.contains("\u{FFFD}"))
            #expect(!tail.contains("\u{FFFD}"))
        }
        #expect(sliceHead("abcdef", 3) == "abc")
        #expect(sliceTail("abcdef", 3) == "def")
        #expect(sliceHead("abc", 10) == "abc")
        #expect(sliceTail("abc", 0) == "")
        // Slice by UTF-16 units, including cuts within a composed grapheme.
        #expect(sliceHead("e\u{301}x", 1) == "e")
    }

    @Test("counts empty files and trailing line feeds as upstream truncateHead does")
    func truncationLineCounts() {
        #expect(truncateHead("").totalLines == 0)
        #expect(truncateHead("a\n").totalLines == 1)
        #expect(truncateHead("a\r\nb\r\n").totalLines == 2)
        #expect(truncateTail("a\nb\n", options: TruncationOptions(maxLines: 1)).content == "b")
    }

    // d448c51e2 test/tools.test.ts:1723-1830; compare the exact written bytes.
    @Test("keeps mixed line endings, BOM, lone CR, fuzzy lines, and splice seams")
    func lineEndings() async throws {
        let cases: [(String, [EditReplacement], String)] = [
            ("first\r\nsecond\r\nthird", [.init(oldText: "second\nthird", newText: "2a\r\n2b\nthird!")], "first\r\n2a\r\n2b\r\nthird!"),
            ("first\nsecond\nthird", [.init(oldText: "second\nthird", newText: "2a\r\n2b\nthird!")], "first\n2a\n2b\nthird!"),
            ("a\nb\r\nX = 1\r\n", [.init(oldText: "X = 1", newText: "X = 2")], "a\nb\r\nX = 2\r\n"),
            ("a\r\nb\nc", [.init(oldText: "c", newText: "C")], "a\r\nb\nC"),
            ("a\rb\nX = 1\n", [.init(oldText: "X = 1", newText: "X = 2")], "a\rb\nX = 2\n"),
            ("lf1\nlf2\ncr1\r\ncr2\r\n", [.init(oldText: "lf1\n", newText: "A\nB\n"), .init(oldText: "cr1\n", newText: "C\nD\n")], "A\nB\nlf2\nC\r\nD\r\ncr2\r\n"),
            ("a\r\nfoo   \r\nb\n", [.init(oldText: "foo\n", newText: "FOO\n")], "a\r\nFOO\r\nb\n"),
            ("a\rb\nc", [.init(oldText: "b", newText: "\nB")], "a\r\n\nB\nc"),
            ("a\rb\nc", [.init(oldText: "b", newText: "")], "a\r\n\nc"),
            ("a\rb\rc", [.init(oldText: "b", newText: "B\nC")], "a\rB\rC\rc"),
            ("\u{FEFF}a\r\nb\nc", [.init(oldText: "b", newText: "B")], "\u{FEFF}a\r\nB\nc"),
        ]
        let directory = try ctaTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("f.txt")
        for (index, entry) in cases.enumerated() {
            let (original, edits, expected) = entry
            try Data(original.utf8).write(to: file)
            let result = try await createEditTool(cwd: directory.path).execute("edit", [
                "path": AnyCodable("f.txt"), "edits": AnyCodable(edits.map { ["oldText": $0.oldText, "newText": $0.newText] }),
            ], nil, nil)
            #expect(try Data(contentsOf: file) == Data(expected.utf8), "line-ending vector \(index): \(String(reflecting: original))")
            let patch = try #require((result.details?.value as? [String: Any])?["patch"] as? String)
            let base = normalizeToLF(splitBom(original).text)
            #expect(try ctaApplyPatch(base, patch: patch) == normalizeToLF(splitBom(expected).text))
        }
        let seam = applyReplacementsToOriginal("a\rb\nc", replacements: [.init(matchIndex: 2, matchLength: 1, newText: "\r")])
        #expect(normalizeToLF(seam) == "a\n\n\nc")
    }

    // d448c51e2 test/edit-tool-diff-before-write.test.ts:16-29.
    @Test("should compute the diff before writing, so a diff failure leaves the file unchanged")
    func diffBeforeWrite() async throws {
        let directory = try ctaTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("f.txt")
        let original = Data("a\nb\n".utf8)
        try original.write(to: file)
        let tool = createEditTool(cwd: directory.path, generateDiff: { _, _, _, _ in throw CTAReadEditFailure.diffFailed })
        await #expect(throws: CTAReadEditFailure.diffFailed) {
            try await tool.execute("failure", ["path": AnyCodable("f.txt"), "oldText": AnyCodable("b"), "newText": AnyCodable("B")], nil, nil)
        }
        #expect(try Data(contentsOf: file) == original)
    }

    // d448c51e2 test/edit-diff-window.test.ts:55-84. The fixture uses the pinned TypeScript source.
    @Test("matches the whole-file diff and patch when lines are distinct")
    func upstreamDiffVectors() throws {
        let url = try #require(Bundle.module.url(forResource: "cta-edit-vectors", withExtension: "json", subdirectory: "fixtures"))
        let vectors = try JSONDecoder().decode([CTAEditVector].self, from: Data(contentsOf: url))
        #expect(vectors.count == 40)
        for vector in vectors {
            let edits = vector.edits.map { EditReplacement(oldText: $0.oldText, newText: $0.newText) }
            let applied = try applyEditsToNormalizedContent(normalizeToLF(vector.original), edits: edits, path: "f.txt")
            #expect(applied.baseContent == vector.baseContent, "\(vector.name)")
            #expect(applied.newContent == vector.newContent, "\(vector.name)")
            #expect(applyReplacementsToOriginal(vector.original, replacements: applied.replacements) == vector.written, "\(vector.name)")
            let result = generateEditDiff(path: "f.txt", baseContent: applied.baseContent, newContent: applied.newContent, replacements: applied.replacements)
            #expect(result.diff == vector.diff, "\(vector.name)")
            #expect(result.patch == vector.patch, "\(vector.name)")
            #expect(result.firstChangedLine == vector.firstChangedLine, "\(vector.name)")
            #expect(try ctaApplyPatch(applied.baseContent, patch: result.patch) == applied.newContent, "\(vector.name)")
        }
    }

    // d448c51e2 test/edit-diff-window.test.ts:55-77.
    @Test("random change windows match the whole-file diff and produce applicable patches")
    func randomChangeWindows() throws {
        for distinct in [true, false] {
            var random = CTAEditRandom(state: distinct ? 1 : 2)
            for _ in 0..<2000 {
                let count = random.next(400)
                let lines = (0..<count).map { index in distinct ? "line \(index)" : ["a", "b", "", "}"][random.next(4)] }
                let content = lines.joined(separator: "\n") + (random.next(2) == 0 ? "\n" : "")
                var replacements: [TextReplacement] = []
                var position = 0
                for edit in 0..<(1 + random.next(4)) where position < content.utf16.count {
                    let index = position + random.next(min(content.utf16.count - position, 300))
                    let length = 1 + random.next(min(content.utf16.count - index, 120))
                    let newLines = (0..<random.next(4)).map { "new \(edit) \($0)" }
                    let newText = random.next(3) == 0 ? "" : newLines.joined(separator: "\n") + (random.next(2) == 0 ? "\n" : "")
                    replacements.append(.init(matchIndex: index, matchLength: length, newText: newText))
                    position = index + length
                }
                var changed = content
                for replacement in replacements.reversed() {
                    changed = (changed as NSString).replacingCharacters(
                        in: NSRange(location: replacement.matchIndex, length: replacement.matchLength), with: replacement.newText)
                }
                guard content != changed else { continue }
                let result = generateEditDiff(path: "f.txt", baseContent: content, newContent: changed, replacements: replacements)
                #expect(try ctaApplyPatch(content, patch: result.patch) == changed)
                if distinct {
                    let whole = generateDiffString(content, changed)
                    #expect(result.diff == whole.diff)
                    #expect(result.patch == generateUnifiedPatch(path: "f.txt", oldContent: content, newContent: changed))
                    #expect(result.firstChangedLine == whole.firstChangedLine)
                }
            }
        }
    }

    // d448c51e2 test/tools.test.ts:1832-1868.
    @Test("should write content that normalizes to the diffed content for random mixed line endings")
    func randomMixedLineEndings() throws {
        var random = CTAEditRandom(state: 1)
        let endings = ["\n", "\r\n", "\r", ""]
        for _ in 0..<3000 {
            var original = ""
            for _ in 0..<(random.next(12) + 1) {
                original += "w\(random.next(100))" + (random.next(5) == 0 ? "  " : "") + endings[random.next(4)]
            }
            let normalized = normalizeToLF(original)
            let start = random.next(normalized.utf16.count)
            let length = min(1 + random.next(12), normalized.utf16.count - start)
            let oldText = (normalized as NSString).substring(with: NSRange(location: start, length: length))
            let newText = ["", "\n", "X\n", "\nY", "\r", "Z"][random.next(6)]
            guard let applied = try? applyEditsToNormalizedContent(normalized,
                edits: [.init(oldText: oldText, newText: newText)], path: "f.txt") else { continue }
            #expect(normalizeToLF(applyReplacementsToOriginal(original, replacements: applied.replacements)) == applied.newContent)
        }
    }

    // d448c51e2 test/edit-diff-window.test.ts:80-106.
    @Test("handles a replacement of many lines")
    func manyReplacementLines() throws {
        let replacement = String(repeating: "x\n", count: 150_000)
        let result = generateEditDiff(path: "f.txt", baseContent: "a\nb\n", newContent: replacement + "b\n",
            replacements: [.init(matchIndex: 0, matchLength: 2, newText: replacement)])
        #expect(try ctaApplyPatch("a\nb\n", patch: result.patch) == replacement + "b\n")
    }

    @Test("diffs a small change in a 20 MB file")
    func largeFileDiffWindow() {
        let half = String(repeating: String(repeating: "x", count: 99) + "\n", count: 100_000)
        let result = generateEditDiff(path: "big.txt", baseContent: half + "TARGET = 1\n" + half,
            newContent: half + "TARGET = 2\n" + half,
            replacements: [.init(matchIndex: half.utf16.count, matchLength: 10, newText: "TARGET = 2")])
        let changes = result.diff.components(separatedBy: "\n").filter { $0.hasPrefix("+") || $0.hasPrefix("-") }.joined(separator: "\n")
        #expect(changes == "-100001 TARGET = 1\n+100001 TARGET = 2")
    }
}

private struct CTAEditRandom {
    var state: UInt32
    mutating func next(_ maximum: Int) -> Int {
        guard maximum > 0 else { return 0 }
        state = state &* 1_664_525 &+ 1_013_904_223
        return Int(Double(state) / 4_294_967_296 * Double(maximum))
    }
}

private struct CTAEditVector: Decodable {
    struct Edit: Decodable { var oldText: String; var newText: String }
    var name: String
    var original: String
    var edits: [Edit]
    var baseContent: String
    var newContent: String
    var written: String
    var diff: String
    var patch: String
    var firstChangedLine: Int?
}

/// Apply unified patch hunks in the tests. This checks the public patch format independently of the diff code.
private func ctaApplyPatch(_ original: String, patch: String) throws -> String {
    var oldLines = original.components(separatedBy: "\n")
    for index in oldLines.indices where index + 1 < oldLines.count { oldLines[index] += "\n" }
    if oldLines.last == "" { oldLines.removeLast() }
    let lines = patch.components(separatedBy: "\n")
    var output = ""
    var cursor = 0
    var index = 2
    while index < lines.count {
        let header = lines[index]
        guard header.hasPrefix("@@ ") else { index += 1; continue }
        let fields = header.components(separatedBy: " ")
        let oldRange = fields[1].dropFirst().components(separatedBy: ",")
        let oldStart = try #require(Int(oldRange[0]))
        let oldCount = oldRange.count > 1 ? (Int(oldRange[1]) ?? 1) : 1
        let target = oldStart - (oldCount == 0 ? 0 : 1)
        #expect(target >= cursor)
        if target > cursor { output += oldLines[cursor..<target].joined(); cursor = target }
        index += 1
        while index < lines.count && !lines[index].hasPrefix("@@ ") && !lines[index].isEmpty {
            let line = lines[index]
            let prefix = line.first
            var text = String(line.dropFirst()) + "\n"
            if index + 1 < lines.count && lines[index + 1] == "\\ No newline at end of file" {
                text.removeLast()
                index += 1
            }
            if prefix == " " || prefix == "-" {
                #expect(cursor < oldLines.count)
                guard cursor < oldLines.count else { throw CTAReadEditFailure.diffFailed }
                #expect(oldLines[cursor] == text)
                cursor += 1
            }
            if prefix == " " || prefix == "+" { output += text }
            index += 1
        }
    }
    return output + oldLines[cursor...].joined()
}
