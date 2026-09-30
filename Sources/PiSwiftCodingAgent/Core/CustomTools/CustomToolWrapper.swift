import PiSwiftAI
import PiSwiftAgent

public func wrapCustomTool(_ tool: CustomTool, _ getContext: @escaping @Sendable () -> CustomToolContext) -> AgentTool {
    wrapCustomTool(tool, contextFactory: { _, _ in getContext() })
}

/// Create the extension context for each call, including its id and cancellation signal.
public func wrapCustomTool(
    _ tool: CustomTool,
    contextFactory: @escaping @Sendable (String, CancellationToken?) -> CustomToolContext
) -> AgentTool {
    AgentTool(
        label: tool.label,
        name: tool.name,
        description: tool.description,
        parameters: tool.parameters ?? [:],
        execute: { toolCallId, params, signal, onUpdate in
            var context = contextFactory(toolCallId, signal)
            context.setToolCall(toolCallId, signal: signal)
            return try await tool.execute(toolCallId, params, onUpdate, context, signal)
        },
        constrainedSampling: tool.constrainedSampling,
        outputSchema: tool.outputSchema,
        executionMode: tool.executionMode
    )
}

public func wrapCustomTools(_ loadedTools: [LoadedCustomTool], _ getContext: @escaping @Sendable () -> CustomToolContext) -> [AgentTool] {
    loadedTools.map { wrapCustomTool($0.tool, getContext) }
}

public func wrapCustomTools(
    _ loadedTools: [LoadedCustomTool],
    contextFactory: @escaping @Sendable (String, CancellationToken?) -> CustomToolContext
) -> [AgentTool] {
    loadedTools.map { wrapCustomTool($0.tool, contextFactory: contextFactory) }
}
