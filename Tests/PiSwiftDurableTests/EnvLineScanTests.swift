import Testing
@testable import PiSwiftDurable

private struct EnvRandom {
    var state: UInt32

    mutating func next() -> Double {
        state &+= 0x6d2b79f5
        var value = state
        value = (value ^ (value >> 15)) &* (value | 1)
        value ^= value &+ ((value ^ (value >> 7)) &* (value | 61))
        return Double(value ^ (value >> 14)) / 4_294_967_296
    }

    mutating func file() -> [UInt8] {
        let pieces: [[UInt8]] = [
            [0x0a], [0x0a], [0x61], [0x62, 0x63], [0xef, 0xbb, 0xbf],
            [0xc3, 0xa9], [0xe2, 0x82, 0xac], [0xf0, 0x9f, 0x98, 0x80],
            [0xe2, 0x82], [0xff], [0x80], [0xf0, 0x9f], [0x0d, 0x0a],
        ]
        var bytes: [UInt8] = []
        let count = Int(next() * 60)
        for _ in 0..<count { bytes.append(contentsOf: pieces[Int(next() * Double(pieces.count))]) }
        return bytes
    }
}

/// Independent whole-input decoding, with the WHATWG leading-BOM rule.
private func envWholeText(_ bytes: [UInt8], dropBom: Bool = true) -> String {
    let text = String(decoding: bytes, as: UTF8.self)
    if dropBom && bytes.starts(with: [0xef, 0xbb, 0xbf]) {
        return String(text.unicodeScalars.dropFirst())
    }
    return text
}

struct EnvLineScanTests {
    @Test("keeps a U+FEFF that does not start the stream")
    func keepsInteriorBom() {
        let bytes: [UInt8] = [0xe2, 0x82, 0xef, 0xbb, 0xbf, 0x61]
        var decoder = StreamDecoder()
        var text = ""
        for byte in bytes { text += decoder.decode([byte]) }
        text += decoder.decode()
        #expect(Array(text.utf8) == Array("\u{fffd}\u{feff}a".utf8))
        #expect(Array(text.utf8) == Array(envWholeText(bytes).utf8))
    }

    @Test("decodes any chunking like decoding the whole stream")
    func decodesAnyChunking() {
        for seed in 1...5000 {
            var random = EnvRandom(state: UInt32(seed))
            let bytes = random.file()
            var decoder = StreamDecoder()
            var text = ""
            var offset = 0
            while offset < bytes.count {
                let count = 1 + Int(random.next() * 7)
                text += decoder.decode(Array(bytes[offset..<min(offset + count, bytes.count)]))
                offset += count
            }
            text += decoder.decode()
            #expect(Array(text.utf8) == Array(envWholeText(bytes).utf8), "seed \(seed)")
        }

        // The random upstream inputs do not include all restricted leading-byte bounds.
        let malformed: [[UInt8]] = [
            [0xe0, 0x80, 0x80], [0xed, 0xa0, 0x80], [0xf0, 0x80, 0x80, 0x80],
            [0xf4, 0x90, 0x80, 0x80], [0xc0, 0xaf], [0xf5, 0x80, 0x80, 0x80],
            [0xef, 0xbb], [0xf0, 0x9f, 0x98], [0xef, 0xbb, 0xbf, 0xef, 0xbb, 0xbf],
        ]
        for bytes in malformed {
            var decoder = StreamDecoder()
            var text = ""
            for byte in bytes { text += decoder.decode([byte]) }
            text += decoder.decode()
            #expect(Array(text.utf8) == Array(envWholeText(bytes).utf8))
        }
    }

    @Test("agrees with decoding and splitting the whole file")
    func agreesWithWholeFile() throws {
        for seed in 1...5000 {
            var random = EnvRandom(state: UInt32(seed))
            let file = random.file()
            let lines = envWholeText(file).unicodeScalars.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            let startLine = Int(random.next() * Double(lines.count + 2))
            let endLine: Int? = random.next() < 0.3 ? nil : startLine + 1 + Int(random.next() * Double(lines.count + 1))
            var scanner = try LineScanner(startLine: startLine, endLine: endLine)
            var offset = 0
            while offset < file.count {
                let count = 1 + Int(random.next() * 7)
                scanner.push(Array(file[offset..<min(offset + count, file.count)]))
                offset += count
            }
            let scan = scanner.finish()
            let selected = Array(lines.dropFirst(startLine).prefix(max(0, (endLine ?? lines.count) - startLine)))
            let selectedText = selected.joined(separator: "\n")
            #expect(scan.newlines == lines.count - 1, "seed \(seed)")
            let decoded = envWholeText(Array(file[Int(scan.start)..<Int(scan.end)]), dropBom: scan.start == 0)
            #expect(Array(decoded.utf8) == Array(selectedText.utf8), "seed \(seed)")
            #expect(scan.selectedBytes == Int64(selectedText.utf8.count), "seed \(seed)")
            if startLine < lines.count {
                let first = envWholeText(Array(file[Int(scan.start)..<Int(scan.firstLineEnd)]), dropBom: scan.start == 0)
                #expect(Array(first.utf8) == Array(lines[startLine].utf8), "seed \(seed)")
                #expect(scan.firstLineBytes == Int64(lines[startLine].utf8.count), "seed \(seed)")
                let lastLine = min(endLine ?? lines.count, lines.count) - 1
                let lastStart = Int(scan.lastLineStart)
                let lastEnd = lastLine + 1 < lines.count ? (file[lastStart...].firstIndex(of: 0x0a) ?? file.count) : file.count
                let last = envWholeText(Array(file[lastStart..<lastEnd]), dropBom: lastStart == 0)
                #expect(Array(last.utf8) == Array(lines[lastLine].utf8), "seed \(seed)")
            } else {
                #expect(scan.start == Int64(file.count), "seed \(seed)")
                #expect(scan.end == Int64(file.count), "seed \(seed)")
                #expect(scan.selectedBytes == 0, "seed \(seed)")
            }
        }
    }

    @Test("rejects empty or invalid ranges")
    func rejectsInvalidRanges() {
        #expect(throws: FileError.self) { try LineScanner(startLine: 2, endLine: 2) }
        #expect(throws: FileError.self) { try LineScanner(startLine: -1) }
        // Swift integer arguments cannot represent the fractional upstream input 1.5.
        #expect(throws: FileError.self) { try LineScanner(startLine: 9_007_199_254_740_992) }
    }
}
