import Synchronization
import Testing
import PiSwiftChord
import PiSwiftDurable

@Suite("Durable output compatibility") struct ChordOutputCompatibilityTests {
    @Test func sharedProgressActor() async {
        let writes = Mutex(0)
        let progress: PiSwiftDurable.Progress = PiSwiftChord.Progress(
            write: { writes.withLock { $0 += 1 }; return 0 }, onError: { _ in }, minIntervalMs: 0)
        await markOutput(progress)
        _ = await progress.stop()
        #expect(writes.withLock { $0 } == 1)
    }

    @Test func sharedOutputTypes() throws {
        let limits: PiSwiftDurable.OutputLimits = PiSwiftChord.OutputLimits(maxBytes: 10, maxLines: 1, retain: .tail)
        let buffer: PiSwiftDurable.OutputBuffer = PiSwiftChord.OutputBuffer(limits)
        let skip: ShellOutputSkip = PiSwiftChord.OutputSkip(bytes: 6, newlines: 2, endsWithNewline: true)
        try buffer.push("a\nb\n", skipped: skip)
        let snapshot: PiSwiftDurable.BoundedOutput = buffer.snapshot()
        #expect(snapshot.text == "b\n")
        #expect(snapshot.droppedBytes == 8)
        #expect(snapshot.droppedLines == 3)
        #expect(PiSwiftDurable.boundOutput("a\nb\n", limits: limits).text == PiSwiftChord.boundOutput("a\nb\n", limits: limits).text)
        #expect(PiSwiftDurable.sanitizeOutput("a\0b") == PiSwiftChord.sanitizeOutput("a\0b"))
    }
}

private func markOutput(_ progress: isolated PiSwiftDurable.Progress) {
    progress.mark()
}
