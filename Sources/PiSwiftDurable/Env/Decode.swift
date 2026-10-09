/// A UTF-8 decoder that keeps incomplete characters between chunks and keeps byte-order marks.
public struct RangeDecoder: Sendable {
    private var codePoint: UInt32 = 0
    private var needed = 0
    private var seen = 0
    private var lower: UInt8 = 0x80
    private var upper: UInt8 = 0xbf

    /// Creates a decoder with no pending bytes.
    public init() {}

    /// Decodes a chunk. Pass no bytes to finish the stream.
    public mutating func decode(_ bytes: [UInt8]? = nil) -> String {
        var text = String.UnicodeScalarView()
        guard let bytes else {
            if needed != 0 { text.append("\u{fffd}") }
            reset()
            return String(text)
        }
        var index = 0
        while index < bytes.count {
            let byte = bytes[index]
            if needed == 0 {
                switch byte {
                case 0...0x7f:
                    text.append(Unicode.Scalar(UInt32(byte))!)
                case 0xc2...0xdf:
                    needed = 1; codePoint = UInt32(byte & 0x1f)
                case 0xe0...0xef:
                    needed = 2; codePoint = UInt32(byte & 0x0f)
                    if byte == 0xe0 { lower = 0xa0 }
                    if byte == 0xed { upper = 0x9f }
                case 0xf0...0xf4:
                    needed = 3; codePoint = UInt32(byte & 0x07)
                    if byte == 0xf0 { lower = 0x90 }
                    if byte == 0xf4 { upper = 0x8f }
                default:
                    text.append("\u{fffd}")
                }
                index += 1
                continue
            }
            guard byte >= lower && byte <= upper else {
                // The invalid continuation byte must also be processed as a new leading byte.
                reset()
                text.append("\u{fffd}")
                continue
            }
            lower = 0x80; upper = 0xbf
            codePoint = (codePoint << 6) | UInt32(byte & 0x3f)
            seen += 1
            index += 1
            if seen == needed {
                text.append(Unicode.Scalar(codePoint)!)
                reset()
            }
        }
        return String(text)
    }

    private mutating func reset() {
        codePoint = 0; needed = 0; seen = 0; lower = 0x80; upper = 0xbf
    }
}

/// Creates a decoder that keeps a byte-order mark at the start of a byte range.
public func rangeDecoder() -> RangeDecoder { RangeDecoder() }

/// Returns true if the bytes start with a UTF-8 byte-order mark.
public func startsWithBom(_ firstBytes: [UInt8]) -> Bool {
    firstBytes.count >= 3 && firstBytes[0] == 0xef && firstBytes[1] == 0xbb && firstBytes[2] == 0xbf
}

/// Decodes a stream and removes only its leading byte-order mark.
public struct StreamDecoder: Sendable {
    private var decoder = rangeDecoder()
    private var started = false

    /// Creates a decoder with no pending bytes.
    public init() {}

    /// Decodes a chunk. Pass no bytes to finish the stream.
    public mutating func decode(_ bytes: [UInt8]? = nil) -> String {
        let text = decoder.decode(bytes)
        guard !started, !text.isEmpty else { return text }
        started = true
        guard text.unicodeScalars.first == "\u{feff}" else { return text }
        return String(text.unicodeScalars.dropFirst())
    }
}
