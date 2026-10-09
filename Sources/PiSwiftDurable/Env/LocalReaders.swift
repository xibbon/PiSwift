import Foundation
import PiSwiftChord
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

internal actor LocalBinaryReader: BinaryReader {
    private var fd: Int32
    private let path: String
    private let io: LocalFileIO
    init(fd: Int32, path: String, io: LocalFileIO) { self.fd = fd; self.path = path; self.io = io }
    deinit { if fd >= 0 { _ = closeDescriptor(fd) } }
    private func check(_ context: ChordContext) throws {
        try LocalFS.check(context, path: path)
        if fd < 0 { throw FileError(.invalid, message: "Binary reader is closed", path: path) }
    }
    func info(context: ChordContext) async -> Result<FileInfo, FileError> {
        LocalFS.result {
            try check(context)
            var value = stat()
            guard fstat(fd, &value) == 0 else { throw LocalFS.error(path: path) }
            return try LocalFS.info(path, stats: value)
        }
    }
    func read(offset: Int64, length: Int, context: ChordContext) async -> Result<[UInt8], FileError> {
        do {
            try check(context)
            guard offset >= 0, offset <= LocalFS.maxSafeInteger, length >= 0, Int64(length) <= LocalFS.maxSafeInteger else {
                throw FileError(.invalid, message: "Offset and length must be non-negative safe integers", path: path)
            }
            var bytes: [UInt8] = []
            while bytes.count < length {
                await io.beforeRead?()
                // Recheck the descriptor after a test hook yields to close().
                if fd < 0 { throw FileError(.invalid, message: "Binary reader is closed", path: path) }
                let chunk = try LocalFS.read(fd, offset: offset + Int64(bytes.count), length: min(length - bytes.count, 1024 * 1024), path: path)
                try LocalFS.check(context, path: path)
                if chunk.isEmpty { break }
                bytes.append(contentsOf: chunk)
            }
            return .success(bytes)
        } catch let failure as FileError { return .failure(failure) }
        catch { return .failure(FileError(.unknown, message: String(describing: error), path: path)) }
    }
    func scanLines(options: ScanLinesOptions, context: ChordContext) async -> Result<LineScan, FileError> {
        do {
            try check(context)
            var scanner = try LineScanner(startLine: options.startLine, endLine: options.endLine)
            var offset: Int64 = 0
            while true {
                await io.beforeRead?()
                if fd < 0 { throw FileError(.invalid, message: "Binary reader is closed", path: path) }
                let bytes = try LocalFS.read(fd, offset: offset, length: 64 * 1024, path: path)
                try LocalFS.check(context, path: path)
                if bytes.isEmpty { return .success(scanner.finish()) }
                scanner.push(bytes)
                offset += Int64(bytes.count)
            }
        } catch let failure as FileError { return .failure(FileError(failure.code, message: failure.message, path: path)) }
        catch { return .failure(FileError(.unknown, message: String(describing: error), path: path)) }
    }
    func close(context: ChordContext) async {
        if fd >= 0 { _ = closeDescriptor(fd); fd = -1 }
    }
}

internal actor LocalTextLineReader: TextLineReader {
    private var fd: Int32
    private let path: String
    private let io: LocalFileIO
    private var offset: Int64 = 0
    private var buffered = ""
    private var decoder = StreamDecoder()
    private var ended = false
    init(fd: Int32, path: String, io: LocalFileIO) { self.fd = fd; self.path = path; self.io = io }
    deinit { if fd >= 0 { _ = closeDescriptor(fd) } }
    func readLine(context: ChordContext) async -> Result<TextLine?, FileError> {
        do {
            try LocalFS.check(context, path: path)
            if fd < 0 { throw FileError(.invalid, message: "Text line reader is closed", path: path) }
            while true {
                // Search scalars: Swift Character can combine CR and LF into one character.
                if let newline = buffered.unicodeScalars.firstIndex(of: "\n") {
                    let text = String(buffered[..<newline])
                    buffered = String(buffered[buffered.unicodeScalars.index(after: newline)...])
                    return .success(TextLine(text: text, terminated: true))
                }
                if ended {
                    if buffered.isEmpty { return .success(nil) }
                    let text = buffered; buffered = ""
                    return .success(TextLine(text: text, terminated: false))
                }
                await io.beforeRead?()
                if fd < 0 { throw FileError(.invalid, message: "Text line reader is closed", path: path) }
                let bytes = try LocalFS.read(fd, offset: offset, length: 64 * 1024, path: path)
                try LocalFS.check(context, path: path)
                offset += Int64(bytes.count)
                if bytes.isEmpty { buffered += decoder.decode(); ended = true }
                else { buffered += decoder.decode(bytes) }
            }
        } catch let failure as FileError { return .failure(failure) }
        catch { return .failure(FileError(.unknown, message: String(describing: error), path: path)) }
    }
    func close(context: ChordContext) async {
        if fd >= 0 { _ = closeDescriptor(fd); fd = -1; buffered = "" }
    }
}

internal actor LocalDirReader: DirReader {
    // The address is used only in actor-isolated, synchronous operations.
    private var address: UInt
    private let path: String
    private var done = false
    init(directory: UnsafeMutablePointer<DIR>, path: String) { address = UInt(bitPattern: directory); self.path = path }
    deinit { if let directory = UnsafeMutablePointer<DIR>(bitPattern: address) { closedir(directory) } }
    func next(maxEntries: Int, context: ChordContext) async -> Result<DirectoryPage, FileError> {
        LocalFS.result {
            try LocalFS.check(context, path: path)
            guard let directory = UnsafeMutablePointer<DIR>(bitPattern: address) else { throw FileError(.invalid, message: "Directory reader is closed", path: path) }
            guard maxEntries > 0, Int64(maxEntries) <= LocalFS.maxSafeInteger else { throw FileError(.invalid, message: "maxEntries must be a positive safe integer", path: path) }
            var entries: [FileInfo] = []
            while !done && entries.count < maxEntries {
                errno = 0
                guard let entry = readdir(directory) else {
                    if errno != 0 { throw LocalFS.error(path: path) }
                    done = true; break
                }
                try LocalFS.check(context, path: path)
                let name = withUnsafePointer(to: &entry.pointee.d_name) {
                    $0.withMemoryRebound(to: CChar.self, capacity: 256) { String(cString: $0) }
                }
                if name == "." || name == ".." { continue }
                let entryPath = LocalFS.normalize(path + "/" + name)
                let value: stat
                do { value = try LocalFS.stats(entryPath) }
                catch let failure as FileError { if failure.code == .notFound { continue }; throw failure }
                if let info = try? LocalFS.info(entryPath, stats: value) { entries.append(info) }
            }
            return DirectoryPage(entries: entries, done: done)
        }
    }
    func close(context: ChordContext) async {
        if let directory = UnsafeMutablePointer<DIR>(bitPattern: address) { closedir(directory); address = 0 }
    }
}

private func closeDescriptor(_ fd: Int32) -> Int32 {
    #if canImport(Darwin)
    Darwin.close(fd)
    #else
    Glibc.close(fd)
    #endif
}
