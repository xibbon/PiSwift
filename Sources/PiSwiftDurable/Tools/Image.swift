/// A file size and a callback for byte-range reads.
internal struct ByteSource: Sendable {
    internal let size: Int64
    internal let read: @Sendable (Int64, Int) async throws -> [UInt8]
    internal init(size: Int64, read: @escaping @Sendable (Int64, Int) async throws -> [UInt8]) {
        self.size = size; self.read = read
    }
}

private let pngSignature: [UInt8] = [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]

/// Detects supported images from the header and PNG chunk headers. It uses bounded memory.
internal func detectSupportedImageMimeTypeOf(_ source: ByteSource) async throws -> String? {
    let header = try await source.read(0, 32)
    guard header.starts(with: pngSignature) else { return detectSupportedImageMimeType(header) }
    guard isPng(header) else { return nil }
    var block: [UInt8] = []
    var blockStart: Int64 = 0
    var offset: Int64 = 8
    while offset + 8 <= source.size {
        if offset < blockStart || offset + 8 > blockStart + Int64(block.count) {
            blockStart = offset
            block = try await source.read(offset, 64 * 1024)
        }
        let local = Int(offset - blockStart)
        let chunk = Array(block.dropFirst(local).prefix(8))
        if startsWithAscii(chunk, at: 4, "acTL") { return nil }
        if startsWithAscii(chunk, at: 4, "IDAT") { return "image/png" }
        let next = offset + 12 + readUInt32BE(chunk, at: 0)
        if next <= offset || next > source.size { break }
        offset = next
    }
    return "image/png"
}

/// Detects JPEG, PNG, GIF, WebP, and BMP images from their bytes. Animated PNG is excluded.
internal func detectSupportedImageMimeType(_ bytes: [UInt8]) -> String? {
    if bytes.starts(with: [0xff, 0xd8, 0xff]) { return bytes.count > 3 && bytes[3] == 0xf7 ? nil : "image/jpeg" }
    if bytes.starts(with: pngSignature) {
        guard isPng(bytes) else { return nil }
        var offset = 8
        while offset + 8 <= bytes.count {
            if startsWithAscii(bytes, at: offset + 4, "acTL") { return nil }
            if startsWithAscii(bytes, at: offset + 4, "IDAT") { return "image/png" }
            let next = Int64(offset) + 12 + readUInt32BE(bytes, at: offset)
            if next <= offset || next > bytes.count { break }
            offset = Int(next)
        }
        return "image/png"
    }
    if startsWithAscii(bytes, at: 0, "GIF87a") || startsWithAscii(bytes, at: 0, "GIF89a") { return "image/gif" }
    if startsWithAscii(bytes, at: 0, "RIFF") && startsWithAscii(bytes, at: 8, "WEBP") { return "image/webp" }
    if startsWithAscii(bytes, at: 0, "BM") && isBmp(bytes) { return "image/bmp" }
    return nil
}

private func isPng(_ bytes: [UInt8]) -> Bool {
    bytes.count >= 16 && readUInt32BE(bytes, at: 8) == 13 && startsWithAscii(bytes, at: 12, "IHDR")
}
private func isBmp(_ bytes: [UInt8]) -> Bool {
    guard bytes.count >= 26 else { return false }
    let size = readUInt32LE(bytes, at: 2)
    let pixels = readUInt32LE(bytes, at: 10)
    let dib = readUInt32LE(bytes, at: 14)
    guard size == 0 || size >= 26, pixels >= 14 + dib, size == 0 || pixels < size else { return false }
    let planes: Int64
    let bits: Int64
    if dib == 12 {
        planes = readUInt16LE(bytes, at: 22); bits = readUInt16LE(bytes, at: 24)
    } else if dib >= 40 && dib <= 124 && bytes.count >= 30 {
        planes = readUInt16LE(bytes, at: 26); bits = readUInt16LE(bytes, at: 28)
    } else { return false }
    return planes == 1 && [1, 4, 8, 16, 24, 32].contains(bits)
}
private func byte(_ bytes: [UInt8], _ index: Int) -> Int64 { index < bytes.count ? Int64(bytes[index]) : 0 }
private func readUInt16LE(_ bytes: [UInt8], at offset: Int) -> Int64 {
    byte(bytes, offset) + byte(bytes, offset + 1) * 256
}
private func readUInt32BE(_ bytes: [UInt8], at offset: Int) -> Int64 {
    byte(bytes, offset) * 0x1000000 + byte(bytes, offset + 1) * 0x10000 + byte(bytes, offset + 2) * 256 + byte(bytes, offset + 3)
}
private func readUInt32LE(_ bytes: [UInt8], at offset: Int) -> Int64 {
    byte(bytes, offset) + byte(bytes, offset + 1) * 256 + byte(bytes, offset + 2) * 0x10000 + byte(bytes, offset + 3) * 0x1000000
}
private func startsWithAscii(_ bytes: [UInt8], at offset: Int, _ text: String) -> Bool {
    let prefix = Array(text.utf8)
    return offset + prefix.count <= bytes.count && bytes.dropFirst(offset).starts(with: prefix)
}
