import Foundation
import Synchronization
import PiSwiftAI
import PiSwiftChord
import PiSwiftDurable
import PiSwiftDurableTesting

func toolTestApi(env: (any ExecutionEnv)? = nil,
                 output: @escaping @Sendable (ToolOutputChunk, ShellOutputSkip?) throws -> Void = { _, _ in },
                 retainedOutput: @escaping @Sendable () throws -> RetainedToolOutput = { .init(text: "", truncated: false) },
                 diagnostic: @escaping @Sendable (ToolDiagnostic) throws -> Void = { _ in },
                 outputWindow: ShellOutputWindow? = nil) throws -> ToolExecutionApi {
    ToolExecutionApi(taskId: try TaskID(2), conversationId: rootConversationID, callId: "tool-test",
        registry: .init(), models: FakeDurableModels(), env: env, outputWindow: outputWindow,
        agent: { _ in Agent() }, output: output, retainedOutput: retainedOutput, diagnostic: diagnostic)
}

final class ToolTestReports: Sendable {
    private struct State: Sendable {
        var text = ""
        var skips: [ShellOutputSkip] = []
        var diagnostics: [ToolDiagnostic] = []
    }
    private let state = Mutex(State())
    var text: String { state.withLock { $0.text } }
    var skips: [ShellOutputSkip] { state.withLock { $0.skips } }
    var diagnostics: [ToolDiagnostic] { state.withLock { $0.diagnostics } }
    func api(env: (any ExecutionEnv)? = nil, outputWindow: ShellOutputWindow? = nil) throws -> ToolExecutionApi {
        let retained = OutputBuffer(.init(maxBytes: outputWindow?.maxBytes ?? defaultMaxBytes,
            maxLines: outputWindow?.maxLines ?? defaultMaxLines, retain: .tail))
        return try toolTestApi(env: env, output: { [self] chunk, skip in
            switch chunk {
            case .text(let text): _ = try retained.push(text, skipped: skip)
            case .bytes(let bytes): _ = try retained.push(bytes, skipped: skip)
            }
            state.withLock { value in
                switch chunk {
                case .text(let text): value.text += text
                case .bytes(let data): value.text += String(decoding: data, as: UTF8.self)
                }
                if let skip { value.skips.append(skip) }
            }
        }, retainedOutput: {
            let output = retained.snapshot()
            return .init(text: output.text, truncated: output.droppedBytes > 0)
        }, diagnostic: { [self] diagnostic in
            state.withLock { $0.diagnostics.append(diagnostic) }
        }, outputWindow: outputWindow)
    }
}

func toolTestDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("durable-tools-\(UUID())", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

func toolResultText(_ result: ToolExecutionResult) -> String {
    (result.output ?? []).compactMap { if case .text(let text) = $0 { text.text } else { nil } }.joined()
}
