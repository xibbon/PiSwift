import Foundation

public struct TranscriptContext: Sendable {
    public let messages: [Message]
    init(messages: [Message]) { self.messages = messages }
}

public protocol TranscriptMessageLike {
    var transcriptSystemMessage: SystemMessage? { get }
}
extension Message: TranscriptMessageLike {
    public var transcriptSystemMessage: SystemMessage? {
        if case .system(let message) = self { return message }
        return nil
    }
}

public func contentText(_ content: SystemContent, separator: String = "\n") -> String {
    switch content {
    case .text(let text): text
    case .blocks(let blocks): blocks.map(\.text).joined(separator: separator)
    }
}

public func getSystemMessageText(_ message: SystemMessage) -> String {
    ([contentText(message.content)] + (message.sections?.entries.compactMap(\.value) ?? []))
        .filter { !$0.isEmpty }.joined(separator: "\n\n")
}

public func renderSystemMessageUpdate(_ message: SystemMessage) -> String {
    var parts: [String] = []
    let text = contentText(message.content)
    if !text.isEmpty { parts.append(text) }
    for section in message.sections?.entries ?? [] {
        if let value = section.value {
            parts.append("Updated system prompt section \"\(section.name)\":\n\n\(value)")
        } else {
            parts.append("Removed system prompt section \"\(section.name)\".")
        }
    }
    return parts.joined(separator: "\n\n")
}

public func createInitialSystemMessage(_ systemPrompt: String?, _ tools: [AITool]?) -> SystemMessage? {
    guard systemPrompt?.isEmpty == false || tools?.isEmpty == false else { return nil }
    return SystemMessage(content: .text(systemPrompt ?? ""), toolsAdded: tools?.isEmpty == false ? tools : nil, timestamp: 0)
}
public func normalizeContext(_ context: Context) -> TranscriptContext {
    let messages = createInitialSystemMessage(context.systemPrompt, context.tools).map { [Message.system($0)] + context.messages } ?? context.messages
    return TranscriptContext(messages: messages)
}
public func getInitialSystemMessage<T: TranscriptMessageLike>(_ messages: [T]) -> SystemMessage? { messages.first?.transcriptSystemMessage }
public func withoutInitialSystemMessage(_ messages: [Message]) -> [Message] { getInitialSystemMessage(messages) == nil ? messages : Array(messages.dropFirst()) }
public func getCurrentTools<T: TranscriptMessageLike>(_ messages: [T]) -> [AITool] {
    var tools: [AITool] = []
    for message in messages {
        guard let system = message.transcriptSystemMessage else { continue }
        for removed in system.toolsRemoved ?? [] { tools.removeAll { $0.name == removed.name } }
        for added in system.toolsAdded ?? [] {
            if let index = tools.firstIndex(where: { $0.name == added.name }) { tools[index] = added }
            else { tools.append(added) }
        }
    }
    return tools
}
public func getCurrentSystemMessage<T: TranscriptMessageLike>(_ messages: [T]) -> SystemMessage? {
    var content: [String] = []
    var sections = SystemPromptSections([])
    var timestamp: Int64?
    for message in messages {
        guard let system = message.transcriptSystemMessage else { continue }
        if timestamp == nil { timestamp = system.timestamp }
        let text = contentText(system.content)
        if !text.isEmpty { content.append(text) }
        for section in system.sections?.entries ?? [] {
            if let value = section.value { sections[section.name] = value }
            else { sections.remove(section.name) }
        }
    }
    let tools = getCurrentTools(messages)
    guard timestamp != nil || !tools.isEmpty else { return nil }
    return SystemMessage(content: .text(content.joined(separator: "\n\n")),
                         sections: sections.entries.isEmpty ? nil : sections,
                         toolsAdded: tools.isEmpty ? nil : tools, timestamp: timestamp ?? 0)
}
public func getCurrentSystemPrompt<T: TranscriptMessageLike>(_ messages: [T]) -> String {
    getCurrentSystemMessage(messages).map(getSystemMessageText) ?? ""
}
public func collapseSystemMessages(_ context: TranscriptContext) -> TranscriptContext {
    let head = getCurrentSystemMessage(context.messages)
    let tail = context.messages.filter { $0.transcriptSystemMessage == nil }
    return TranscriptContext(messages: head.map { [.system($0)] + tail } ?? tail)
}
public func resolveTranscript(_ context: TranscriptContext, supportsMidConvoSystemMessages: Bool) -> TranscriptContext {
    supportsMidConvoSystemMessages ? context : collapseSystemMessages(context)
}

