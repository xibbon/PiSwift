import Foundation
import Testing
import PiSwiftChord
@testable import PiSwiftDurable
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

struct LocalExecutionPathTests {
    @Test func pathRules() async throws {
        let env = LocalExecutionEnv(cwd: "relative/dir")
        let base = FileManager.default.currentDirectoryPath
        #expect(try await env.absolutePath("../x", context: .background).get() == base + "/relative/x")
        #expect(try await env.absolutePath("~", context: .background).get() == FileManager.default.homeDirectoryForCurrentUser.path)
        #expect(try await env.absolutePath("file:///tmp/a%20b?query#fragment", context: .background).get() == "/tmp/a b")
        #expect(try await env.absolutePath("file:///tmp/a?query=%2F", context: .background).get() == "/tmp/a")
        #expect(try await env.absolutePath("file://LOCALHOST/tmp/x", context: .background).get() == "/tmp/x")
        for malformed in ["file:///tmp/%ff", "file:///tmp/%zz", "file://user@localhost/tmp/x"] {
            let ordinary = base + "/relative/dir/" + malformed.split(separator: "/").joined(separator: "/")
            #expect(try await env.absolutePath(malformed, context: .background).get() == ordinary)
        }
        #expect(try await env.absolutePath("file:///tmp/a%2Fb", context: .background).get() == base + "/relative/dir/file:/tmp/a%2Fb")
        #expect(try await env.joinPath(["a", "../b/"], context: .background).get() == "b/")
        #expect(try await env.joinPath([], context: .background).get() == ".")
        #expect(env.id == "local")
        env.cwd = "/tmp"
        #expect(try await env.absolutePath("x", context: .background).get() == "/tmp/x")
    }
    @Test func errnoMapping() {
        let cases: [(Int32, FileErrorCode)] = [(ENOENT, .notFound), (EACCES, .permissionDenied), (EPERM, .permissionDenied),
                                              (ENOTDIR, .notDirectory), (EISDIR, .isDirectory), (EINVAL, .invalid), (EIO, .unknown), (EEXIST, .unknown)]
        for (number, code) in cases {
            let error = LocalFS.error(number, path: "/path")
            #expect(error.code == code); #expect(error.path == "/path"); #expect(!error.message.isEmpty)
        }
    }
    @Test func nullWriteHasNoSideEffectAndZeroLimitHonorsAbort() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let env = LocalExecutionEnv(cwd: directory.path)
        if case .failure(let error) = await env.writeFile("file\u{0}suffix", content: .text("x"), context: .background) { #expect(error.code == .invalid) }
        else { Issue.record("Expected invalid path") }
        #expect(try await env.listDir(".", context: .background).get().isEmpty)
        let child = ChordContext.background.withCancel(); child.cancel()
        if case .failure(let error) = await env.readTextLines("missing", options: .init(maxLines: 0), context: child.context) { #expect(error.code == .aborted) }
        else { Issue.record("Expected aborted zero-limit read") }
    }
    @Test func wholeFileReadsAllowReadableDevices() async throws {
        let env = LocalExecutionEnv()
        #expect(try await env.readBinaryFile("/dev/null", context: .background).get().isEmpty)
        if case .failure(let error) = await env.openBinaryReader("/dev/null", options: nil, context: .background) { #expect(error.code == .invalid) }
        else { Issue.record("Expected regular-file reader to refuse a device") }
    }
}
