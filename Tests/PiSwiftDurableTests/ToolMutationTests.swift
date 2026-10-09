import Foundation
import Synchronization
import Testing
import PiSwiftAI
import PiSwiftChord
@testable import PiSwiftDurable

@Suite("Durable file mutation queue v1.1.0")
struct ToolMutationTests {
    @Test func missingChildWithCombiningMarkKeepsItsCanonicalQueue() async throws {
        let created = Mutex(false), entered = Mutex(false)
        let started = ToolTestGate(), release = ToolTestGate()
        var fixture = ToolFixtureEnv(base: LocalExecutionEnv())
        fixture.absolutePathHook = { .success($0) }
        fixture.canonicalPathHook = { path in
            if path == "/alias" { return .success("/real") }
            if path == "/real" { return .success(path) }
            if created.withLock({ $0 }) { return .success(path.replacingOccurrences(of: "/alias/", with: "/real/")) }
            return .failure(.init(.notFound, message: "missing"))
        }
        fixture.joinPathHook = { parts in
            if parts.last == ".." { return .success((parts[0] as NSString).deletingLastPathComponent) }
            return .success(parts.joined(separator: "/"))
        }
        let env = fixture
        let first = Task {
            try await withFileMutationQueue(env: env, path: "/alias/\u{0301}name", context: .background) {
                created.withLock { $0 = true }
                await started.release()
                await release.wait()
            }
        }
        await started.wait()
        let second = Task {
            try await withFileMutationQueue(env: env, path: "/real/\u{0301}name", context: .background) {
                entered.withLock { $0 = true }
            }
        }
        try await Task.sleep(for: .milliseconds(20))
        #expect(!entered.withLock { $0 })
        await release.release()
        _ = try await (first.value, second.value)
        #expect(entered.withLock { $0 })
    }

    @Test func canonicallyEquivalentEnvironmentIDsStaySeparate() async throws {
        let directory = try toolTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let base = LocalExecutionEnv(cwd: directory.path)
        let firstEnv = ToolFixtureEnv(base: base, id: "\u{00E9}"), secondEnv = ToolFixtureEnv(base: base, id: "e\u{0301}")
        let started = ToolTestGate(), release = ToolTestGate()
        let first = Task {
            try await withFileMutationQueue(env: firstEnv, path: "file.txt", context: .background) {
                await started.release()
                await release.wait()
            }
        }
        await started.wait()
        let entered = Mutex(false)
        let second = Task {
            try await withFileMutationQueue(env: secondEnv, path: "file.txt", context: .background) {
                entered.withLock { $0 = true }
            }
        }
        try await Task.sleep(for: .milliseconds(20))
        #expect(entered.withLock { $0 })
        await release.release()
        _ = try await (first.value, second.value)
    }