public func toToolDeclaration(_ tool: AITool) -> AITool { tool }
private func toolDeclarationObject(_ tool: AITool) -> [String: Any] {
    var result: [String: Any] = ["name": tool.name, "description": tool.description,
                                 "parameters": tool.parameters.mapValues(\.jsonValue)]
    if let sampling = tool.constrainedSampling {
        switch sampling {
        case .disabled: result["constrainedSampling"] = false
        case .jsonSchema(let strict): result["constrainedSampling"] = ["type": "json_schema", "strict": strict.rawValue]
        case .grammar(let variants): result["constrainedSampling"] = ["type": "grammar", "variants": Dictionary(uniqueKeysWithValues: variants.map { ($0.key.rawValue, $0.value) })]
        }
    }
    return result
}
public func declarationsEqual(_ left: AITool, _ right: AITool) -> Bool {
    let lhs = toolDeclarationObject(left), rhs = toolDeclarationObject(right)
    guard let a = try? JSONSerialization.data(withJSONObject: lhs, options: [.sortedKeys, .fragmentsAllowed]),
          let b = try? JSONSerialization.data(withJSONObject: rhs, options: [.sortedKeys, .fragmentsAllowed]) else { return false }
    return a == b
}
public struct ToolStateChanges: Sendable {
    public let toolsAdded: [AITool]
    public let toolsRemoved: [ToolReference]
}
public func getToolStateChanges(_ previous: [AITool], _ current: [AITool]) -> ToolStateChanges {
    var old: [String: AITool] = [:]
    var new: [String: AITool] = [:]
    for tool in previous { old[tool.name] = tool }
    for tool in current { new[tool.name] = tool }
    return ToolStateChanges(
        toolsAdded: current.filter { tool in old[tool.name].map { !declarationsEqual($0, tool) } ?? true }.map(toToolDeclaration),
        toolsRemoved: previous.filter { tool in new[tool.name].map { !declarationsEqual(tool, $0) } ?? true }.map { ToolReference(name: $0.name) })
}
public func getDeclaredTools<T: TranscriptMessageLike>(_ messages: [T]) -> [AITool] {
    var result: [AITool] = []
    for message in messages {
        for tool in message.transcriptSystemMessage?.toolsAdded ?? [] {
            if let index = result.firstIndex(where: { $0.name == tool.name }) { result[index] = tool }
            else { result.append(tool) }
        }
    }
    return result
}
@available(*, deprecated, message: "No built-in transport needs this anymore: Anthropic expresses redefinitions with inline tool_definition blocks.")
public func hasToolRedefinitions<T: TranscriptMessageLike>(_ messages: [T]) -> Bool {
    var declared: [String: AITool] = [:]
    for message in messages {
        for tool in message.transcriptSystemMessage?.toolsAdded ?? [] {
            if let previous = declared[tool.name], !declarationsEqual(previous, tool) { return true }
            declared[tool.name] = tool
        }
    }
    return false
}
public func hasNonAdditiveToolChanges<T: TranscriptMessageLike>(_ messages: [T]) -> Bool {
    var declared: Set<String> = []
    for message in messages {
        guard let system = message.transcriptSystemMessage else { continue }
        if system.toolsRemoved?.isEmpty == false { return true }
        for tool in system.toolsAdded ?? [] {
            if !declared.insert(tool.name).inserted { return true }
        }
    }
    return false
}
public struct TranscriptTools: Sendable {
    public let requestTools: [AITool]
    public let anchorsAdditions: Bool
}
public func resolveTranscriptTools<T: TranscriptMessageLike>(_ messages: [T], supportsToolAdditions: Bool) -> TranscriptTools {
    let anchors = supportsToolAdditions && !hasNonAdditiveToolChanges(messages)
    return TranscriptTools(requestTools: anchors ? (getInitialSystemMessage(messages)?.toolsAdded ?? []) : getCurrentTools(messages),
                           anchorsAdditions: anchors)
}

// Providers without native mid-conversation system support use the collapsed transcript.
func collapsedProviderContext(_ transcript: TranscriptContext) -> Context {
    let collapsed = collapseSystemMessages(transcript)
    let prompt = getCurrentSystemPrompt(collapsed.messages)
    let tools = getCurrentTools(collapsed.messages)
    return Context(systemPrompt: prompt.isEmpty ? nil : prompt,
                   messages: collapsed.messages.filter { $0.transcriptSystemMessage == nil },
                   tools: tools.isEmpty ? nil : tools)
}

public func systemMessageToJSONObject(_ message: SystemMessage) -> [String: Any] {
    var result: [String: Any] = ["role": "system", "timestamp": message.timestamp]
    switch message.content {
    case .text(let text): result["content"] = text
    case .blocks(let blocks): result["content"] = blocks.map { block -> [String: Any] in
        var value: [String: Any] = ["type": "text", "text": block.text]
        if let signature = block.textSignature { value["textSignature"] = signature }
        return value
    }
    }
    if let sections = message.sections {
        result["sections"] = Dictionary(uniqueKeysWithValues: sections.entries.map { ($0.name, $0.value as Any? ?? NSNull()) })
    }
    if let added = message.toolsAdded { result["toolsAdded"] = added.map(toolDeclarationObject) }
    if let removed = message.toolsRemoved { result["toolsRemoved"] = removed.map { ["name": $0.name] } }
    return result
}

public func systemMessageToOrderedJSON(_ message: SystemMessage) -> OrderedJSON {
    let content: OrderedJSON
    switch message.content {
    case .text(let text): content = .string(text)
    case .blocks(let blocks):
        content = .array(blocks.map { block in
            var fields: [(String, OrderedJSON)] = [("type", .string("text")), ("text", .string(block.text))]
            if let signature = block.textSignature { fields.append(("textSignature", .string(signature))) }
            return .object(fields)
        })
    }
    var fields: [(String, OrderedJSON)] = [("role", .string("system")), ("content", content)]
    if let sections = message.sections {
        fields.append(("sections", .object(sections.entries.map { ($0.name, $0.value.map(OrderedJSON.string) ?? .null) })))
    }
    if let tools = message.toolsAdded {
        fields.append(("toolsAdded", .array(tools.map { tool in
            var entries: [(String, OrderedJSON)] = [
                ("name", .string(tool.name)), ("description", .string(tool.description)),
                ("parameters", .fromFoundation(tool.parameters.mapValues(\.jsonValue)))
            ]
            if let sampling = toolDeclarationObject(tool)["constrainedSampling"] {
                entries.append(("constrainedSampling", .fromFoundation(sampling)))
            }
            return .object(entries)
        })))
    }
    if let removed = message.toolsRemoved {
        fields.append(("toolsRemoved", .array(removed.map { .object([("name", .string($0.name))]) })))
    }
    fields.append(("timestamp", .number(String(message.timestamp))))
    return .object(fields)
}
