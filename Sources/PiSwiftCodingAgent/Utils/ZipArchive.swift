import Foundation

public struct ZipEntry: Sendable {
    public var name: String
    public var data: Data

    public init(name: String, data: Data) { self.name = name; self.data = data }
    public init(name: String, text: String) { self.name = name; self.data = Data(text.utf8) }
}

public enum ZipArchiveError: Error, Sendable { case invalidEntry, archiveTooLarge }

private func crc32(_ data: Data) -> UInt32 {
    var crc: UInt32 = 0xffff_ffff
    for byte in data {
        crc ^= UInt32(byte)
        for _ in 0..<8 { crc = (crc >> 1) ^ ((crc & 1) == 1 ? 0xedb8_8320 : 0) }
    }
    return ~crc
}

private extension Data {
    mutating func zip16(_ value: UInt16) {
        append(UInt8(truncatingIfNeeded: value))
        append(UInt8(truncatingIfNeeded: value >> 8))
    }
    mutating func zip32(_ value: UInt32) {
        zip16(UInt16(truncatingIfNeeded: value))
        zip16(UInt16(truncatingIfNeeded: value >> 16))
    }
}

/// Classic ZIP with UTF-8 names and stored entries. Store is equivalent to
/// upstream's deflate writer for these small reports and needs no platform library.
public func createZipArchive(_ entries: [ZipEntry], date: Date = Date()) throws -> Data {
    guard entries.count <= Int(UInt16.max) else { throw ZipArchiveError.archiveTooLarge }
    var archive = Data()
    var central = Data()
    let calendar = Calendar.current
    let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
    let time = UInt16(((parts.hour ?? 0) << 11) | ((parts.minute ?? 0) << 5) | ((parts.second ?? 0) >> 1))
    let day = UInt16(((max(1980, parts.year ?? 1980) - 1980) << 9) | ((parts.month ?? 1) << 5) | (parts.day ?? 1))
    for entry in entries {
        guard !entry.name.isEmpty, !entry.name.hasPrefix("/"), !entry.name.split(separator: "/").contains("..") else { throw ZipArchiveError.invalidEntry }
        let name = Data(entry.name.utf8)
        guard name.count <= Int(UInt16.max), entry.data.count <= Int(UInt32.max), archive.count <= Int(UInt32.max) else { throw ZipArchiveError.archiveTooLarge }
        let size = UInt32(entry.data.count)
        let checksum = crc32(entry.data)
        let offset = UInt32(archive.count)
        archive.zip32(0x04034b50)
        archive.zip16(20); archive.zip16(0x0800); archive.zip16(0)
        archive.zip16(time); archive.zip16(day)
        archive.zip32(checksum); archive.zip32(size); archive.zip32(size)
        archive.zip16(UInt16(name.count)); archive.zip16(0)
        archive.append(name); archive.append(entry.data)

        central.zip32(0x02014b50)
        central.zip16(20); central.zip16(20); central.zip16(0x0800); central.zip16(0)
        central.zip16(time); central.zip16(day)
        central.zip32(checksum); central.zip32(size); central.zip32(size)
        central.zip16(UInt16(name.count)); central.zip16(0); central.zip16(0)
        central.zip16(0); central.zip16(0); central.zip32(0)
        central.zip32(offset); central.append(name)
    }
    guard archive.count <= Int(UInt32.max), central.count <= Int(UInt32.max) else { throw ZipArchiveError.archiveTooLarge }
    let centralOffset = UInt32(archive.count)
    archive.append(central)
    archive.zip32(0x06054b50)
    archive.zip16(0); archive.zip16(0)
    archive.zip16(UInt16(entries.count)); archive.zip16(UInt16(entries.count))
    archive.zip32(UInt32(central.count)); archive.zip32(centralOffset)
    archive.zip16(0)
    return archive
}

public func writeZipArchive(_ entries: [ZipEntry], to path: String) throws {
    try createZipArchive(entries).write(to: URL(fileURLWithPath: path), options: .atomic)
}
