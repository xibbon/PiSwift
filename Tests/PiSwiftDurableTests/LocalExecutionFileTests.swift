import Foundation
import Synchronization
import Testing
import PiSwiftChord
@testable import PiSwiftDurable
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

private func localFileRoot() throws -> String {
    let path = FileManager.default.temporaryDirectory.appendingPathComponent("pi-local-files-\(UUID().uuidString)").path
    try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    return path
}

private func localFileFailure<T>(_ result: Result<T, FileError>) throws -> FileError {
    guard case .failure(let error) = result else {
        throw FileError(.unknown, message: "Expected a file operation to fail")
    }
    return error
}

private func localFileAborted<T>(_ result: Result<T, FileError>) throws {
    let error = try localFileFailure(result)
    #expect(error.code == .aborted)
}

private struct LocalSyncHandle: Sendable {
    let fd: Int32
    let device: Int64
    let inode: UInt64

    init?(_ fd: Int32) {
        var info = stat()
        guard fstat(fd, &info) == 0 else { return nil }
        self.fd = fd
        device = Int64(info.st_dev)
        inode = UInt64(info.st_ino)
    }
}

private func localExpectSyncClosed(_ handle: LocalSyncHandle) {
    if fcntl(handle.fd, F_GETFD) == -1 {
        #expect(errno == EBADF)
        return
    }
    var current = stat()
    if fstat(handle.fd, &current) == -1 {
        #expect(errno == EBADF)
    } else {
        // Another parallel test can open a different file with the closed descriptor number.
        #expect(Int64(current.st_dev) != handle.device || UInt64(current.st_ino) != handle.inode)
    }
}

struct LocalExecutionFileTests {
    @Test("reads, writes, lists, and removes files and directories")
    func readsWritesListsRemoves() async throws {
        let root = try localFileRoot(); defer { try? FileManager.default.removeItem(atPath: root) }
        let env = LocalExecutionEnv(cwd: root)
        #expect(try await env.absolutePath("nested/child", context: .background).get() == root + "/nested/child")
        #expect(try await env.joinPath([root, "nested", "child"], context: .background).get() == root + "/nested/child")
        try await env.createDir("nested/child", options: nil, context: .background).get()
        try await env.writeFile("nested/child/file.txt", content: .text("hel"), context: .background).get()
        try await env.appendFile("nested/child/file.txt", content: .text("lo"), context: .background).get()
        #expect(try await env.readTextFile("nested/child/file.txt", context: .background).get() == "hello")
        #expect(try await env.readTextLines("nested/child/file.txt", options: .init(maxLines: 1), context: .background).get() == ["hello"])
        #expect(try await env.readBinaryFile("nested/child/file.txt", context: .background).get() == Array("hello".utf8))
        let entries = try await env.listDir("nested/child", context: .background).get()
        #expect(entries.count == 1)
        let entry = try #require(entries.first)
        #expect(entry.name == "file.txt")
        #expect(entry.path == root + "/nested/child/file.txt")
        #expect(entry.kind == .file)
        #expect(entry.size == 5)
        #expect(entry.mtimeMs > 0)
        #expect(try await env.exists("nested/child/file.txt", context: .background).get())
        try await env.remove("nested/child/file.txt", options: nil, context: .background).get()
        #expect(try await !env.exists("nested/child/file.txt", context: .background).get())
    }

    @Test("expands home-relative paths and file URLs")
    func expandsHomeAndURLs() async throws {
        let root = try localFileRoot(); defer { try? FileManager.default.removeItem(atPath: root) }
        let env = LocalExecutionEnv(cwd: root)
        #expect(try await env.absolutePath("~/pi-node-env-test", context: .background).get() == NSHomeDirectory() + "/pi-node-env-test")
        #expect(try await env.absolutePath("~", context: .background).get() == NSHomeDirectory())
        let path = root + "/file with spaces.txt"
        #expect(try await env.absolutePath(URL(fileURLWithPath: path).absoluteString, context: .background).get() == path)
    }

