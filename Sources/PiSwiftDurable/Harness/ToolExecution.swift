import Foundation
import PiSwiftAI
import PiSwiftChord

internal func executeTool(_ runtime: TaskRuntime, _ call: ToolHookCall, _ tool: ToolRegistration,
                          _ args: JSONObject, _ context: ChordContext) async throws {
    let limits = OutputLimits(maxBytes: tool.outputLimits?.maxBytes ?? defaultMaxBytes,
                              maxLines: tool.outputLimits?.maxLines ?? defaultMaxLines,
                              retain: tool.outputLimits?.retain ?? .head)
    let lifetime = ToolInvocationLifetime(callId: call.id)
    let record = try await runtime.getTask(runtime.taskId, context: context)
    let streams = record?.input["kind"] != "nested" || record?.input["progress"] != false
    let reporter = ToolReporter(runtime: runtime, lifetime: lifetime, limits: limits, enabled: streams, context: context)
    let nested = NestedToolCalls(runtime: runtime, callId: call.id, resumes: tool.replay == .safe)
    var result: ToolExecutionResult
    var ending = ToolEnding.completed
    var durationMs: Int?
    do {
        let env = try await runtime.env(context: context)
        var api = ToolExecutionApi(taskId: runtime.taskId, conversationId: runtime.conversationId, callId: call.id,
            registry: runtime.registry, models: runtime.models, env: env, read: runtime.hookApi.read,
            outputWindow: limits.retain == .tail ? ShellOutputWindow(maxBytes: limits.maxBytes, maxLines: limits.maxLines,
                minIntervalMs: runtime.settings.progress.outputIntervalMs, bytesPerSecond: progressBytesPerSecond) : nil,
            runtime: runtime, lifetime: lifetime, agent: { try await runtime.agent(context: $0) },
            output: { try reporter.output($0, skipped: $1) },
            retainedOutput: { let output = reporter.snapshot().output; return .init(text: output.text, truncated: output.droppedBytes > 0) }, diagnostic: { try reporter.diagnostic($0) },
            details: { try await reporter.details($0, context: $1) },
            memo: { try await runtime.memo($0, value: $1, context: $2) })
        api.nestedCalls = nested
        api.abandonCreatedTasks = tool.replay != .safe
        api.pendingDetailsCount = { reporter.pendingDetailsCount }
        let now = runtime.scheduler.toolServices.executionTime()
        let started = now()
        do { result = try await tool.execute(.object(args), api, context) }
        catch {
            durationMs = toolDurationMs(now() - started)
            throw error
        }
        durationMs = toolDurationMs(now() - started)
    } catch {
        if runtime.signal.aborted || context.abortSignal?.aborted == true {
            nested.close(); lifetime.end()
            let pending = await reporter.stop()
            for waiter in pending { waiter.reject(error) }
            throw error
        }
        result = ToolExecutionResult(isError: true, diagnostics: [ToolDiagnostic(severity: .error, message: toolErrorText(error), code: "tool_error")])
        ending = .failed("Tool \(call.name) threw")
    }
    nested.close(); lifetime.end()
    await nested.end()
    let pending = await reporter.stop()
    do {
        let final = try await finalToolResult(runtime, call, tool, result, reporter, context)
        try await settleTool(runtime, call, ending, durationMs: durationMs, context: context) { _ in final }
        for waiter in pending { waiter.resolve() }
    } catch {
        for waiter in pending { waiter.reject(error) }
        throw error
    }
}
private func toolDurationMs(_ duration: Duration) -> Int {
    let value = Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
    return max(0, Int(value.rounded()))
}
private func finalToolResult(_ runtime: TaskRuntime, _ call: ToolHookCall, _ tool: ToolRegistration, _ result: ToolExecutionResult,
                             _ reporter: ToolReporter, _ context: ChordContext) async throws -> ToolExecutionResult {
    let reported = reporter.snapshot()
    let retained = result.output == nil ? reported.output : nil
    var final = result
    if let retained { final.output = retained.text.isEmpty ? [] : [.text(TextContent(text: retained.text))] }
    if final.details == nil { final.details = reported.details }
    final.diagnostics = reported.diagnostics + (result.diagnostics ?? [])
    let retainedIdentity = final.outputIdentity
    try await runtime.hooks.each(ToolHooks.self, context: context) { hooks in
        if let replacement = try await hooks.afterTool?(call, final, runtime.hookApi, context) {
            final = replacement
        }
    }
    var diagnostics = final.diagnostics ?? []
    if final.outputIdentity == retainedIdentity, let retained, retained.droppedBytes > 0 {
        diagnostics.append(toolTruncated(retained.droppedBytes, retained.droppedLines, retain: reporter.limits.retain))
    }
    let bounded = boundToolContent(final.output ?? [], limits: reporter.limits)
    if bounded.droppedBytes > 0 { diagnostics.append(toolTruncated(bounded.droppedBytes, bounded.droppedLines, retain: reporter.limits.retain)) }
    if let broken = try structuredOutputError(tool, final) {
        final.structuredOutput = nil
        if call.parent != nil {
            final.isError = true
            diagnostics.append(.init(severity: .error, message: broken, code: "invalid_structured_output"))
        } else { runtime.scheduler.report(TaskDefinitionError(broken)) }
    }
    if call.parent != nil {
        if tool.structuredOutputSchema == nil { final.structuredOutput = try outputValue(bounded.content) }
        else if final.isError == true, final.structuredOutput == nil,
                !diagnostics.contains(where: { $0.severity == .error }) {
            let text = bounded.content.compactMap { if case .text(let item) = $0 { return item.text }; return nil }.joined(separator: "\n")
            if !text.isEmpty { diagnostics.append(.init(severity: .error, message: text, code: "tool_error")) }
        }
    }
    final.output = bounded.content; final.diagnostics = diagnostics
    return final
}
internal func boundToolContent(_ content: [ContentBlock], limits: OutputLimits) -> (content: [ContentBlock], droppedBytes: Int, droppedLines: Int) {
    let indices = content.indices.filter { if case .text = content[$0] { return true }; return false }
    let bounded = boundOutput(indices.map { if case .text(let text) = content[$0] { return text.text }; return "" }.joined(), limits: limits)
    guard bounded.droppedBytes > 0 else { return (content, 0, 0) }
    let keep = limits.retain == .head ? indices.first : indices.last
    var result: [ContentBlock] = []
    for index in content.indices {
        if case .text(var text) = content[index] {
            if index == keep { text.text = bounded.text; result.append(.text(text)) }
        } else { result.append(content[index]) }
    }
    return (result, bounded.droppedBytes, bounded.droppedLines)
}

/// A schema-free program result uses bounded output before rendered diagnostics.
private func outputValue(_ content: [ContentBlock]) throws -> JSONValue {
    if content.isEmpty { return "" }
    if content.count == 1, case .text(let text) = content[0] { return .string(text.text) }
    let message = ToolResultMessage(toolCallId: "", toolName: "", content: content, isError: false, timestamp: 0)
    let value = try EntryRecord.encodeMessages([.toolResult(message)])[0]
    guard let encoded = value["content"]?.arrayValue else { throw TaskDefinitionError("Tool output has no content") }
    return encoded.count == 1 ? encoded[0] : .array(encoded)
}
