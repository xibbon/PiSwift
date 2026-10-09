import Testing
import PiSwiftDurable

private struct OutputRandom {
    var state: UInt32
    mutating func next() -> Double {
        state = state &+ 0x6d2b79f5
        var t = (state ^ (state >> 15)) &* (state | 1)
        t ^= t &+ ((t ^ (t >> 7)) &* (t | 61))
        return Double(t ^ (t >> 14)) / 4294967296
    }
    mutating func integer(_ maximum: Int) -> Int { Int(next() * Double(maximum)) }
    mutating func chunk() -> String {
        let alphabet = ["a", "b", "z", " ", "\n", "\n", "\n", "\r\n", "\t", "é", "€", "😀", "\u{fffd}", "\u{1}", "\u{1b}"]
        let count = integer(12)
        return (0..<count).map { _ in alphabet[integer(alphabet.count)] }.joined()
    }
    mutating func limits() -> OutputLimits { .init(maxBytes: 1 + integer(40), maxLines: 1 + integer(5), retain: .tail) }
}
private func measureOutput(_ text: String) -> ShellOutputSkip {
    .init(bytes: text.utf8.count, newlines: text.utf8.filter { $0 == 10 }.count, endsWithNewline: text.hasSuffix("\n"))
}
@Suite("Harness output skips") struct HarnessOutputSkipTests {
    @Test("keeps the same tail whenever progress snapshots happen") func sampledTail() throws {
        for seed in 1...3000 {
            var random = OutputRandom(state: UInt32(seed)); let limits = random.limits()
            let plain = OutputBuffer(limits); let sampled = OutputBuffer(limits)
            let count = random.integer(30)
            for _ in 0..<count {
                let chunk = random.chunk(); try plain.push(chunk); try sampled.push(chunk)
                if random.next() < 0.4 { _ = sampled.snapshot() }
            }
            #expect(sampled.snapshot() == plain.snapshot(), "seed \(seed)")
        }
    }
    @Test("matches the full stream for every legal skip pattern") func legalSkips() throws {
        for seed in 1...3000 {
            var random = OutputRandom(state: UInt32(seed)); let limits = random.limits()
            let full = OutputBuffer(limits); let skipping = OutputBuffer(limits)
            var pending = ""
            func flush() throws {
                if pending.isEmpty { return }
                let scalars = Array(pending.unicodeScalars)
                let cuts = (1..<scalars.count).filter { cut in
                    let suffix = String(String.UnicodeScalarView(scalars[cut...]))
                    let size = measureOutput(suffix)
                    return size.bytes > limits.maxBytes || size.newlines > limits.maxLines
                }
                if !cuts.isEmpty && random.next() < 0.7 {
                    let cut = cuts[random.integer(cuts.count)]
                    let prefix = String(String.UnicodeScalarView(scalars[..<cut]))
                    let suffix = String(String.UnicodeScalarView(scalars[cut...]))
                    try skipping.push(suffix, skipped: measureOutput(prefix))
                } else { try skipping.push(pending) }
                pending = ""
                if random.next() < 0.5 { _ = skipping.snapshot() }
                #expect(skipping.snapshot() == full.snapshot(), "seed \(seed)")
            }
            let count = random.integer(40)
            for _ in 0..<count {
                let chunk = random.chunk(); try full.push(chunk)
                if random.next() < 0.3 { _ = full.snapshot() }
                pending += chunk
                if random.next() < 0.3 { try flush() }
            }
            try flush(); full.end(); skipping.end()
            #expect(skipping.snapshot() == full.snapshot(), "seed \(seed)")
        }
    }
    @Test("counts skipped bytes, lines and the final newline exactly") func skippedTotals() throws {
        let limits = OutputLimits(maxBytes: 1000, maxLines: 2, retain: .tail)
        let full = OutputBuffer(limits); let skipping = OutputBuffer(limits)
        let omitted = "one\ntwo\nthr"; let kept = "ee\nfour\nfive\nsix"
        try full.push(omitted + kept); try skipping.push(kept, skipped: measureOutput(omitted))
        #expect(skipping.snapshot() == full.snapshot())
        #expect(skipping.snapshot() == .init(text: "five\nsix", droppedBytes: 19, droppedLines: 4))
    }
    @Test("refuses skips for head retention") func refusedHeadSkip() {
        let buffer = OutputBuffer(.init(maxBytes: 10, maxLines: 2, retain: .head))
        #expect(throws: OutputBufferError.self) {
            try buffer.push("x\ny\nz\n", skipped: .init(bytes: 3, newlines: 1, endsWithNewline: true))
        }
    }
}