    @Test("returns fileInfo for files, directories, and symlinks without following symlinks")
    func fileInfoDoesNotFollowLinks() async throws {
        let root = try localFileRoot(); defer { try? FileManager.default.removeItem(atPath: root) }
        let env = LocalExecutionEnv(cwd: root)
        try await env.createDir("dir", options: .init(recursive: true), context: .background).get()
        try await env.writeFile("dir/file.txt", content: .text("hello"), context: .background).get()
        try FileManager.default.createSymbolicLink(atPath: root + "/file-link", withDestinationPath: root + "/dir/file.txt")
        try FileManager.default.createSymbolicLink(atPath: root + "/dir-link", withDestinationPath: root + "/dir")
        for (path, kind) in [("dir", FileKind.directory), ("dir/file.txt", .file), ("file-link", .symlink), ("dir-link", .symlink)] {
            let info = try await env.fileInfo(path, context: .background).get()
            #expect(info.path == root + "/" + path)
            #expect(info.name == URL(fileURLWithPath: path).lastPathComponent)
            #expect(info.kind == kind)
            if kind == .file { #expect(info.size == 5) }
        }
        let pointer = try #require(realpath(root + "/dir/file.txt", nil))
        defer { free(pointer) }
        let expectedPath = String(cString: pointer)
        #expect(try await env.canonicalPath("file-link", context: .background).get() == expectedPath)
    }

    @Test("lists symlinks as symlinks")
    func listsSymlinks() async throws {
        let root = try localFileRoot(); defer { try? FileManager.default.removeItem(atPath: root) }
        let env = LocalExecutionEnv(cwd: root)
        try await env.writeFile("target.txt", content: .text("hello"), context: .background).get()
        try FileManager.default.createSymbolicLink(atPath: root + "/link.txt", withDestinationPath: root + "/target.txt")
        let entries = try await env.listDir(".", context: .background).get().sorted { $0.name < $1.name }
        #expect(entries.map(\.name) == ["link.txt", "target.txt"])
        #expect(entries.map(\.kind) == [.symlink, .file])
    }

    @Test("stops reading text lines at the requested limit")
    func stopsAtLineLimit() async throws {
        let root = try localFileRoot(); defer { try? FileManager.default.removeItem(atPath: root) }
        let env = LocalExecutionEnv(cwd: root)
        try await env.writeFile("file.txt", content: .text("one\ntwo\nthree"), context: .background).get()
        #expect(try await env.readTextLines("file.txt", options: .init(maxLines: 1), context: .background).get() == ["one"])
    }

    @Test("returns FileError for missing paths and keeps exists false for missing paths")
    func missingPaths() async throws {
        let root = try localFileRoot(); defer { try? FileManager.default.removeItem(atPath: root) }
        let env = LocalExecutionEnv(cwd: root)
        let error = try localFileFailure(await env.fileInfo("missing.txt", context: .background))
        #expect(error.code == .notFound)
        #expect(error.path == root + "/missing.txt")
        #expect(try await !env.exists("missing.txt", context: .background).get())
    }

    @Test("returns FileError for listing non-directories")
    func listsNonDirectory() async throws {
        let root = try localFileRoot(); defer { try? FileManager.default.removeItem(atPath: root) }
        let env = LocalExecutionEnv(cwd: root)
        try await env.writeFile("file.txt", content: .text("hello"), context: .background).get()
        #expect(try localFileFailure(await env.listDir("file.txt", context: .background)).code == .notDirectory)
    }

    @Test("appends to new files and creates parent directories")
    func appendsWithParents() async throws {
        let root = try localFileRoot(); defer { try? FileManager.default.removeItem(atPath: root) }
        let env = LocalExecutionEnv(cwd: root)
        try await env.appendFile("new/nested/file.txt", content: .text("a"), context: .background).get()
        try await env.appendFile("new/nested/file.txt", content: .text("b"), context: .background).get()
        #expect(try await env.readTextFile("new/nested/file.txt", context: .background).get() == "ab")
    }

    @Test("atomically renames a file and replaces the destination")
    func renameReplacesDestination() async throws {
        let root = try localFileRoot(); defer { try? FileManager.default.removeItem(atPath: root) }
        let env = LocalExecutionEnv(cwd: root)
        try await env.writeFile("source.txt", content: .text("new"), context: .background).get()
        try await env.writeFile("destination.txt", content: .text("old"), context: .background).get()
        try await env.renameFile("source.txt", destinationPath: "destination.txt", context: .background).get()
        #expect(try await !env.exists("source.txt", context: .background).get())
        #expect(try await env.readTextFile("destination.txt", context: .background).get() == "new")
    }

    @Test("reports the source path when rename fails because the source is missing")
    func renameMissingSource() async throws {
        let root = try localFileRoot(); defer { try? FileManager.default.removeItem(atPath: root) }
        let env = LocalExecutionEnv(cwd: root)
        try await env.writeFile("destination.txt", content: .text("unchanged"), context: .background).get()
        let error = try localFileFailure(await env.renameFile("missing-source.txt", destinationPath: "destination.txt", context: .background))
        #expect(error.code == .notFound)
        #expect(error.path == root + "/missing-source.txt")
        #expect(try await env.readTextFile("destination.txt", context: .background).get() == "unchanged")
    }

    @Test("creates temporary directories and files")
    func createsTemporaryEntries() async throws {
        let root = try localFileRoot(); defer { try? FileManager.default.removeItem(atPath: root) }
        let env = LocalExecutionEnv(cwd: root)
        let directory = try await env.createTempDir(prefix: "node-env-test-", context: .background).get()
        defer { try? FileManager.default.removeItem(atPath: directory) }
        #expect(FileManager.default.fileExists(atPath: directory))
        let file = try await env.createTempFile(options: .init(prefix: "prefix-", suffix: ".txt"), context: .background).get()
        defer { try? FileManager.default.removeItem(atPath: URL(fileURLWithPath: file).deletingLastPathComponent().path) }
        #expect(FileManager.default.fileExists(atPath: file))
        #expect(file.hasSuffix(".txt"))
        #expect(try await env.readTextFile(file, context: .background).get() == "")
    }

    @Test("honors createDir recursive false and remove recursive/force options")
    func directoryAndRemoveOptions() async throws {
        let root = try localFileRoot(); defer { try? FileManager.default.removeItem(atPath: root) }
        let env = LocalExecutionEnv(cwd: root)
        #expect(try localFileFailure(await env.createDir("missing/child", options: .init(recursive: false), context: .background)).code == .notFound)
        try await env.writeFile("dir/child/file.txt", content: .text("hello"), context: .background).get()
        _ = try localFileFailure(await env.remove("dir", options: .init(recursive: false), context: .background))
        try await env.remove("dir", options: .init(recursive: true), context: .background).get()
        #expect(try await !env.exists("dir", context: .background).get())
        _ = try localFileFailure(await env.remove("missing", options: .init(force: false), context: .background))
        try await env.remove("missing", options: .init(force: true), context: .background).get()
    }

    @Test("returns aborted results without side effects for pre-aborted file operations")
    func preAbortedHasNoEffects() async throws {
        let root = try localFileRoot(); defer { try? FileManager.default.removeItem(atPath: root) }
        let env = LocalExecutionEnv(cwd: root)
        try await env.writeFile("file.txt", content: .text("hello"), context: .background).get()
        let controller = AbortController(); controller.abort()
        let context = ChordContext.background.withAbortSignal(controller.signal)
        try localFileAborted(await env.readTextFile("file.txt", context: context))
        try localFileAborted(await env.readTextLines("file.txt", options: nil, context: context))
        try localFileAborted(await env.readBinaryFile("file.txt", context: context))
        try localFileAborted(await env.openTextLineReader("file.txt", context: context))
        try localFileAborted(await env.writeFile("other.txt", content: .text("hello"), context: context))
        try localFileAborted(await env.appendFile("file.txt", content: .text(" world"), context: context))
        try localFileAborted(await env.truncateFile("file.txt", size: 1, context: context))
        try localFileAborted(await env.flushFile("file.txt", context: context))
        try localFileAborted(await env.renameFile("file.txt", destinationPath: "renamed.txt", context: context))
        try localFileAborted(await env.fileInfo("file.txt", context: context))
        try localFileAborted(await env.listDir(".", context: context))
        try localFileAborted(await env.canonicalPath("file.txt", context: context))
        try localFileAborted(await env.exists("file.txt", context: context))
        try localFileAborted(await env.createDir("dir", options: nil, context: context))
        try localFileAborted(await env.remove("file.txt", options: nil, context: context))
        try localFileAborted(await env.createTempDir(prefix: nil, context: context))
        try localFileAborted(await env.createTempFile(options: nil, context: context))
        try localFileAborted(await env.openBinaryReader("file.txt", options: nil, context: context))
        try localFileAborted(await env.openDirReader(".", context: context))
        #expect(try await env.readTextFile("file.txt", context: .background).get() == "hello")
        #expect(try await env.listDir(".", context: .background).get().map(\.name) == ["file.txt"])
    }

    @Test("truncates and extends files to exact byte sizes")
    func truncatesExactBytes() async throws {
        let root = try localFileRoot(); defer { try? FileManager.default.removeItem(atPath: root) }
        let env = LocalExecutionEnv(cwd: root)
        try await env.writeFile("file.bin", content: .bytes([0x61, 0xc3, 0xa9, 0x0a, 0x62, 0x0a]), context: .background).get()
        try await env.truncateFile("file.bin", size: 2, context: .background).get()
        #expect(try await env.readBinaryFile("file.bin", context: .background).get() == [0x61, 0xc3])
        try await env.truncateFile("file.bin", size: 4, context: .background).get()
        #expect(try await env.readBinaryFile("file.bin", context: .background).get() == [0x61, 0xc3, 0, 0])
        try await env.truncateFile("file.bin", size: 0, context: .background).get()
        #expect(try await env.fileInfo("file.bin", context: .background).get().size == 0)
    }

    @Test("rejects invalid truncation sizes and never creates missing files")
    func rejectsInvalidTruncation() async throws {
        let root = try localFileRoot(); defer { try? FileManager.default.removeItem(atPath: root) }
        let env = LocalExecutionEnv(cwd: root)
        try await env.writeFile("file.txt", content: .text("hello"), context: .background).get()
        // Int64 excludes fractional, NaN, and infinite upstream inputs.
        for size in [Int64(-1), 9_007_199_254_740_992] {
            let error = try localFileFailure(await env.truncateFile("file.txt", size: size, context: .background))
            #expect(error.code == .invalid)
            #expect(error.path == root + "/file.txt")
        }
        #expect(try await env.readTextFile("file.txt", context: .background).get() == "hello")
        let error = try localFileFailure(await env.truncateFile("missing.txt", size: 0, context: .background))
        #expect(error.code == .notFound)
        #expect(error.path == root + "/missing.txt")
        #expect(try await !env.exists("missing.txt", context: .background).get())
    }

    @Test("flushes existing files without changing content and reports missing paths")
    func flushPreservesContent() async throws {
        let root = try localFileRoot(); defer { try? FileManager.default.removeItem(atPath: root) }
        let env = LocalExecutionEnv(cwd: root)
        try await env.writeFile("file.txt", content: .text("durable"), context: .background).get()
        try await env.flushFile("file.txt", context: .background).get()
        #expect(try await env.readTextFile("file.txt", context: .background).get() == "durable")
        let error = try localFileFailure(await env.flushFile("missing.txt", context: .background))
        #expect(error.code == .notFound)
        #expect(error.path == root + "/missing.txt")
        #expect(try await !env.exists("missing.txt", context: .background).get())
        try await env.createDir("dir", options: nil, context: .background).get()
        #expect(try localFileFailure(await env.flushFile("dir", context: .background)).code == .isDirectory)
    }

    @Test("syncs through an opened handle, returns sync failures, and always closes the handle")
    func syncClosesOnSuccessAndFailure() async throws {
        let root = try localFileRoot(); defer { try? FileManager.default.removeItem(atPath: root) }
        let descriptors = Mutex<[LocalSyncHandle]>([])
        let io = LocalFileIO(fullSync: { fd in
            guard let handle = LocalSyncHandle(fd) else { return EBADF }
            let count = descriptors.withLock { values in values.append(handle); return values.count }
            return count == 1 ? LocalFS.fullSyncError(fd) : EIO
        })
        let env = LocalExecutionEnv(cwd: root, io: io)
        try await env.writeFile("file.txt", content: .text("durable"), context: .background).get()
        try await env.flushFile("file.txt", context: .background).get()
        let first = try #require(descriptors.withLock { $0.first })
        #expect(descriptors.withLock { $0.count } == 1)
        localExpectSyncClosed(first)
        let error = try localFileFailure(await env.flushFile("file.txt", context: .background))
        #expect(error.code == .unknown)
        #expect(error.path == root + "/file.txt")
        #expect(!error.message.isEmpty)
        let second = try #require(descriptors.withLock { $0.last })
        #expect(descriptors.withLock { $0.count } == 2)
        localExpectSyncClosed(second)
    }

    @Test("cleanup is best-effort")
    func cleanupIsBestEffort() async throws {
        let root = try localFileRoot(); defer { try? FileManager.default.removeItem(atPath: root) }
        await LocalExecutionEnv(cwd: root).cleanup(context: .background)
    }

    @Test("attempts full sync and falls back to fsync when full sync is unsupported")
    func fullSyncFallback() async throws {
        let root = try localFileRoot(); defer { try? FileManager.default.removeItem(atPath: root) }
        let operations = Mutex<[String]>([])
        let descriptors = Mutex<[LocalSyncHandle]>([])
        let io = LocalFileIO(fullSync: { fd in
            operations.withLock { $0.append("full") }
            guard let handle = LocalSyncHandle(fd) else { return EBADF }
            descriptors.withLock { $0.append(handle) }
            return EINVAL
        }, sync: { fd in
            operations.withLock { $0.append("sync") }
            guard let handle = LocalSyncHandle(fd) else { return EBADF }
            descriptors.withLock { $0.append(handle) }
            return LocalFS.syncError(fd)
        })
        let env = LocalExecutionEnv(cwd: root, io: io)
        try await env.writeFile("file.txt", content: .text("durable"), context: .background).get()
        try await env.flushFile("file.txt", context: .background).get()
        #expect(operations.withLock { $0 } == ["full", "sync"])
        let handles = descriptors.withLock { $0 }
        #expect(handles.count == 2)
        #expect(handles.first?.fd == handles.last?.fd)
        localExpectSyncClosed(try #require(handles.first))
    }
}
