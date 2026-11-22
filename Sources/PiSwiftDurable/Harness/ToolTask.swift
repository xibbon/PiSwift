import Foundation
import PiSwiftAI
import PiSwiftChord

/// The saved call and context consumed by the built-in tool task.
public enum ToolTaskInput: Codable, Sendable, Equatable {
    /// A call from a saved assistant message.
    case model(assistant: EntryID, callId: String)
    /// A model call to a tool its request did not offer.
    case unofferedModel(assistant: EntryID, callId: String)
    /// A call made by a running tool, with a stable caller key.
    case nested(parent: TaskID, parentCallId: String, key: String, call: ToolCall, progress: Bool? = nil)

    /// Creates a model-issued call.
    public init(assistant: EntryID, callId: String) { self = .model(assistant: assistant, callId: callId) }
    /// Decodes a tagged v2 input. Only the migration accepts untagged v1 input.
    public init(from decoder: any Decoder) throws {
        let object = try JSONObject(from: decoder)
        switch object["kind"] {
        case .string("model"):
            let unoffered: Bool? = try recordOptional(object, "unoffered")
            guard unoffered != false else { throw TaskDefinitionError("Invalid unoffered tool task flag") }
            let assistant: EntryID = try recordRequired(object, "assistant")
            let callId: String = try recordRequired(object, "callId")
            self = unoffered == true ? .unofferedModel(assistant: assistant, callId: callId) : .model(assistant: assistant, callId: callId)
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
        case .unofferedModel(let assistant, let callId):
            let object: JSONObject = ["kind": "model", "assistant": try JSONValue(encoding: assistant), "callId": .string(callId), "unoffered": true]
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
        /// The tool is asleep or waiting without an active invocation.
        case parked
    }
    /// The saved prepare or execute phase.
    public var phase: Phase
    /// Replacement JSON arguments for the tool call.
    public var arguments: JSONObject?
    /// Whether this tool can execute again after a restart.
    public var replay: ToolReplay?
    /// Why a recovered execute phase resumed after a park.
    public var wake: WakeReason?
    /// Opaque tool state saved before a park or on resumed execution.
    public var checkpoint: JSONValue?
    /// Selects the saved tool phase, prepared arguments, and replay policy.
    public init(phase: Phase, arguments: JSONObject? = nil, replay: ToolReplay? = nil,
                wake: WakeReason? = nil, checkpoint: JSONValue? = nil) {
        self.phase = phase; self.arguments = arguments; self.replay = replay
        self.wake = wake; self.checkpoint = checkpoint
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
    name: "pi.tool", version: 4, initial: { _ in ToolTaskCheckpoint(phase: .call) },
    phase: { task, runtime, context in try await runToolTask(task, runtime, context) },
    abort: { task, runtime, context in
        let call = try await readToolCall(runtime, task.input, context)
        if task.checkpoint.phase == .parked ||
            (task.checkpoint.phase == .execute && task.checkpoint.wake != nil) {
            let tool = try await resolveTool(runtime, task.input, call, context)
            if let tool, let args = task.checkpoint.arguments {
                try await cancelTool(runtime, call, tool, args, checkpoint: task.checkpoint.checkpoint, context: context)
            } else {
                try runtime.report(TaskDefinitionError("Tool \(call.name) is not available: its parked call \(call.id) was not cancelled"))
            }
        }
        let code: String, message: String
        if case .unofferedModel = task.input { code = "tool_unavailable"; message = "Tool \(call.name) is not available" }
        else if task.record.abortReason != .restart { code = "aborted"; message = "Tool \(call.name) was aborted" }
        else if task.checkpoint.phase == .execute { code = "interrupted"; message = "Tool \(call.name) was interrupted by a restart and may have partially run" }
        else if task.checkpoint.phase == .parked { code = "abandoned"; message = "Tool \(call.name) was parked: its caller ended with a restart" }
        else { code = "abandoned"; message = "Tool \(call.name) was not started: its caller ended with a restart" }
        let hooks = task.record.restarts < runtime.settings.restartLimit - 1
        try await settleToolFromSlot(runtime, task.input, call, .aborted, code: code, message: message, hooks: hooks, context: context)
    },
    migrate: { input, checkpoint, fromVersion in
        guard case .object(var object) = input else { throw TaskDefinitionError("Tool task input must be an object") }
        // v1.6.0 tool.ts:161-167 tags only v1 input; v2 and v3 stay unchanged.
        if fromVersion == 1 { object["kind"] = "model" }
        return (try JSONValue.object(object).decode(ToolTaskInput.self), try checkpoint.decode(ToolTaskCheckpoint.self))
    }
)
internal enum ToolEnding { case completed, failed(String), restartLimit(String), aborted }
private func readToolCall(_ runtime: TaskRuntime, _ input: ToolTaskInput, _ context: ChordContext) async throws -> ToolHookCall {
    switch input {
    case .nested(let parent, let parentCallId, _, let call, _):
        return ToolHookCall(call, parent: ToolHookParent(taskId: parent, callId: parentCallId))
    case .model(let assistant, let callId), .unofferedModel(let assistant, let callId):
        if let entry = try await runtime.entry(assistantEntry, id: assistant, context: context),
           case .assistant(let message) = try entry.record.messages()?.first {
            for block in message.content {
                if case .toolCall(let call) = block, harnessNamesEqual(call.id, callId) { return ToolHookCall(call) }
            }
        }
        throw TaskDefinitionError("Entry \(assistant.rawValue) has no tool call \(callId)")
    }
}
private func resolveTool(_ runtime: TaskRuntime, _ input: ToolTaskInput, _ call: ToolHookCall,
                         _ context: ChordContext) async throws -> ToolRegistration? {
    if case .unofferedModel = input { return nil }
    let agent = try await runtime.agent(context: context)
    let choices: [ToolRegistration]
    switch input { case .model, .unofferedModel: choices = agent.tools; case .nested: choices = agent.callable }
    return choices.first { harnessNamesEqual($0.name, call.name) }
}
private func checkedToolArguments(_ tool: ToolRegistration, _ call: ToolCall, _ value: JSONValue,
                                  preserveCallOrder: Bool = true) throws -> JSONObject {
    guard let object = try foundationJSON(from: value) as? [String: Any] else {
        throw HarnessDefinitionError.argumentsMustBeObject(tool.name)
    }
    var candidate = call
    candidate.arguments = object.mapValues(AnyCodable.init)
    candidate.argumentsJSON = preserveCallOrder && call.argumentsJSON != nil
        ? toolArgumentsToOrderedJSON(candidate.arguments, argumentsJSON: call.argumentsJSON)
        : try OrderedJSON.parse(value.jsonText())
    candidate.arguments = toolArgumentsWithOrder(candidate.arguments, argumentsJSON: candidate.argumentsJSON)
    let schema = try tool.currentOrderedDeclaration()["parameters"] ?? .object([:])
    let checked = try validateToolArguments(tool: tool.declaration, toolCall: candidate,
                                            orderedParameters: OrderedJSON.parse(schema.jsonText()))
    guard case .object(let arguments) = try durableJSON(fromFoundation: checked.mapValues(\.value)) else {
        throw HarnessDefinitionError.argumentsMustBeObject(tool.name)
    }
    return arguments
}
private func runToolTask(_ task: RunningTask<ToolTaskInput, ToolTaskCheckpoint>, _ runtime: TaskRuntime,
                         _ context: ChordContext) async throws {
    let call = try await readToolCall(runtime, task.input, context)
    if let restarts = task.record.storedRestarts, restarts >= runtime.settings.restartLimit {
        let count = restarts == 1 ? "once" : "\(Int(restarts)) times in a row"
        let message = "Tool \(call.name) was interrupted \(count); it is not run again"
        return try await settleToolFromSlot(runtime, task.input, call, .restartLimit(message), code: "restart_limit", message: message,
                                            hooks: restarts <= runtime.settings.restartLimit, context: context)
    }
    let tool = try await resolveTool(runtime, task.input, call, context)
    if task.checkpoint.phase == .parked {
        guard let args = task.checkpoint.arguments else { throw TaskDefinitionError("Tool checkpoint is missing arguments") }
        guard let tool else {
            let message = "Tool \(call.name) is not available"
            try runtime.report(TaskDefinitionError("\(message): its parked call \(call.id) cannot run again"))
            return try await settleToolFromSlot(runtime, task.input, call, .failed(message), code: "tool_unavailable", message: message,
                                                hooks: true, context: context)
        }
        let wake = try task.record.state.wakeReason()
        try await runtime.commit({ tx, _ in
            if let slot = try toolSlot(live: await tx.doc(LiveDoc, conversationId: runtime.conversationId), taskId: runtime.taskId) {
                try slot.set("status", .string("running"))
                for key in ["output", "droppedBytes", "droppedLines"] { try slot.remove(key) }
            }
            return .running(checkpoint: try JSONValue(encoding: ToolTaskCheckpoint(phase: .execute, arguments: args,
                replay: tool.replay ?? .unsafe, wake: wake, checkpoint: task.checkpoint.checkpoint)))
        }, context: context)
        return try await executeTool(runtime, call, tool, args, context, wake: wake, checkpoint: task.checkpoint.checkpoint)
    }
    if task.checkpoint.phase == .execute {
        guard let args = task.checkpoint.arguments, let replay = task.checkpoint.replay else {
            throw TaskDefinitionError("Tool checkpoint is missing arguments or replay")
        }
        if replay == .safe, let tool, tool.replay == .safe {
            try await runtime.commit({ tx, _ in
                if let slot = try toolSlot(live: await tx.doc(LiveDoc, conversationId: runtime.conversationId), taskId: runtime.taskId) {
                    if task.checkpoint.wake == nil { try clearProgress(slot: slot) }
                    else { for key in ["output", "droppedBytes", "droppedLines"] { try slot.remove(key) } }
                    try slot.set("status", .string("running"))
                }
                return nil
            }, context: context)
            return try await executeTool(runtime, call, tool, args, context,
                                         wake: task.checkpoint.wake, checkpoint: task.checkpoint.checkpoint)
        }
        if task.checkpoint.wake != nil, let tool {
            try await cancelTool(runtime, call, tool, args, checkpoint: task.checkpoint.checkpoint, context: context)
        }
        let message = "Tool \(call.name) was interrupted and may have partially run"
        return try await settleToolFromSlot(runtime, task.input, call, .failed(message), code: "interrupted", message: message,
                                            hooks: true, context: context)
    }
    guard let tool else {
        return try await rejectTool(runtime, task.input, call, tool: nil,
            result: harnessToolError(code: "tool_unavailable", message: "Tool \(call.name) is not available"), context: context)
    }
    var args: JSONObject
    do {
        let original = try durableJSON(fromFoundation: call.arguments.mapValues(\.value))
        args = try checkedToolArguments(tool, call.call, tool.prepareArguments?(original) ?? original)
    } catch {
        return try await rejectTool(runtime, task.input, call, tool: tool,
            result: harnessToolError(code: "invalid_arguments", message: toolErrorText(error)), context: context)
    }
    var block: String?
    var gateSleep: GateSleep?
    let gateEpoch = runtime.phase.registryEpoch
    try await runtime.hooks.each(ToolHooks.self, context: context) { hooks in
        guard block == nil, gateSleep == nil, let hook = hooks.beforeTool else { return }
        var candidate = call
        candidate.arguments = (try foundationJSON(from: .object(args)) as! [String: Any]).mapValues(AnyCodable.init)
        candidate.argumentsJSON = nil
        do {
            if let decision = try await hook(candidate, runtime.hookApi, context) {
                if let reason = decision.block { block = reason }
                else if let sleep = decision.sleep { gateSleep = sleep }
                else if let replacement = decision.arguments { args = replacement }
            }
        } catch {
            if runtime.signal.aborted || context.abortSignal?.aborted == true { throw error }
            block = toolErrorText(error)
        }
    }
    if let block {
        return try await rejectTool(runtime, task.input, call, tool: tool,
            result: harnessToolError(code: "blocked", message: "Tool call blocked: \(block)"), context: context)
    }
    if let gateSleep {
        return try await parkAtGate(runtime, task.input, call, tool, gateSleep, gateEpoch: gateEpoch, context: context)
    }
    do { args = try checkedToolArguments(tool, call.call, .object(args), preserveCallOrder: false) }
    catch {
        return try await rejectTool(runtime, task.input, call, tool: tool,
            result: harnessToolError(code: "invalid_arguments", message: toolErrorText(error)), context: context)
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
        return nil
    }, context: context, persistence: .deferred()) // v1.5.2 D7 tool.ts:181-193
    // v1.5.2 D7 tool.ts:195-198 stores the execution intent before the tool runs.
    try await runtime.commit({ _, _ in
        try toolTask.running(ToolTaskCheckpoint(phase: .execute, arguments: final, replay: tool.replay ?? .unsafe))
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
    diagnostics.append(ToolDiagnostic(severity: .error, message: message, code: code))
    return ToolExecutionResult(output: slot?.output.flatMap { $0.isEmpty ? nil : [.text(TextContent(text: $0))] } ?? [],
                               isError: true, details: slot?.details, diagnostics: diagnostics)
}
internal func currentToolSlot(_ runtime: TaskRuntime, _ context: ChordContext) async throws -> ToolSlot? {
    guard let live = try await runtime.snapshot(LiveDoc, conversationId: runtime.conversationId, context: context) else { return nil }
    if let slot = live.tools?.first(where: { $0.taskId == runtime.taskId }) { return slot }
    guard let nested = live.nestedTools?.first(where: { $0.taskId == runtime.taskId }) else { return nil }
    var slot = ToolSlot(callId: nested.callId, name: nested.name, taskId: nested.taskId, status: nested.status)
    slot.output = nested.output; slot.droppedBytes = nested.droppedBytes; slot.droppedLines = nested.droppedLines
    slot.details = nested.details; slot.diagnostics = nested.diagnostics
    return slot
}

/// Applies afterTool to a Harness result before the terminal commit, including rejected and aborted calls.
private func afterHarnessToolResult(_ runtime: TaskRuntime, _ input: ToolTaskInput, _ call: ToolHookCall,
                                    tool: ToolRegistration?, result: ToolExecutionResult,
                                    truncation: ToolDiagnostic? = nil,
                                    context: ChordContext) async throws -> ToolExecutionResult {
    var final = result
    let originalOutput = result.outputIdentity
    try await runtime.hooks.each(ToolHooks.self, context: context) { hooks in
        if let replacement = try await hooks.afterTool?(call, final, runtime.hookApi, context) { final = replacement }
    }
    let limits = OutputLimits(maxBytes: tool?.outputLimits?.maxBytes ?? defaultMaxBytes,
                              maxLines: tool?.outputLimits?.maxLines ?? defaultMaxLines,
                              retain: tool?.outputLimits?.retain ?? .head)
    var diagnostics = final.diagnostics ?? []
    if final.outputIdentity == originalOutput, let truncation { diagnostics.append(truncation) }
    let bounded = boundToolContent(final.output ?? [], limits: limits)
    if bounded.droppedBytes > 0 { diagnostics.append(toolTruncated(bounded.droppedBytes, bounded.droppedLines, retain: limits.retain)) }
    final.structuredOutput = nil
    if case .nested = input, final.isError != true, tool?.structuredOutputSchema == nil {
        final.structuredOutput = try outputValue(bounded.content)
    }
    final.output = bounded.content
    final.diagnostics = diagnostics
    return final
}

private func rejectTool(_ runtime: TaskRuntime, _ input: ToolTaskInput, _ call: ToolHookCall,
                        tool: ToolRegistration?, result: ToolExecutionResult, context: ChordContext) async throws {
    let final = try await afterHarnessToolResult(runtime, input, call, tool: tool, result: result, context: context)
    try await settleTool(runtime, call, .completed, result: final, context: context)
}

/// Save a gate sleep at the call phase so every wake checks the full gate chain.
private func parkAtGate(_ runtime: TaskRuntime, _ input: ToolTaskInput, _ call: ToolHookCall,
                        _ tool: ToolRegistration, _ gate: GateSleep, gateEpoch: UInt64,
                        context: ChordContext) async throws {
    do {
        try await runtime.commit({ tx, _ in
            if let slot = try toolSlot(live: await tx.doc(LiveDoc, conversationId: runtime.conversationId), taskId: runtime.taskId) {
                try slot.set("status", .string("sleeping"))
            }
            let checkpoint = ToolTaskCheckpoint(phase: .call)
            if let signals = gate.signals {
                return try toolTask.sleeping(checkpoint, signals: signals, until: gate.until)
            }
            if let until = gate.until { return try toolTask.sleeping(checkpoint, until: until) }
            throw TaskDefinitionError("Tool call \(call.id) cannot sleep without until or signals")
        }, context: context)
        // A publication may occur while the hook runs. Wake the just saved sleep.
        runtime.scheduler.wakeGatedCallIfRegistryChanged(runtime.taskId, since: gateEpoch)
    } catch {
        if runtime.signal.aborted || context.abortSignal?.aborted == true || runtime.scheduler.closing { throw error }
        let message = "Tool call \(call.id) cannot wait at its gates: \(toolErrorText(error))"
        try await rejectTool(runtime, input, call, tool: tool,
            result: harnessToolError(code: "invalid_park", message: message), context: context)
    }
}

private func settleToolFromSlot(_ runtime: TaskRuntime, _ input: ToolTaskInput, _ call: ToolHookCall,
                                _ ending: ToolEnding, code: String, message: String, hooks: Bool,
                                context: ChordContext) async throws {
    let slot = try await currentToolSlot(runtime, context)
    let result = toolResultFromSlot(slot, code: code, message: message)
    let truncation = slot.flatMap { slot in
        (slot.droppedBytes ?? 0) > 0 ? toolTruncated(slot.droppedBytes ?? 0, slot.droppedLines ?? 0) : nil
    }
    let final: ToolExecutionResult
    if hooks {
        let tool: ToolRegistration?
        if case .unofferedModel = input { tool = nil }
        else {
            let agent = try? await runtime.agent(context: context)
            let choices: [ToolRegistration]
            switch input { case .model, .unofferedModel: choices = agent?.tools ?? []; case .nested: choices = agent?.callable ?? [] }
            tool = choices.first { harnessNamesEqual($0.name, call.name) }
        }
        final = try await afterHarnessToolResult(runtime, input, call, tool: tool, result: result,
                                                 truncation: truncation, context: context)
    } else {
        var built = result
        if let truncation { built.diagnostics = (built.diagnostics ?? []) + [truncation] }
        final = built
    }
    try await settleTool(runtime, call, ending, result: final, context: context)
}

internal func settleTool(_ runtime: TaskRuntime, _ call: ToolHookCall, _ ending: ToolEnding,
                         result: ToolExecutionResult, durationMs measured: Int? = nil, context: ChordContext) async throws {
    let children = try await runtime.ownedTasks(context: context).filter { $0.kind == "pi.tool" && $0.input["kind"] == "nested" }
    let madeNested = try await runtime.memo("pi.tool.madeNestedCalls", context: context) == true
    try await withThrowingTaskGroup(of: Void.self) { group in
        for child in children { group.addTask { try await runtime.abortOwned(child.id, context: context) } }
        try await group.waitForAll()
    }
    try await runtime.commit({ tx, current in
        let durationMs: Int?
        if let startedAt = current.startedAt {
            durationMs = Int(exactly: (Double(try runtime.now()) - startedAt).rounded())
        } else {
            durationMs = measured
        }
        let live = try await tx.doc(LiveDoc, conversationId: runtime.conversationId)
        let slot = try toolSlot(live: live, taskId: runtime.taskId)
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
        case .model, .unofferedModel:
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
        case .restartLimit(let message): return .terminal(outcome: .failed(error: TaskOutcomeError(message: message, detail: ["reason": "restart_limit"]), result: value))
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
    var model = try EntryRecord.encodeMessages([.toolResult(message)])
    if result.details == nil, case .object(var object) = model[0] {
        object.removeValue(forKey: "details")
        model[0] = .object(object)
    }
    return try await tx.appendEntry(conversationId, value: EntryDraft(kind: toolResultEntry.kind,
        model: model, data: JSONValue(encoding: ToolResultEntryData(diagnostics: diagnostics))))
}

/// Use the Swift error's message without Foundation error bridging.
internal func toolErrorText(_ error: any Error) -> String {
    if let localized = error as? any LocalizedError, let message = localized.errorDescription { return message }
    return String(describing: error)
}
