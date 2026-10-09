import Foundation
import Synchronization
import Testing
import PiSwiftAI
import PiSwiftChord
@testable import PiSwiftDurable

/// A local environment with deterministic command and write hooks.
struct ToolFixtureEnv: ExecutionEnv {
    let base: LocalExecutionEnv
    let id: String
    var writeHook: (@Sendable (String, FileContent, ChordContext) async -> Result<Void, FileError>)?
    var execHook: (@Sendable (ShellCommand, ShellExecOptions?, ChordContext) async -> Result<ShellExecResult, ExecutionError>)?
    var slowRead = false
    var absolutePathHook: (@Sendable (String) -> Result<String, FileError>)?
    var canonicalPathHook: (@Sendable (String) -> Result<String, FileError>)?
    var joinPathHook: (@Sendable ([String]) -> Result<String, FileError>)?
    var cwd: String { get { base.cwd } nonmutating set { base.cwd = newValue } }
    init(base: LocalExecutionEnv, id: String = "local",
         writeHook: (@Sendable (String, FileContent, ChordContext) async -> Result<Void, FileError>)? = nil,
         execHook: (@Sendable (ShellCommand, ShellExecOptions?, ChordContext) async -> Result<ShellExecResult, ExecutionError>)? = nil,
         slowRead: Bool = false) {
        self.base = base; self.id = id; self.writeHook = writeHook; self.execHook = execHook; self.slowRead = slowRead
    }
    func absolutePath(_ path: String, context: ChordContext) async -> Result<String, FileError> {
        if let absolutePathHook { return absolutePathHook(path) }
        return await base.absolutePath(path, context: context)
    }
    func joinPath(_ parts: [String], context: ChordContext) async -> Result<String, FileError> {
        if let joinPathHook { return joinPathHook(parts) }
        return await base.joinPath(parts, context: context)
    }
    func readTextFile(_ path: String, context: ChordContext) async -> Result<String, FileError> { if slowRead { try? await Task.sleep(for: .milliseconds(20)) }; return await base.readTextFile(path, context: context) }
    func openTextLineReader(_ path: String, context: ChordContext) async -> Result<any TextLineReader, FileError> { return await base.openTextLineReader(path, context: context) }
    func readTextLines(_ path: String, options: ReadTextLinesOptions?, context: ChordContext) async -> Result<[String], FileError> { return await base.readTextLines(path, options: options, context: context) }
    func readBinaryFile(_ path: String, context: ChordContext) async -> Result<[UInt8], FileError> { return await base.readBinaryFile(path, context: context) }
    func openBinaryReader(_ path: String, options: OpenBinaryReaderOptions?, context: ChordContext) async -> Result<any BinaryReader, FileError> { return await base.openBinaryReader(path, options: options, context: context) }
    func writeFile(_ path: String, content: FileContent, context: ChordContext) async -> Result<Void, FileError> { if let writeHook { return await writeHook(path, content, context) }; return await base.writeFile(path, content: content, context: context) }
    func appendFile(_ path: String, content: FileContent, context: ChordContext) async -> Result<Void, FileError> { return await base.appendFile(path, content: content, context: context) }
    func truncateFile(_ path: String, size: Int64, context: ChordContext) async -> Result<Void, FileError> { return await base.truncateFile(path, size: size, context: context) }
    func flushFile(_ path: String, context: ChordContext) async -> Result<Void, FileError> { return await base.flushFile(path, context: context) }
    func renameFile(_ sourcePath: String, destinationPath: String, context: ChordContext) async -> Result<Void, FileError> { return await base.renameFile(sourcePath, destinationPath: destinationPath, context: context) }
    func fileInfo(_ path: String, context: ChordContext) async -> Result<FileInfo, FileError> { return await base.fileInfo(path, context: context) }
    func listDir(_ path: String, context: ChordContext) async -> Result<[FileInfo], FileError> { return await base.listDir(path, context: context) }
    func openDirReader(_ path: String, context: ChordContext) async -> Result<any DirReader, FileError> { return await base.openDirReader(path, context: context) }
    func watch(_ targets: [WatchTarget], onChange: @escaping @Sendable (WatchChange) -> Void, context: ChordContext) async -> Result<any FileWatcher, FileError> { return await base.watch(targets, onChange: onChange, context: context) }
    func canonicalPath(_ path: String, context: ChordContext) async -> Result<String, FileError> {
        if let canonicalPathHook { return canonicalPathHook(path) }
        return await base.canonicalPath(path, context: context)
    }
    func exists(_ path: String, context: ChordContext) async -> Result<Bool, FileError> { return await base.exists(path, context: context) }
    func createDir(_ path: String, options: CreateDirOptions?, context: ChordContext) async -> Result<Void, FileError> { return await base.createDir(path, options: options, context: context) }
    func remove(_ path: String, options: RemoveOptions?, context: ChordContext) async -> Result<Void, FileError> { return await base.remove(path, options: options, context: context) }
    func createTempDir(prefix: String?, context: ChordContext) async -> Result<String, FileError> { return await base.createTempDir(prefix: prefix, context: context) }
    func createTempFile(options: CreateTempFileOptions?, context: ChordContext) async -> Result<String, FileError> { return await base.createTempFile(options: options, context: context) }
    func cleanup(context: ChordContext) async { return await base.cleanup(context: context) }
    func exec(_ command: ShellCommand, options: ShellExecOptions?, context: ChordContext) async -> Result<ShellExecResult, ExecutionError> {
        if let execHook { return await execHook(command, options, context) }
        return await base.exec(command, options: options, context: context)
    }
}

