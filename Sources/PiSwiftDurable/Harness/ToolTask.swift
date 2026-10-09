import Foundation
import PiSwiftAI
import PiSwiftChord

public typealias ToolTaskInput = GenerationToolInput
public struct ToolTaskCheckpoint: TaskCheckpoint {
    public enum Phase: String, Codable, Sendable { case call, execute }
    public var phase: Phase
    public var arguments: JSONObject?
    public var replay: ToolReplay?
    public init(phase: Phase, arguments: JSONObject? = nil, replay: ToolReplay? = nil) {
        self.phase = phase; self.arguments = arguments; self.replay = replay
    }
}
public struct ToolTaskResult: Codable, Sendable {
    public var entryId: EntryID
    public var control: ToolControl?
    public init(entryId: EntryID, control: ToolControl? = nil) { self.entryId = entryId; self.control = control }
}
public let toolTask = TaskDefinition<ToolTaskInput, ToolTaskCheckpoint, ToolTaskResult, ToolHooks>(
    name: "pi.tool", version: 1, initial: { _ in ToolTaskCheckpoint(phase: .call) },
    phase: { task, runtime, context in try await runToolTask(task, runtime, context) },
    abort: { task, runtime, context in
        let call = try await readToolCall(runtime, task.input, context)
        try await settleTool(runtime, call, .aborted, context: context) { slot in
            toolResultFromSlot(slot, code: "aborted", message: "Tool \(call.name) was aborted")
        }
    }
)
internal enum ToolEnding { case completed, failed(String), aborted }
private func readToolCall(_ runtime: TaskRuntime, _ input: ToolTaskInput, _ context: ChordContext) async throws -> ToolCall {
    if let entry = try await runtime.entry(assistantEntry, id: input.assistant, context: context),
       case .assistant(let message) = try entry.record.messages()?.first {
        for block in message.content {
            if case .toolCall(let call) = block, harnessNamesEqual(call.id, input.callId) { return call }
        }
    }
    throw TaskDefinitionError("Entry \(input.assistant.rawValue) has no tool call \(input.callId)")
}
private func checkedToolArguments(_ tool: ToolRegistration, _ call: ToolCall, _ value: JSONValue) throws -> JSONObject {
    guard let object = try foundationJSON(from: value) as? [String: Any] else {
        throw HarnessDefinitionError.argumentsMustBeObject(tool.name)
    }
    var candidate = call
    candidate.arguments = object.mapValues(AnyCodable.init); candidate.argumentsJSON = nil
    let checked = try validateToolArguments(tool: tool.declaration, toolCall: candidate)
    guard case .object(let arguments) = try durableJSON(fromFoundation: checked.mapValues(\.value)) else {
        throw HarnessDefinitionError.argumentsMustBeObject(tool.name)
    }
    return arguments
}
private func runToolTask(_ task: RunningTask<ToolTaskInput, ToolTaskCheckpoint>, _ runtime: TaskRuntime,
                         _ context: ChordContext) async throws {
    let call = try await readToolCall(runtime, task.input, context)
    let tool = try await runtime.agent(context: context).tools.first { harnessNamesEqual($0.name, call.name) }
    if task.checkpoint.phase == .execute {
        guard let args = task.checkpoint.arguments, let replay = task.checkpoint.replay else {
            throw TaskDefinitionError("Tool checkpoint is missing arguments or replay")
        }
        if replay == .safe, let tool, tool.replay == .safe {
            try await runtime.commit({ tx, _ in
                if let slot = try toolSlot(live: await tx.doc(LiveDoc, conversationId: runtime.conversationId), taskId: runtime.taskId) {
                    try clearProgress(slot: slot)
                }
                return nil
            }, context: context)
            return try await executeTool(runtime, call, tool, args, context)
        }
        let message = "Tool \(call.name) was interrupted and may have partially run"
        return try await settleTool(runtime, call, .failed(message), context: context) { toolResultFromSlot($0, code: "interrupted", message: message) }
    }
    guard let tool else {
        return try await settleTool(runtime, call, .completed, context: context) { _ in
            harnessToolError(code: "tool_unavailable", message: "Tool \(call.name) is not available")
        }
    }
    var args: JSONObject
    do {
        let original = try durableJSON(fromFoundation: call.arguments.mapValues(\.value))
        args = try checkedToolArguments(tool, call, tool.prepareArguments?(original) ?? original)
    } catch {
        return try await settleTool(runtime, call, .completed, context: context) { _ in harnessToolError(code: "invalid_arguments", message: toolErrorText(error)) }
    }
    var block: String?
    try await runtime.hooks.each(ToolHooks.self, context: context) { hooks in
        guard block == nil, let hook = hooks.beforeTool else { return }
        var candidate = call
        candidate.arguments = (try foundationJSON(from: .object(args)) as! [String: Any]).mapValues(AnyCodable.init)
        candidate.argumentsJSON = nil
        do {
            if let decision = try await hook(candidate, runtime.hookApi, context) {
                if let reason = decision.block { block = reason }
                else if let replacement = decision.arguments { args = replacement }
            }
        } catch {
            if runtime.signal.aborted || context.abortSignal?.aborted == true { throw error }
            block = toolErrorText(error)
        }
    }
    if let block {
        return try await settleTool(runtime, call, .completed, context: context) { _ in harnessToolError(code: "blocked", message: "Tool call blocked: \(block)") }
    }
    do { args = try checkedToolArguments(tool, call, .object(args)) }
    catch {
        return try await settleTool(runtime, call, .completed, context: context) { _ in harnessToolError(code: "invalid_arguments", message: toolErrorText(error)) }
    }
    let final = args
    try await runtime.commit({ tx, _ in
        if let slot = try toolSlot(live: await tx.doc(LiveDoc, conversationId: runtime.conversationId), taskId: runtime.taskId) {
            try slot.set("status", .string("running"))
        }
        return try toolTask.running(ToolTaskCheckpoint(phase: .execute, arguments: final, replay: tool.replay ?? .unsafe))
    }, context: context)
    try await executeTool(runtime, call, tool, final, context)
}
internal func harnessToolError(code: String, message: String) -> ToolExecutionResult {
    ToolExecutionResult(content: [], isError: true, diagnostics: [ToolDiagnostic(severity: .error, message: message, code: code)])
}
internal func toolTruncated(_ bytes: Int, _ lines: Int, retain: OutputRetention? = nil) -> ToolDiagnostic {
    let kept = retain.map { " to its \($0 == .head ? "beginning" : "end")" } ?? ""
    return ToolDiagnostic(severity: .warn, message: "Output truncated\(kept): \(lines) lines, \(bytes) bytes dropped", code: "truncated")
}
internal func toolResultFromSlot(_ slot: ToolSlot?, code: String, message: String) -> ToolExecutionResult {
    var diagnostics = slot?.diagnostics ?? []
    if let bytes = slot?.droppedBytes, bytes > 0 { diagnostics.append(toolTruncated(bytes, slot?.droppedLines ?? 0)) }
    diagnostics.append(ToolDiagnostic(severity: .error, message: message, code: code))
    return ToolExecutionResult(content: slot?.output.flatMap { $0.isEmpty ? nil : [.text(TextContent(text: $0))] } ?? [],
                               isError: true, details: slot?.details, diagnostics: diagnostics)
}
internal func settleTool(_ runtime: TaskRuntime, _ call: ToolCall, _ ending: ToolEnding,
                         durationMs: Int? = nil, context: ChordContext,
                         build: (ToolSlot?) throws -> ToolExecutionResult) async throws {
    try await runtime.commit({ tx, _ in
        let live = try await tx.doc(LiveDoc, conversationId: runtime.conversationId)
        let slot = try toolSlot(live: live, taskId: runtime.taskId)
        let result = try build(slot.map { try $0.snapshot().decode(ToolSlot.self) })
        let entry = try await appendToolResult(tx: tx, conversationId: runtime.conversationId, call: call,
                                               result: result, timestamp: runtime.now(), durationMs: durationMs)
        if let slot { try finishSlot(slot: slot, entry: entry.id) }
        let value = try JSONValue(encoding: ToolTaskResult(entryId: entry.id, control: { if case .completed = ending { return result.control }; return nil }()))
        switch ending {
        case .completed: return .terminal(outcome: .completed(result: value))
        case .aborted: return .terminal(outcome: .aborted(result: value))
        case .failed(let message): return .terminal(outcome: .failed(error: TaskOutcomeError(message: message), result: value))
        }
    }, context: context)
}
public func appendToolResult(tx: Transaction, conversationId: ConversationID, call: ToolCall,
                             result: ToolExecutionResult, timestamp: Int64, durationMs: Int? = nil) async throws -> EntryRecord {
    let diagnostics = result.diagnostics ?? []
    var content = result.content ?? []
    if !diagnostics.isEmpty {
        content.append(.text(TextContent(text: "<harness>\n" + diagnostics.map { "[\($0.severity.rawValue)] \($0.message)" }.joined(separator: "\n") + "\n</harness>")))
    }
    let message = ToolResultMessage(toolCallId: call.id, toolName: call.name, content: content,
        details: try result.details.map { AnyCodable(try foundationJSON(from: $0)) }, usage: result.usage,
        isError: result.isError ?? false, timestamp: timestamp, durationMs: durationMs)
    if let usage = result.usage { try await recordUsage(tx: tx, conversationId: conversationId, bucket: .tools, key: call.name, usage: usage) }
    return try await tx.appendEntry(conversationId, value: EntryDraft(kind: toolResultEntry.kind,
        model: EntryRecord.encodeMessages([.toolResult(message)]), data: JSONValue(encoding: ToolResultEntryData(diagnostics: diagnostics))))
}

/// Use the Swift error's message without Foundation error bridging.
internal func toolErrorText(_ error: any Error) -> String {
    if let localized = error as? any LocalizedError, let message = localized.errorDescription { return message }
    return String(describing: error)
}
