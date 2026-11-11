import Foundation

public func detectSupportedImageMimeType(fromFile path: String) -> String? {
    guard let handle = FileHandle(forReadingAtPath: path) else {
        return nil
    }
    defer { try? handle.close() }

    // v1.5.2 mime.ts reads enough bytes to inspect PNG chunks and BMP headers.
    let data = handle.readData(ofLength: 4_100)
    if data.count >= 8 {
        let pngSignature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        if Array(data.prefix(8)) == pngSignature {
            guard data.count >= 16, readUInt32BE(data, at: 8) == 13,
                  String(decoding: data[12..<16], as: UTF8.self) == "IHDR" else { return nil }
            var offset = 8
            while offset + 8 <= data.count {
                let length = Int(readUInt32BE(data, at: offset))
                let type = String(decoding: data[(offset + 4)..<(offset + 8)], as: UTF8.self)
                if type == "acTL" { return nil }
                if type == "IDAT" { return "image/png" }
                let next = offset + 12 + length
                if next <= offset || next > data.count { break }
                offset = next
            }
            return "image/png"
        }
    }

    if data.count >= 3 {
        let jpegSignature: [UInt8] = [0xFF, 0xD8, 0xFF]
        if Array(data.prefix(3)) == jpegSignature {
            return data.count > 3 && data[3] == 0xF7 ? nil : "image/jpeg"
        }
    }

    if data.count >= 6 {
        let header = String(bytes: data.prefix(6), encoding: .ascii) ?? ""
        if header.hasPrefix("GIF87a") || header.hasPrefix("GIF89a") {
            return "image/gif"
        }
    }

    if data.count >= 12 {
        let riff = String(bytes: data.prefix(4), encoding: .ascii) ?? ""
        let webp = String(bytes: data[8..<12], encoding: .ascii) ?? ""
        if riff == "RIFF" && webp == "WEBP" {
            return "image/webp"
        }
    }

    if data.count >= 26, data[0] == 0x42, data[1] == 0x4D {
        let declaredSize = readUInt32LE(data, at: 2)
        let pixelOffset = readUInt32LE(data, at: 10)
        let headerSize = readUInt32LE(data, at: 14)
        guard (declaredSize == 0 || declaredSize >= 26),
              UInt64(pixelOffset) >= 14 + UInt64(headerSize),
              declaredSize == 0 || pixelOffset < declaredSize else { return nil }
        let planeOffset: Int
        if headerSize == 12 { planeOffset = 22 }
        else if headerSize >= 40 && headerSize <= 124 && data.count >= 30 { planeOffset = 26 }
        else { return nil }
        let planes = readUInt16LE(data, at: planeOffset)
        let bits = readUInt16LE(data, at: planeOffset + 2)
        if planes == 1 && [1, 4, 8, 16, 24, 32].contains(bits) { return "image/bmp" }
    }

    return nil
}

private func readUInt16LE(_ data: Data, at index: Int) -> UInt16 {
    UInt16(data[index]) | (UInt16(data[index + 1]) << 8)
}

private func readUInt32LE(_ data: Data, at index: Int) -> UInt32 {
    UInt32(data[index]) | (UInt32(data[index + 1]) << 8) |
        (UInt32(data[index + 2]) << 16) | (UInt32(data[index + 3]) << 24)
}

private func readUInt32BE(_ data: Data, at index: Int) -> UInt32 {
    (UInt32(data[index]) << 24) | (UInt32(data[index + 1]) << 16) |
        (UInt32(data[index + 2]) << 8) | UInt32(data[index + 3])
}