actor ToolTestGate {
    private var open = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if open { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func release() {
        open = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }
}

@Suite("Durable tool write and bash v1.1.0")
struct ToolWriteBashTests {
    @Test func pathPrefixPreservesAnInitialCombiningMark() async throws {
        var fixture = ToolFixtureEnv(base: LocalExecutionEnv())
        fixture.absolutePathHook = { .success($0) }
        let resolved = try await resolveToolPath(env: fixture, path: "@\u{0301}file", context: .background)
        #expect(Array(resolved.utf8) == Array("\u{0301}file".utf8))
    }

    @Test func writeCreatesParentsAndOverwrites() async throws {
        let directory = try toolTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let env = LocalExecutionEnv(cwd: directory.path)
        let tool = try createWriteTool()
        let api = try toolTestApi(env: env)
        let first = try await tool.execute(["path": "@nested/dir/file.txt", "content": "hello"], api, .background)
        #expect(toolResultText(first) == "Successfully wrote to @nested/dir/file.txt")
        #expect(try await env.readTextFile("nested/dir/file.txt", context: .background).get() == "hello")
        _ = try await tool.execute(["path": "nested/dir/file.txt", "content": "next"], api, .background)
        #expect(try await env.readTextFile("nested/dir/file.txt", context: .background).get() == "next")
    }

    @Test func noEnvironmentAndExtensionFactories() async throws {
        let extensionValue = try CodingTools
        #expect(extensionValue.name == "coding-tools")
        #expect(extensionValue.tools.map(\.name) == ["read", "write", "edit", "bash"])
        let api = try toolTestApi()
        await #expect(throws: NoExecutionEnvironmentError.self) {
            _ = try await createWriteTool().execute(["path": "x", "content": "x"], api, .background)
        }
        await #expect(throws: NoExecutionEnvironmentError.self) {
            _ = try await createBashTool().execute(["command": ":"], api, .background)
        }
    }

    @Test func forwardsWindowSkippedAndSpillLimits() async throws {
        let window = ShellOutputWindow(maxBytes: 4, maxLines: 1, minIntervalMs: 100, bytesPerSecond: 1024)
        let skipped = ShellOutputSkip(bytes: 6, newlines: 2, endsWithNewline: true)
        let env = ToolFixtureEnv(base: LocalExecutionEnv(), execHook: { command, options, context in
            guard case .shell("anything") = command else { Issue.record("Wrong shell command"); return .success(.init(exitCode: 0)) }
            #expect(options?.window == window)
            #expect(options?.spill?.afterBytes == defaultMaxBytes)
            #expect(options?.spill?.afterLines == defaultMaxLines)
            #expect(options?.timeout == nil)
            do { try options?.onOutput?("tail\n", context, .init(stream: .stdout, skipped: skipped)) }
            catch { return .failure(.init(.callbackError, message: String(describing: error))) }
            return .success(.init(exitCode: 0))
        })
        let reports = ToolTestReports()
        let tool = try createBashTool()
        #expect(tool.outputLimits?.retain == .tail)
        let result = try await tool.execute(["command": "anything"], reports.api(env: env, outputWindow: window), .background)
        #expect(result.content == nil)
        #expect(reports.text == "tail\n")
        #expect(reports.skips == [skipped])
    }

    @Test func timeoutSpillIsReportedBeforeFailure() async throws {
        let directory = try toolTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let base = LocalExecutionEnv(cwd: directory.path)
        let output = (1...2001).map { "line-\($0)\n" }.joined()
        let path = directory.appendingPathComponent("timeout.log").path
        let env = ToolFixtureEnv(base: base, execHook: { _, options, context in
            #expect(options?.timeout == .seconds(0.05))
            do {
                try await base.writeFile(path, content: .text(output), context: context).get()
                try options?.onOutput?(output, context, .init(stream: .stdout))
            } catch { return .failure(.init(.unknown, message: String(describing: error))) }
            return .failure(.init(.timeout, message: "timeout", spillPath: path))
        })
        let reports = ToolTestReports()
        do {
            _ = try await createBashTool().execute(["command": "emit", "timeout": 0.05], reports.api(env: env), .background)
            Issue.record("Expected timeout")
        } catch { #expect(String(describing: error) == "Command timed out after 0.05 seconds") }
        #expect(reports.text == output)
        #expect(reports.diagnostics == [.init(severity: .info, message: "Full output: \(path)", code: "full_output")])
        #expect(try await base.readTextFile(path, context: .background).get() == output)
    }

    @Test func validatesTimeoutBeforeConversion() throws {
        for value in [0.0, -1.0, Double.nan, Double.infinity, -Double.infinity] {
            do { _ = try bashTimeout(value); Issue.record("Expected invalid timeout") }
            catch { #expect(String(describing: error) == "Invalid timeout: must be a finite number of seconds") }
        }
        #expect(try bashTimeout(nil) == nil)
        #expect(try bashTimeout(0.01) == .seconds(0.01))
        #expect(try bashTimeout(2_147_483.647) == .seconds(2_147_483.647))
        do { _ = try bashTimeout(2_147_483.648); Issue.record("Expected excessive timeout error") }
        catch { #expect(String(describing: error) == "Invalid timeout: maximum is 2147483.647 seconds") }
    }

    @Test func timeoutMessagesUseJavaScriptNumberText() async throws {
        for (seconds, expected) in [(1.0, "1"), (1e-7, "1e-7"), (1e-6, "0.000001")] {
            let env = ToolFixtureEnv(base: LocalExecutionEnv(), execHook: { _, options, _ in
                #expect(options?.timeout == .seconds(seconds))
                return .failure(.init(.timeout, message: "timeout"))
            })
            do {
                _ = try await createBashTool().execute(["command": ":", "timeout": .number(seconds)], toolTestApi(env: env), .background)
                Issue.record("Expected timeout")
            } catch { #expect(String(describing: error) == "Command timed out after \(expected) seconds") }
        }
    }

    @Test func shellUnavailableAndAbortRemainOrdinaryErrors() async throws {
        let reports = ToolTestReports()
        let tool = try createBashTool()
        for code in [ExecutionErrorCode.shellUnavailable, .aborted] {
            let env = ToolFixtureEnv(base: LocalExecutionEnv(), execHook: { _, _, _ in .failure(.init(code, message: "unavailable")) })
            do {
                _ = try await tool.execute(["command": ":"], reports.api(env: env), .background)
                Issue.record("Expected execution failure")
            } catch {
                #expect(String(describing: error) == (code == .aborted ? "Command aborted" : "unavailable"))
            }
        }
        let controller = AbortController()
        controller.abort()
        let env = ToolFixtureEnv(base: LocalExecutionEnv(), execHook: { _, _, _ in .failure(.init(.aborted, message: "original abort")) })
        do {
            _ = try await tool.execute(["command": ":"], reports.api(env: env), .background.withAbortSignal(controller.signal))
            Issue.record("Expected abort")
        } catch let error as ExecutionError { #expect(error.message == "original abort") }
    }

    #if os(macOS)
    @Test func streamsCombinedOutputAndThrowsAfterOutput() async throws {
        let env = LocalExecutionEnv()
        let reports = ToolTestReports()
        let tool = try createBashTool()
        let result = try await tool.execute(["command": "printf out; printf err >&2"], reports.api(env: env), .background)
        #expect(result.content == nil)
        #expect(reports.text.contains("out"))
        #expect(reports.text.contains("err"))
        let failure = ToolTestReports()
        do {
            _ = try await tool.execute(["command": "printf failed; exit 7"], failure.api(env: env), .background)
            Issue.record("Expected nonzero exit")
        } catch { #expect(String(describing: error) == "Command exited with code 7") }
        #expect(failure.text == "failed")
        do {
            _ = try await tool.execute(["command": "sleep 2", "timeout": 0.01], reports.api(env: env), .background)
            Issue.record("Expected timeout")
        } catch { #expect(String(describing: error) == "Command timed out after 0.01 seconds") }
    }

    @Test func preparesEachCallWithPrefixDirectoryAndExplicitEnvironment() async throws {
        let directory = try toolTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let base = LocalExecutionEnv(cwd: directory.path, shellEnv: ["PI_INHERITED": "inherited"])
        let workspace = directory.appendingPathComponent("workspace").path
        try await base.createDir(workspace, options: nil, context: .background).get()
        let controller = AbortController()
        let context = ChordContext.background.withAbortSignal(controller.signal)
        let tool = try createBashTool(options: .init(commandPrefix: "prefix=ready", prepare: { execution, api, callContext in
            #expect(api.env?.id == "local")
            #expect(callContext.abortSignal === controller.signal)
            #expect(execution.env.isEmpty)
            #expect(execution.inheritEnv)
            var execution = execution
            execution.cwd = workspace
            execution.env = ["PI_EXPLICIT": "explicit"]
            execution.inheritEnv = false
            execution.command += "\n: > prepared-cwd\nprintf '%s:%s:%s:%s' \"$prefix\" \"${PI_INHERITED-}\" \"$PI_EXPLICIT\" \"$PWD\""
            return execution
        }))
        for _ in 0..<2 {
            let reports = ToolTestReports()
            _ = try await tool.execute(["command": ":"], reports.api(env: base), context)
            let canonical = try await base.canonicalPath(workspace, context: .background).get()
            #expect(reports.text == "ready::explicit:\(canonical)")
        }
        #expect(try await base.exists(workspace + "/prepared-cwd", context: .background).get())
        let reports = ToolTestReports()
        _ = try await createBashTool(options: .init(commandPrefix: "value=hello")).execute(
            ["command": "printf $value"], reports.api(env: base), .background)
        #expect(reports.text == "hello")
    }

    @Test func streamsEveryByteAndSpillsOnlyBeyondLimits() async throws {
        let directory = try toolTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let env = LocalExecutionEnv(cwd: directory.path)
        let reports = ToolTestReports()
        _ = try await createBashTool().execute(
            ["command": "i=1; while [ $i -le 3000 ]; do echo line-$i; i=$((i + 1)); done"], reports.api(env: env), .background)
        let expected = (1...3000).map { "line-\($0)\n" }.joined()
        #expect(reports.text == expected)
        let diagnostic = try #require(reports.diagnostics.first)
        #expect(diagnostic.code == "full_output")
        let path = String(diagnostic.message.dropFirst("Full output: ".count))
        defer { try? FileManager.default.removeItem(atPath: path) }
        #expect(try await env.readTextFile(path, context: .background).get() == expected)
        let small = ToolTestReports()
        _ = try await createBashTool().execute(["command": "printf small"], small.api(env: env), .background)
        #expect(small.text == "small")
        #expect(small.diagnostics.isEmpty)
    }
    #endif
}
