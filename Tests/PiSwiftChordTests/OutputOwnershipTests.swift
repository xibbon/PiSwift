import Foundation
import Synchronization
import Testing
@testable import PiSwiftChord

@Suite("Chord output ownership") struct OutputOwnershipTests {
    @Test func boundsAndUTF8Helpers() {
        let text = "a\nééé\n"
        let head = boundOutput(text, limits: .init(maxBytes: 6, maxLines: 2, retain: .head))
        #expect(head.text == "a\n")
        #expect(head.bytes == 2)
        #expect(head.droppedBytes == 7)
        #expect(head.droppedLines == 1)
        let tail = boundOutput(text, limits: .init(maxBytes: 5, maxLines: 2, retain: .tail))
        #expect(tail.text == "éé\n")
        #expect(utf8ByteLength("é😀") == 6)
        let bytes = Array("x😀z".utf8)
        #expect(characterEnd(bytes, at: 3) == 1)
        #expect(characterEnd(bytes, at: bytes.count) == bytes.count)
        #expect(sanitizeOutput("a\0\tb\n\u{1b}\u{fff9}c") == "a\tb\nc")
    }

    @Test("removes whole ANSI escape sequences, not only their ESC bytes")
    func removesWholeANSIEscapeSequences() throws {
        #expect(try NSRegularExpression(pattern: OutputSanitizerPattern.source).pattern
                == OutputSanitizerPattern.expression.pattern)
        #expect(sanitizeOutput("\u{1b}[31mERROR\u{1b}[0m\n") == "ERROR\n")
        #expect(sanitizeOutput("\u{1b}[1;38;5;208mx\u{1b}[?25l\u{1b}[2K\u{1b}(By\u{1b}7z") == "xyz")
        #expect(sanitizeOutput("\u{1b}]8;;https://pi.dev\u{7}link\u{1b}]8;;\u{1b}\\ \u{1b}]0;title\u{7}ok") == "link ok")
        let output = OutputBuffer(.init(maxBytes: 1024, maxLines: 100, retain: .tail))
        try output.push("\u{1b}[3")
        try output.push("1mERROR\u{1b}[0")
        try output.push("m\n")
        #expect(output.snapshot().text == "ERROR\n")
    }

    @Test func snapshotsShowIncompleteEscapeTextUntilItCompletes() throws {
        let output = OutputBuffer(.init(maxBytes: 1024, maxLines: 100, retain: .tail))
        try output.push("\u{1b}[3")
        #expect(output.snapshot().text == "3")
        try output.push("1mERROR\u{1b}[0")
        #expect(output.snapshot().text == "ERROR0")
        try output.push("m\n")
        #expect(output.snapshot().text == "ERROR\n")
    }

    @Test func boundedSnapshotsCanCutThroughEscapeSequences() throws {
        let head = OutputBuffer(.init(maxBytes: 3, maxLines: 100, retain: .head))
        try head.push("\u{1b}[31mRED")
        #expect(head.snapshot().text == "3")
        try head.push("more")
        #expect(head.snapshot().text == "3")

        let tail = OutputBuffer(.init(maxBytes: 3, maxLines: 100, retain: .tail))
        try tail.push("prefix\u{1b}[31mZ")
        #expect(tail.snapshot().text == "1mZ")
        try tail.push("!")
        #expect(tail.snapshot().text == "mZ!")
    }

    @Test func decodedByteChunksAndSkips() throws {
        let limits = OutputLimits(maxBytes: 100, maxLines: 2, retain: .tail)
        let buffer = OutputBuffer(limits)
        try buffer.push([0xef, 0xbb])
        try buffer.push(Data([0xbf, 0x61, 0x0a]))
        try buffer.push([0xe2])
        try buffer.push("b\nc\nd", skipped: OutputSkip(bytes: 8, newlines: 3, endsWithNewline: true))
        buffer.end()
        let result = buffer.snapshot()
        #expect(result.text == "c\nd")
        #expect(result.droppedBytes == 15)
        #expect(result.droppedLines == 5)
        let head = OutputBuffer(.init(maxBytes: 10, maxLines: 2, retain: .head))
        #expect(throws: OutputBufferError.skippedOutputRequiresTailRetention) {
            try head.push("x", skipped: .init(bytes: 4, newlines: 1, endsWithNewline: true))
        }
    }

    @Test func snapshotsPreserveTheNextWindow() throws {
        for retain in [OutputRetention.head, .tail] {
            let limits = OutputLimits(maxBytes: 19, maxLines: 3, retain: retain)
            let buffer = OutputBuffer(limits)
            var text = ""
            for index in 0..<80 {
                let chunk = "é\(index)\n"
                text += chunk
                try buffer.push(chunk)
                let expected = boundOutput(text, limits: limits)
                let actual = buffer.snapshot()
                #expect(actual.text == expected.text)
                #expect(actual.droppedBytes == expected.droppedBytes)
                #expect(actual.droppedLines == expected.droppedLines)
            }
        }
    }

    @Test func progressWritesAndReportsFailures() async throws {
        let commits = Mutex(0)
        let progress = Progress(write: { commits.withLock { $0 += 1 }; return 12 }, onError: { _ in }, minIntervalMs: 0)
        try await progress.markAndWait()
        #expect(commits.withLock { $0 } == 1)
        #expect(await progress.stop().isEmpty)
        let errors = Mutex(0)
        let failed = Progress(write: { throw OutputOwnershipFailure.write }, onError: { _ in errors.withLock { $0 += 1 } }, minIntervalMs: 0)
        await #expect(throws: OutputOwnershipFailure.write) { try await failed.markAndWait() }
        _ = await failed.stop()
        #expect(errors.withLock { $0 } == 1)
        #expect(progressBytesPerSecond == 100 * 1024)
    }
}

private enum OutputOwnershipFailure: Error { case write }
