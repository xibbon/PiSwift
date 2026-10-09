import Foundation
import Synchronization
import Testing
import PiSwiftAI
import PiSwiftChord
@testable import PiSwiftDurable
import PiSwiftDurableTesting

func toolCalls(_ calls: [(String, JSONObject, String)]) throws -> AssistantMessage {
    var message = chatAssistant("", reason: .toolUse)
    message.content = try calls.map { name, args, id in
        let object = try foundationJSON(from: .object(args)) as! [String: Any]
        return .toolCall(ToolCall(id: id, name: name, arguments: object.mapValues(AnyCodable.init)))
    }
    return message
}
func harnessTestTool(_ name: String = "echo", limits: OutputLimitOverrides? = nil,
                     mode: ToolExecutionMode? = nil,
                     prepare: (@Sendable (JSONValue) throws -> JSONValue)? = nil,
                     execute: @escaping @Sendable (JSONValue, ToolExecutionApi, ChordContext) async throws -> ToolExecutionResult = { _, _, _ in ToolExecutionResult(content: []) }) throws -> ToolRegistration {
    try ToolRegistration(name: name, description: "The \(name) tool", parameters: ["type": "object", "properties": ["text": ["type": "string"]]],
        executionMode: mode, prepareArguments: prepare, outputLimits: limits, execute: execute)
}
func installHarnessTool(_ tool: ToolRegistration, setup: HarnessChatSetup) throws {
    try setup.registry.install(Extension(name: "tool:\(tool.name)", tools: [tool]))
}
func harnessToolResults(_ entries: [EntryRecord]) throws -> [ToolResultMessage] {
    try entries.filter { $0.kind == toolResultEntry.kind }.flatMap { entry in
        try entry.messages()?.compactMap { if case .toolResult(let value) = $0 { value } else { nil } } ?? []
    }
}
func harnessToolText(_ value: ToolResultMessage) -> String {
    value.content.map { if case .text(let text) = $0 { text.text } else { "[image]" } }.joined(separator: "|")
}
func runHarnessTools(_ setup: HarnessChatSetup, calls: [(String, JSONObject, String)] = [("echo", [:], "c1")]) async throws -> (OpenChatResult, [EntryRecord]) {
    setup.models.setResponses([.message(try toolCalls(calls)), .message(chatAssistant("done"))])
    let opened = try await openChat(setup: setup)
    let settled = try await opened.root.submit(.input(content: .text("go")), context: .background).wait(context: .background)
    #expect(settled.status == "done")
    return (opened, try await allEntries(opened.root))
}

func harnessToolAwaitAbort(_ context: ChordContext) async throws {
    let signal = try #require(context.abortSignal), gate = HarnessChatSignal()
    let registration = signal.addAbortListener { _ in gate.signal() }
    defer { signal.removeAbortListener(registration) }
    if signal.aborted { gate.signal() }
    await gate.wait()
    try signal.throwIfAborted()
}

func harnessToolDetails(_ result: ToolResultMessage) -> JSONValue? {
    result.details.flatMap { try? durableJSON(fromFoundation: $0.value) }
}

/// No host files or commands are used. The fixture supplies only a working directory.
final class HarnessToolEnvironment: ExecutionEnv, Sendable {
    let id = "test.tool-environment"
    private let directory: Synchronization.Mutex<String>
    init(cwd: String) { directory = .init(cwd) }
    var cwd: String { get { directory.withLock { $0 } } set { directory.withLock { $0 = newValue } } }
    private func unavailable<T>() -> Result<T, FileError> { .failure(FileError(.notSupported, message: "Fixture operation is not available")) }
    func absolutePath(_ path: String, context: ChordContext) async -> Result<String, FileError> { .success(path) }
    func joinPath(_ parts: [String], context: ChordContext) async -> Result<String, FileError> { .success(parts.joined(separator: "/")) }
    func readTextFile(_ path: String, context: ChordContext) async -> Result<String, FileError> { unavailable() }
    func openTextLineReader(_ path: String, context: ChordContext) async -> Result<any TextLineReader, FileError> { unavailable() }
    func readTextLines(_ path: String, options: ReadTextLinesOptions?, context: ChordContext) async -> Result<[String], FileError> { unavailable() }
    func readBinaryFile(_ path: String, context: ChordContext) async -> Result<[UInt8], FileError> { unavailable() }
    func openBinaryReader(_ path: String, options: OpenBinaryReaderOptions?, context: ChordContext) async -> Result<any BinaryReader, FileError> { unavailable() }
    func writeFile(_ path: String, content: FileContent, context: ChordContext) async -> Result<Void, FileError> { unavailable() }
    func appendFile(_ path: String, content: FileContent, context: ChordContext) async -> Result<Void, FileError> { unavailable() }
    func truncateFile(_ path: String, size: Int64, context: ChordContext) async -> Result<Void, FileError> { unavailable() }
    func flushFile(_ path: String, context: ChordContext) async -> Result<Void, FileError> { unavailable() }
    func renameFile(_ sourcePath: String, destinationPath: String, context: ChordContext) async -> Result<Void, FileError> { unavailable() }
    func fileInfo(_ path: String, context: ChordContext) async -> Result<FileInfo, FileError> { unavailable() }
    func listDir(_ path: String, context: ChordContext) async -> Result<[FileInfo], FileError> { unavailable() }
    func openDirReader(_ path: String, context: ChordContext) async -> Result<any DirReader, FileError> { unavailable() }
    func watch(_ targets: [WatchTarget], onChange: @escaping @Sendable (WatchChange) -> Void, context: ChordContext) async -> Result<any FileWatcher, FileError> { unavailable() }
    func canonicalPath(_ path: String, context: ChordContext) async -> Result<String, FileError> { unavailable() }
    func exists(_ path: String, context: ChordContext) async -> Result<Bool, FileError> { unavailable() }
    func createDir(_ path: String, options: CreateDirOptions?, context: ChordContext) async -> Result<Void, FileError> { unavailable() }
    func remove(_ path: String, options: RemoveOptions?, context: ChordContext) async -> Result<Void, FileError> { unavailable() }
    func createTempDir(prefix: String?, context: ChordContext) async -> Result<String, FileError> { unavailable() }
    func createTempFile(options: CreateTempFileOptions?, context: ChordContext) async -> Result<String, FileError> { unavailable() }
    func cleanup(context: ChordContext) async {}
    func exec(_ command: ShellCommand, options: ShellExecOptions?, context: ChordContext) async -> Result<ShellExecResult, ExecutionError> { .failure(.init(.shellUnavailable, message: "Fixture has no shell")) }
}