    @Test func abortedWriteHoldsQueueUntilWriteSettles() async throws {
        let directory = try toolTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let base = LocalExecutionEnv(cwd: directory.path)
        let started = ToolTestGate(), release = ToolTestGate()
        let secondStarted = Mutex(false)
        let env = ToolFixtureEnv(base: base, writeHook: { path, content, _ in
            if case .text("first\n") = content { await started.release(); await release.wait() }
            if case .text("second\n") = content { secondStarted.withLock { $0 = true } }
            return await base.writeFile(path, content: content, context: .background)
        })
        let controller = AbortController()
        let tool = try createWriteTool(), api = try toolTestApi(env: env)
        let first = Task {
            try await tool.execute(["path": "file.txt", "content": "first\n"], api,
                .background.withAbortSignal(controller.signal))
        }
        await started.wait()
        controller.abort()
        let second = Task { try await tool.execute(["path": "file.txt", "content": "second\n"], api, .background) }
        try await Task.sleep(for: .milliseconds(20))
        #expect(!secondStarted.withLock { $0 })
        await release.release()
        do { _ = try await first.value; Issue.record("Expected aborted write") }
        catch { #expect(String(describing: error) == "Operation aborted") }
        _ = try await second.value
        #expect(try await base.readTextFile("file.txt", context: .background).get() == "second\n")
    }

    @Test func concurrentEditsUseCanonicalPathAndSharedFileSystemIdentity() async throws {
        let directory = try toolTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let firstBase = LocalExecutionEnv(cwd: directory.path), secondBase = LocalExecutionEnv(cwd: directory.path)
        let first = ToolFixtureEnv(base: firstBase, slowRead: true), second = ToolFixtureEnv(base: secondBase, slowRead: true)
        try await firstBase.writeFile("target.txt", content: .text("alpha\nbeta\ngamma\n"), context: .background).get()
        try FileManager.default.createSymbolicLink(atPath: directory.appendingPathComponent("link.txt").path, withDestinationPath: "target.txt")
        let tool = try createEditTool()
        async let alpha = tool.execute(["path": "target.txt", "edits": [["oldText": "alpha", "newText": "ALPHA"]]], toolTestApi(env: first), .background)
        async let beta = tool.execute(["path": "link.txt", "edits": [["oldText": "beta", "newText": "BETA"]]], toolTestApi(env: second), .background)
        _ = try await (alpha, beta)
        #expect(try await firstBase.readTextFile("target.txt", context: .background).get() == "ALPHA\nBETA\ngamma\n")
        try await firstBase.writeFile("same.txt", content: .text("alpha\nbeta\n"), context: .background).get()
        async let a = tool.execute(["path": "same.txt", "edits": [["oldText": "alpha", "newText": "ALPHA"]]], toolTestApi(env: first), .background)
        async let b = tool.execute(["path": "same.txt", "edits": [["oldText": "beta", "newText": "BETA"]]], toolTestApi(env: second), .background)
        _ = try await (a, b)
        #expect(try await firstBase.readTextFile("same.txt", context: .background).get() == "ALPHA\nBETA\n")
    }

    @Test func missingFileUnderSymlinkDirectorySharesCanonicalQueue() async throws {
        let directory = try toolTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let base = LocalExecutionEnv(cwd: directory.path)
        try await base.createDir("real", options: nil, context: .background).get()
        try FileManager.default.createSymbolicLink(atPath: directory.appendingPathComponent("link").path, withDestinationPath: "real")
        let started = ToolTestGate(), release = ToolTestGate()
        let secondStarted = Mutex(false)
        let env = ToolFixtureEnv(base: base, writeHook: { path, content, context in
            if case .text("first\n") = content { await started.release(); await release.wait() }
            if case .text("second\n") = content { secondStarted.withLock { $0 = true } }
            return await base.writeFile(path, content: content, context: context)
        })
        let tool = try createWriteTool(), api = try toolTestApi(env: env)
        let first = Task { try await tool.execute(["path": "link/new.txt", "content": "first\n"], api, .background) }
        await started.wait()
        let second = Task { try await tool.execute(["path": "real/new.txt", "content": "second\n"], api, .background) }
        try await Task.sleep(for: .milliseconds(20))
        #expect(!secondStarted.withLock { $0 })
        await release.release()
        _ = try await (first.value, second.value)
        #expect(try await base.readTextFile("real/new.txt", context: .background).get() == "second\n")
    }

    @Test func missingBackslashNameKeepsItsQueueAfterCreation() async throws {
        let directory = try toolTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let env = LocalExecutionEnv(cwd: directory.path)
        let created = ToolTestGate(), release = ToolTestGate()
        let entered = Mutex(false)
        let first = Task {
            try await withFileMutationQueue(env: env, path: "a\\b.txt", context: .background) {
                try await env.writeFile("a\\b.txt", content: .text("first\n"), context: .background).get()
                await created.release()
                await release.wait()
            }
        }
        await created.wait()
        let second = Task {
            try await withFileMutationQueue(env: env, path: "a\\b.txt", context: .background) {
                entered.withLock { $0 = true }
            }
        }
        try await Task.sleep(for: .milliseconds(20))
        #expect(!entered.withLock { $0 })
        await release.release()
        _ = try await (first.value, second.value)
        #expect(entered.withLock { $0 })
    }

    @Test func differentFileSystemsAndFilesRunWithoutWaiting() async throws {
        let directory = try toolTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let base = LocalExecutionEnv(cwd: directory.path)
        let local = ToolFixtureEnv(base: base), other = ToolFixtureEnv(base: base, id: "other")
        let started = ToolTestGate(), release = ToolTestGate()
        let first = Task {
            try await withFileMutationQueue(env: local, path: "same.txt", context: .background) {
                await started.release(); await release.wait()
            }
        }
        await started.wait()
        try await withFileMutationQueue(env: other, path: "same.txt", context: .background) {
            try await base.writeFile("same.txt", content: .text("other"), context: .background).get()
        }
        try await withFileMutationQueue(env: local, path: "different.txt", context: .background) {
            try await base.writeFile("different.txt", content: .text("different"), context: .background).get()
        }
        await release.release()
        try await first.value
    }

    @Test func failedOperationReleasesQueue() async throws {
        let directory = try toolTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let env = LocalExecutionEnv(cwd: directory.path)
        do {
            try await withFileMutationQueue(env: env, path: "file.txt", context: .background) {
                throw DurableToolError(message: "write failed")
            }
        } catch { #expect(String(describing: error) == "write failed") }
        try await withFileMutationQueue(env: env, path: "file.txt", context: .background) {
            try await env.writeFile("file.txt", content: .text("success"), context: .background).get()
        }
        #expect(try await env.readTextFile("file.txt", context: .background).get() == "success")
    }
}
