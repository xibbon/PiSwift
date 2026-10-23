import Foundation
import PiSwiftAI
import PiSwiftChord

/// The saved call and context consumed by the built-in tool task.
public enum ToolTaskInput: Codable, Sendable, Equatable {
    /// A call from a saved assistant message.
    case model(assistant: EntryID, callId: String)
    /// A call made by a running tool, with a stable caller key.
    case nested(parent: TaskID, parentCallId: String, key: String, call: ToolCall, progress: Bool? = nil)

    /// Creates a model-issued call.
    public init(assistant: EntryID, callId: String) { self = .model(assistant: assistant, callId: callId) }
    /// Decodes a tagged v2 input. Only the migration accepts untagged v1 input.
    public init(from decoder: any Decoder) throws {
        let object = try JSONObject(from: decoder)
        switch object["kind"] {
        case .string("model"):
            self = .model(assistant: try recordRequired(object, "assistant"), callId: try recordRequired(object, "callId"))
        case .string("nested"):
            let progress: Bool? = try recordOptional(object, "progress")
            guard progress != true else { throw TaskDefinitionError("Nested progress must be false or absent") }
            self = .nested(parent: try recordRequired(object, "parent"), parentCallId: try recordRequired(object, "parentCallId"),
                key: try recordRequired(object, "key"), call: try nestedCallFromValue(recordRequired(object, "call")), progress: progress)
        default: throw TaskDefinitionError("Invalid tool task input kind")
        }
    }
    /// Writes the model tag and saved call identity.
    public func encode(to encoder: any Encoder) throws {
        switch self {
        case .model(let assistant, let callId):
            let object: JSONObject = ["kind": "model", "assistant": try JSONValue(encoding: assistant), "callId": .string(callId)]
            try object.encode(to: encoder)
        case .nested(let parent, let parentCallId, let key, let call, let progress):
            var object: JSONObject = ["kind": "nested", "parent": try JSONValue(encoding: parent),
                "parentCallId": .string(parentCallId), "key": .string(key), "call": try nestedCallValue(call)]
            if progress == false { object["progress"] = false }
            try object.encode(to: encoder)
        }
    }
    public static func == (a: Self, b: Self) -> Bool {
        do { return try JSONValue(encoding: a) == JSONValue(encoding: b) }
        catch { return false }
    }
}
/// The persisted prepare or execute phase of a tool task.
public struct ToolTaskCheckpoint: TaskCheckpoint {
    /// The persisted phase used to resume this built-in task.
    public enum Phase: String, Codable, Sendable {
        /// Executes the prepared tool or model request.
        case call
        /// Runs the prepared tool call.
        case execute
    }
    /// The saved prepare or execute phase.
    public var phase: Phase
    /// Replacement JSON arguments for the tool call.
    public var arguments: JSONObject?
    /// Whether this tool can execute again after a restart.
    public var replay: ToolReplay?
    /// Selects the saved tool phase, prepared arguments, and replay policy.
    public init(phase: Phase, arguments: JSONObject? = nil, replay: ToolReplay? = nil) {
        self.phase = phase; self.arguments = arguments; self.replay = replay
    }
}
/// The tool result entry produced by a completed tool task.
public enum ToolTaskResult: Codable, Sendable, Equatable {
    /// The model-visible transcript result and optional run control.
    case model(entryId: EntryID, control: ToolControl? = nil)
    /// The result is stored with the caller, outside this receipt.
    case nested
    /// Creates a tagged model result.
    public init(entryId: EntryID, control: ToolControl? = nil) { self = .model(entryId: entryId, control: control) }
    /// Also accepts an untagged result held by a completing v1 task.
    public init(from decoder: any Decoder) throws {
        let object = try JSONObject(from: decoder)
        if object["kind"] == .string("nested") { self = .nested; return }
        guard object["kind"] == nil || object["kind"] == .string("model") else { throw TaskDefinitionError("Invalid tool task result kind") }
        self = .model(entryId: try recordRequired(object, "entryId"), control: try recordOptional(object, "control"))
    }
    /// New results always contain the model tag.
    public func encode(to encoder: any Encoder) throws {
        switch self {
        case .nested: try JSONObject([("kind", "nested")]).encode(to: encoder)
        case .model(let entryId, let control):
            var object: JSONObject = ["kind": "model", "entryId": try JSONValue(encoding: entryId)]
            try recordSetOptional(&object, "control", control)
            try object.encode(to: encoder)
        }
    }
}
/// The built-in tool definition installed in every registry.
public let toolTask = TaskDefinition<ToolTaskInput, ToolTaskCheckpoint, ToolTaskResult, ToolHooks>(
    name: "pi.tool", version: 2, initial: { _ in ToolTaskCheckpoint(phase: .call) },
    phase: { task, runtime, context in try await runToolTask(task, runtime, context) },
    abort: { task, runtime, context in
        let call = try await readToolCall(runtime, task.input, context)
        let code: String, message: String
        if task.record.abortReason != .restart { code = "aborted"; message = "Tool \(call.name) was aborted" }
        else if task.checkpoint.phase == .execute { code = "interrupted"; message = "Tool \(call.name) was interrupted by a restart and may have partially run" }
        else { code = "abandoned"; message = "Tool \(call.name) was not started: its caller ended with a restart" }
        try await settleTool(runtime, call, .aborted, context: context) { slot in
            toolResultFromSlot(slot, code: code, message: message)
        }
    },
    migrate: { input, checkpoint, _ in
        guard case .object(var object) = input else { throw TaskDefinitionError("Tool task input must be an object") }
        if object["kind"] == nil { object["kind"] = "model" }
        return (try JSONValue.object(object).decode(ToolTaskInput.self), try checkpoint.decode(ToolTaskCheckpoint.self))
    }
)
internal enum ToolEnding { case completed, failed(String), aborted }
private func readToolCall(_ runtime: TaskRuntime, _ input: ToolTaskInput, _ context: ChordContext) async throws -> ToolHookCall {
    switch input {
    case .nested(let parent, let parentCallId, _, let call, _):
        return ToolHookCall(call, parent: ToolHookParent(taskId: parent, callId: parentCallId))
    case .model(let assistant, let callId):
        if let entry = try await runtime.entry(assistantEntry, id: assistant, context: context),
           case .assistant(let message) = try entry.record.messages()?.first {
            for block in message.content {
                if case .toolCall(let call) = block, harnessNamesEqual(call.id, callId) { return ToolHookCall(call) }
            }
        }
        throw TaskDefinitionError("Entry \(assistant.rawValue) has no tool call \(callId)")
    }
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
    let agent = try await runtime.agent(context: context)
    let choices: [ToolRegistration]
    switch task.input { case .model: choices = agent.tools; case .nested: choices = agent.callable }
    let tool = choices.first { harnessNamesEqual($0.name, call.name) }
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
        args = try checkedToolArguments(tool, call.call, tool.prepareArguments?(original) ?? original)
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
    do { args = try checkedToolArguments(tool, call.call, .object(args)) }
    catch {
        return try await settleTool(runtime, call, .completed, context: context) { _ in harnessToolError(code: "invalid_arguments", message: toolErrorText(error)) }
    }
    let final = args
    try await runtime.commit({ tx, _ in
        if let slot = try toolSlot(live: await tx.doc(LiveDoc, conversationId: runtime.conversationId), taskId: runtime.taskId) {
            try slot.set("status", .string("running"))
            if case .nested(_, _, _, let original, _) = task.input,
               try !nestedJSONEqual(durableJSON(fromFoundation: original.arguments.mapValues(\.value)), .object(final)) {
                try slot.set("arguments", .object(final))
            }
        }
        return try toolTask.running(ToolTaskCheckpoint(phase: .execute, arguments: final, replay: tool.replay ?? .unsafe))
    }, context: context)
    try await executeTool(runtime, call, tool, final, context)
}
internal func harnessToolError(code: String, message: String) -> ToolExecutionResult {
    ToolExecutionResult(output: [], isError: true, diagnostics: [ToolDiagnostic(severity: .error, message: message, code: code)])
}
internal func toolTruncated(_ bytes: Int, _ lines: Int, retain: OutputRetention? = nil) -> ToolDiagnostic {
    let kept = retain.map { " to its \($0 == .head ? "beginning" : "end")" } ?? ""
    return ToolDiagnostic(severity: .warn, message: "Output truncated\(kept): \(lines) lines, \(bytes) bytes dropped", code: "truncated")
}
internal func toolResultFromSlot(_ slot: ToolSlot?, code: String, message: String) -> ToolExecutionResult {
    var diagnostics = slot?.diagnostics ?? []
    if let bytes = slot?.droppedBytes, bytes > 0 { diagnostics.append(toolTruncated(bytes, slot?.droppedLines ?? 0)) }
    diagnostics.append(ToolDiagnostic(severity: .error, message: message, code: code))
    return ToolExecutionResult(output: slot?.output.flatMap { $0.isEmpty ? nil : [.text(TextContent(text: $0))] } ?? [],
                               isError: true, details: slot?.details, diagnostics: diagnostics)
}
internal func settleTool(_ runtime: TaskRuntime, _ call: ToolHookCall, _ ending: ToolEnding,
                         durationMs: Int? = nil, context: ChordContext,
                         build: (ToolSlot?) throws -> ToolExecutionResult) async throws {
    let children = try await runtime.ownedTasks(context: context).filter { $0.kind == "pi.tool" && $0.input["kind"] == "nested" }
    let madeNested = try await runtime.memo("pi.tool.madeNestedCalls", context: context) == true
    try await withThrowingTaskGroup(of: Void.self) { group in
        for child in children { group.addTask { try await runtime.abortOwned(child.id, context: context) } }
        try await group.waitForAll()
    }
    try await runtime.commit({ tx, current in
        let live = try await tx.doc(LiveDoc, conversationId: runtime.conversationId)
        let slot = try toolSlot(live: live, taskId: runtime.taskId)
        let result = try build(slot.map { try $0.snapshot().decode(ToolSlot.self) })
        let settled: ToolTaskResult
        switch try current.input.decode(ToolTaskInput.self) {
        case .nested(let parent, _, let key, _, _):
            let nested = NestedToolExecutionResult(taskId: runtime.taskId, structuredOutput: result.structuredOutput,
                isError: result.isError ?? false, details: result.details, diagnostics: result.diagnostics ?? [], usage: result.usage, durationMs: durationMs)
            if let usage = result.usage { try await recordUsage(tx: tx, conversationId: runtime.conversationId, bucket: .tools, key: call.name, usage: usage) }
            let state = try await tx.doc(NestedCallDoc, taskId: parent, key: key, seed: nil)
            guard try state.get("taskId")?.decode(TaskID.self) == runtime.taskId else {
                throw TaskDefinitionError("Nested call \(call.id) is not in its caller's index")
            }
            try state.set("result", JSONValue(encoding: nested))
            if let slot { try finishSlot(slot: slot, entry: nil); try slot.set("summary", JSONValue(encoding: summaryOf(result: nested, output: result.output ?? []))) }
            settled = .nested
        case .model:
            let entry = try await appendToolResult(tx: tx, conversationId: runtime.conversationId, call: call.call,
                result: result, timestamp: runtime.now(), durationMs: durationMs)
            if let slot { try finishSlot(slot: slot, entry: entry.id) }
            settled = .model(entryId: entry.id, control: { if case .completed = ending { return result.control }; return nil }())
        }
        if madeNested { try removeNestedSlots(live: live, taskId: runtime.taskId) }
        let value = try JSONValue(encoding: settled)
        switch ending {
        case .completed: return .terminal(outcome: .completed(result: value))
        case .aborted: return .terminal(outcome: .aborted(result: value))
        case .failed(let message): return .terminal(outcome: .failed(error: TaskOutcomeError(message: message), result: value))
        }
    }, context: context)
}
internal func appendToolResult(tx: Transaction, conversationId: ConversationID, call: ToolCall,
                             result: ToolExecutionResult, timestamp: Int64, durationMs: Int? = nil) async throws -> EntryRecord {
    let diagnostics = result.diagnostics ?? []
    var content = result.output ?? []
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
