import Foundation
import PiSwiftAI
import PiSwiftChord

internal func executeTool(_ runtime: TaskRuntime, _ call: ToolCall, _ tool: ToolRegistration,
                          _ args: JSONObject, _ context: ChordContext) async throws {
    let limits = OutputLimits(maxBytes: tool.outputLimits?.maxBytes ?? defaultMaxBytes,
                              maxLines: tool.outputLimits?.maxLines ?? defaultMaxLines,
                              retain: tool.outputLimits?.retain ?? .head)
    let lifetime = ToolInvocationLifetime(callId: call.id)
    let reporter = ToolReporter(runtime: runtime, lifetime: lifetime, limits: limits, context: context)
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
            output: { try reporter.output($0, skipped: $1) }, diagnostic: { try reporter.diagnostic($0) },
            details: { try await reporter.details($0, context: $1) },
            memo: { try await runtime.memo($0, value: $1, context: $2) })
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
            let pending = await reporter.stop()
            for waiter in pending { waiter.reject(error) }
            throw error
        }
        result = ToolExecutionResult(isError: true, diagnostics: [ToolDiagnostic(severity: .error, message: toolErrorText(error), code: "tool_error")])
        ending = .failed("Tool \(call.name) threw")
    }
    let pending = await reporter.stop()
    do {
        let final = try await finalToolResult(runtime, call, result, reporter, context)
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
private func finalToolResult(_ runtime: TaskRuntime, _ call: ToolCall, _ result: ToolExecutionResult,
                             _ reporter: ToolReporter, _ context: ChordContext) async throws -> ToolExecutionResult {
    let reported = reporter.snapshot()
    let retained = result.content == nil ? reported.output : nil
    var final = result
    if let retained { final.content = retained.text.isEmpty ? [] : [.text(TextContent(text: retained.text))] }
    if final.details == nil { final.details = reported.details }
    final.diagnostics = reported.diagnostics + (result.diagnostics ?? [])
    let retainedIdentity = final.contentIdentity
    try await runtime.hooks.each(ToolHooks.self, context: context) { hooks in
        if let replacement = try await hooks.afterTool?(call, final, runtime.hookApi, context) {
            final = replacement
        }
    }
    var diagnostics = final.diagnostics ?? []
    if final.contentIdentity == retainedIdentity, let retained, retained.droppedBytes > 0 {
        diagnostics.append(toolTruncated(retained.droppedBytes, retained.droppedLines, retain: reporter.limits.retain))
    }
    let bounded = boundToolContent(final.content ?? [], limits: reporter.limits)
    if bounded.droppedBytes > 0 { diagnostics.append(toolTruncated(bounded.droppedBytes, bounded.droppedLines, retain: reporter.limits.retain)) }
    final.content = bounded.content; final.diagnostics = diagnostics
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
