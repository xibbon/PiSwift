import Foundation
import Synchronization
import Testing
import PiSwiftAI
import PiSwiftChord
@testable import PiSwiftDurable

@Suite("Durable edit tool v1.1.0")
struct ToolEditTests {
    @Test func disjointEditsReturnBothDiffFormats() async throws {
        let directory = try toolTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let env = LocalExecutionEnv(cwd: directory.path)
        try await env.writeFile("edit.txt", content: .text("alpha\nbeta\ngamma\ndelta\n"), context: .background).get()
        let result = try await createEditTool().execute(["path": "edit.txt", "edits": [
            ["oldText": "alpha\n", "newText": "ALPHA\n"], ["oldText": "gamma\n", "newText": "GAMMA\n"]]], toolTestApi(env: env), .background)
        #expect(toolResultText(result) == "Successfully replaced 2 block(s) in edit.txt.")
        let details = try #require(result.details).decode(EditToolDetails.self)
        #expect(details.diff == "-1 alpha\n+1 ALPHA\n 2 beta\n-3 gamma\n+3 GAMMA\n 4 delta")
        #expect(details.patch == "--- edit.txt\n+++ edit.txt\n@@ -1,4 +1,4 @@\n-alpha\n+ALPHA\n beta\n-gamma\n+GAMMA\n delta\n")
        #expect(details.firstChangedLine == 1)
        #expect(try await env.readTextFile("edit.txt", context: .background).get() == "ALPHA\nbeta\nGAMMA\ndelta\n")
    }

