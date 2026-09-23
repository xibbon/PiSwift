import PiSwiftAgent

public func wrapCustomTool(_ tool: CustomTool, _ getContext: @escaping @Sendable () -> CustomToolContext) -> AgentTool {
    AgentTool(
        label: tool.label,
        name: tool.name,
        description: tool.description,
        parameters: tool.parameters ?? [:],
        execute: { toolCallId, params, signal, onUpdate in
            try await tool.execute(toolCallId, params, onUpdate, getContext(), signal)
        },
        constrainedSampling: tool.constrainedSampling
    )
}

public func wrapCustomTools(_ loadedTools: [LoadedCustomTool], _ getContext: @escaping @Sendable () -> CustomToolContext) -> [AgentTool] {
    loadedTools.map { wrapCustomTool($0.tool, getContext) }
}
