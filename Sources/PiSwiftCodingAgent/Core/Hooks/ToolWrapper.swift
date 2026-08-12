import Foundation
import PiSwiftAI
import PiSwiftAgent

enum HookRunnerError: LocalizedError, Sendable {
    case toolExecutionBlocked(String)

    var errorDescription: String? {
        switch self {
        case .toolExecutionBlocked(let reason):
            return reason
        }
    }
}

public func wrapToolWithHooks(_ tool: AgentTool, _ hookRunner: HookRunner) -> AgentTool {
    AgentTool(
        label: tool.label,
        name: tool.name,
        description: tool.description,
        parameters: tool.parameters,
        execute: { toolCallId, params, signal, onUpdate in
            if hookRunner.hasHandlers("tool_call") {
                let callEvent = ToolCallEvent(toolName: tool.name, toolCallId: toolCallId, input: params)
                if let callResult = await hookRunner.emitToolCall(callEvent), callResult.block {
                    let reason = callResult.reason ?? "Tool execution was blocked by a hook"
                    return AgentToolResult(
                        content: [.text(TextContent(text: reason))],
                        details: nil,
                        terminate: callResult.terminate
                    )
                }
            }

            do {
                let result = try await tool.execute(toolCallId, params, signal, onUpdate)

                if hookRunner.hasHandlers("tool_result") {
                    let event = ToolResultEvent(
                        toolName: tool.name,
                        toolCallId: toolCallId,
                        input: params,
                        content: result.content,
                        details: result.details,
                        isError: false
                    )
                    if let hookResult = await hookRunner.emit(event) as? ToolResultEventResult {
                        return AgentToolResult(
                            content: hookResult.content ?? result.content,
                            details: hookResult.details ?? result.details,
                            terminate: result.terminate
                        )
                    }
                }

                return result
            } catch {
                if hookRunner.hasHandlers("tool_result") {
                    let event = ToolResultEvent(
                        toolName: tool.name,
                        toolCallId: toolCallId,
                        input: params,
                        content: [.text(TextContent(text: error.localizedDescription))],
                        details: nil,
                        isError: true
                    )
                    _ = await hookRunner.emit(event)
                }
                throw error
            }
        },
        prepareArguments: tool.prepareArguments
    )
}

public func wrapToolsWithHooks(_ tools: [AgentTool], _ hookRunner: HookRunner) -> [AgentTool] {
    tools.map { wrapToolWithHooks($0, hookRunner) }
}