    @Test func repairsArgumentsWithoutChangingTheInput() throws {
        let prepare = try #require(createEditTool().prepareArguments)
        let edit: JSONValue = ["oldText": "a", "newText": "b"]
        let asString: JSONValue = ["path": "f", "edits": .string("[{\"oldText\":\"a\",\"newText\":\"b\"}]")]
        #expect(try prepare(asString) == ["path": "f", "edits": .array([edit])])
        #expect(asString["edits"]?.stringValue == "[{\"oldText\":\"a\",\"newText\":\"b\"}]")
        #expect(try prepare(["path": "f", "edits": "{\"oldText\":\"a\",\"newText\":\"b\"}"]) == ["path": "f", "edits": .array([edit])])
        #expect(try prepare(["path": "f", "edits": edit]) == ["path": "f", "edits": .array([edit])])
        #expect(try prepare(["path": "f", "oldText": "a", "newText": "b"]) == ["path": "f", "edits": .array([edit])])
        #expect(try prepare(["path": "f", "edits": .array([edit]), "oldText": "c", "newText": "d"]) ==
            ["path": "f", "edits": .array([edit, ["oldText": "c", "newText": "d"]])])
        let invalid: JSONValue = ["path": "f", "edits": "not json"]
        #expect(try prepare(invalid) == invalid)
        #expect(try prepare(["path": "f", "edits": "42"]) == ["path": "f", "edits": "42"])
        #expect(try prepare(.array([edit])) == .array([edit]))
        #expect(try prepare(.null) == .null)
    }

    @Test func failuresLeaveTheFileUnchanged() async throws {
        let directory = try toolTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let env = LocalExecutionEnv(cwd: directory.path)
        let original = "one\ntwo\nthree\nfoo foo foo\n"
        try await env.writeFile("edit.txt", content: .text(original), context: .background).get()
        let inputs: [JSONValue] = [
            ["path": "edit.txt", "edits": [["oldText": "one\ntwo\n", "newText": "ONE"], ["oldText": "two\nthree\n", "newText": "TWO"]]],
            ["path": "edit.txt", "edits": [["oldText": "missing", "newText": "X"]]],
            ["path": "edit.txt", "edits": [["oldText": "foo", "newText": "X"]]],
            ["path": "edit.txt", "edits": [["oldText": "", "newText": "X"]]],
            ["path": "edit.txt", "edits": [["oldText": "one", "newText": "one"]]],
            ["path": "edit.txt", "edits": .array([])],
            ["path": "edit.txt", "edits": [["oldText": "one", "newText": "new"], ["oldText": "new", "newText": "X"]]]]
        let messages = ["overlap", "Could not find the exact text", "Found 3 occurrences", "oldText must not be empty", "No changes made", "at least one replacement", "Could not find edits[1]"]
        let tool = try createEditTool(), api = try toolTestApi(env: env)
        for (index, input) in inputs.enumerated() {
            do { _ = try await tool.execute(input, api, .background); Issue.record("Expected edit failure") }
            catch { #expect(String(describing: error).contains(messages[index])) }
            #expect(Array(try await env.readBinaryFile("edit.txt", context: .background).get()) == Array(original.utf8))
        }
    }

    @Test func symlinkAndBOMCRLFPreserveUnchangedBytes() async throws {
        let directory = try toolTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let env = LocalExecutionEnv(cwd: directory.path)
        let original = "\u{FEFF}keep “quote”  \r\none—two\r\nkeep ﬃ \t\r\n"
        try await env.writeFile("target.txt", content: .text(original), context: .background).get()
        try FileManager.default.createSymbolicLink(atPath: directory.appendingPathComponent("link.txt").path, withDestinationPath: "target.txt")
        _ = try await createEditTool().execute(["path": "link.txt", "edits": [["oldText": "one-two", "newText": "ONE\nTWO"]]], toolTestApi(env: env), .background)
        #expect(try await env.readBinaryFile("target.txt", context: .background).get() == Array("\u{FEFF}keep “quote”  \r\nONE\r\nTWO\r\nkeep ﬃ \t\r\n".utf8))
    }

    @Test func abortedEditKeepsTheQueueUntilWriteSettles() async throws {
        let directory = try toolTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let base = LocalExecutionEnv(cwd: directory.path)
        try await base.writeFile("file.txt", content: .text("alpha\nbeta\n"), context: .background).get()
        let started = ToolTestGate(), release = ToolTestGate(), secondStarted = Mutex(false)
        let env = ToolFixtureEnv(base: base, writeHook: { path, content, _ in
            if case .text("ALPHA\nbeta\n") = content { await started.release(); await release.wait() }
            if case .text("ALPHA\nBETA\n") = content { secondStarted.withLock { $0 = true } }
            return await base.writeFile(path, content: content, context: .background)
        })
        let controller = AbortController(), tool = try createEditTool(), api = try toolTestApi(env: env)
        let first = Task { try await tool.execute(["path": "file.txt", "edits": [["oldText": "alpha", "newText": "ALPHA"]]], api, .background.withAbortSignal(controller.signal)) }
        await started.wait()
        controller.abort()
        let second = Task { try await tool.execute(["path": "file.txt", "edits": [["oldText": "beta", "newText": "BETA"]]], api, .background) }
        try await Task.sleep(for: .milliseconds(20))
        #expect(!secondStarted.withLock { $0 })
        await release.release()
        do { _ = try await first.value; Issue.record("Expected aborted edit") }
        catch { #expect(String(describing: error) == "Operation aborted") }
        _ = try await second.value
        #expect(try await base.readTextFile("file.txt", context: .background).get() == "ALPHA\nBETA\n")
    }

    @Test func noEnvironmentAndInvalidPathsReportErrors() async throws {
        let tool = try createEditTool()
        await #expect(throws: NoExecutionEnvironmentError.self) {
            _ = try await tool.execute(["path": "x", "edits": [["oldText": "a", "newText": "b"]]], toolTestApi(), .background)
        }
        let directory = try toolTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let env = LocalExecutionEnv(cwd: directory.path), api = try toolTestApi(env: env)
        for (path, expected) in [("missing.txt", "Error code: not_found."), (".", "Path is not a file.")] {
            do { _ = try await tool.execute(["path": .string(path), "edits": [["oldText": "a", "newText": "b"]]], api, .background); Issue.record("Expected path failure") }
            catch { #expect(String(describing: error).contains(expected)) }
        }
    }
}
