public func splitDeferredTools(
    _ context: Context,
    enabled: Bool,
    normalizeName: (String) -> String = { $0 }
) -> (immediate: [AITool], deferred: [AITool]) {
    var orderedNames: [String] = []
    var uniqueTools: [String: AITool] = [:]

    for tool in context.tools ?? [] {
        let name = normalizeName(tool.name)
        if uniqueTools[name] == nil {
            orderedNames.append(name)
        }
        uniqueTools[name] = tool
    }

    if !enabled {
        return (orderedNames.compactMap { uniqueTools[$0] }, [])
    }

    var deferredNames: Set<String> = []
    var usedNames: Set<String> = []

    for message in context.messages {
        switch message {
        case .assistant(let assistantMessage):
            for block in assistantMessage.content {
                if case .toolCall(let call) = block {
                    usedNames.insert(normalizeName(call.name))
                }
            }
        case .toolResult(let toolResultMessage):
            for name in toolResultMessage.addedToolNames ?? [] {
                let normalizedName = normalizeName(name)
                if !usedNames.contains(normalizedName) {
                    deferredNames.insert(normalizedName)
                }
            }
        case .user:
            break
        }
    }

    var immediate: [AITool] = []
    var deferred: [AITool] = []
    for name in orderedNames {
        guard let tool = uniqueTools[name] else { continue }
        if deferredNames.contains(name) {
            deferred.append(tool)
        } else {
            immediate.append(tool)
        }
    }

    return (immediate, deferred)
}
