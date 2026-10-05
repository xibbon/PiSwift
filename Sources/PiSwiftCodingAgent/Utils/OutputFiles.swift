import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Output can contain private data. Create each file with access for its owner only.
private func outputFilePath(prefix: String, extension fileExtension: String) -> String {
    let suffix = (0..<8).map { _ in String(format: "%02x", UInt8.random(in: .min ... .max)) }.joined()
    return FileManager.default.temporaryDirectory
        .appendingPathComponent("\(prefix)-\(suffix)\(fileExtension)").path
}

/// Open a new file without replacing an existing file or following a link.
/// The path overload also permits tests of an existing file and a link.
func createOutputFileStream(at path: String) throws -> FileHandle {
    let descriptor = open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, mode_t(0o600))
    guard descriptor >= 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
}

func createOutputFileStream(prefix: String, extension fileExtension: String) throws -> (path: String, stream: FileHandle) {
    let path = outputFilePath(prefix: prefix, extension: fileExtension)
    return (path, try createOutputFileStream(at: path))
}

func writeOutputFile(prefix: String, extension fileExtension: String, data: Data) throws -> String {
    let file = try createOutputFileStream(prefix: prefix, extension: fileExtension)
    do {
        try file.stream.write(contentsOf: data)
        try file.stream.close()
    } catch {
        try? file.stream.close()
        throw error
    }
    return file.path
}
