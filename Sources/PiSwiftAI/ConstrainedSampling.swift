import Foundation

public struct GrammarConstrainedSampling: Sendable, Equatable {
    public enum Format: String, Sendable, Equatable {
        case lark
        case regex
    }

    public let format: Format
    public let definition: String
    public let inputProperty: String
}

public struct GrammarToolInputJsonBuffer: Sendable, Equatable {
    public var input: String
    public var started: Bool
    public var closed: Bool

    public init(input: String = "", started: Bool = false, closed: Bool = false) {
        self.input = input
        self.started = started
        self.closed = closed
    }
}

public func getGrammarToolInput(
    toolName: String,
    arguments: [String: AnyCodable],
    inputProperty: String
) throws -> String {
    guard let input = arguments[inputProperty]?.value as? String else {
        throw ValidationError.constrainedSampling(
            "Grammar tool call \"\(toolName)\" requires argument \"\(inputProperty)\" to be a string."
        )
    }
    return input
}

public func appendGrammarToolInputJsonDelta(
    buffer: inout GrammarToolInputJsonBuffer,
    inputProperty: String,
    nextInput: String,
    close: Bool
) throws -> String? {
    if buffer.closed {
        if close, nextInput == buffer.input { return nil }
        throw ValidationError.constrainedSampling(
            "grammar tool input for property \"\(inputProperty)\" changed after it was closed"
        )
    }
    guard nextInput.hasPrefix(buffer.input) else {
        throw ValidationError.constrainedSampling(
            "grammar tool input for property \"\(inputProperty)\" changed non-monotonically"
        )
    }

    let inputDelta = String(nextInput.dropFirst(buffer.input.count))
    if !close, inputDelta.isEmpty { return nil }

    var delta = ""
    if !buffer.started {
        delta += "{\(jsonStringLiteral(inputProperty)):\""
        buffer.started = true
    }
    delta += jsonStringLiteral(inputDelta).dropFirst().dropLast()
    buffer.input = nextInput

    if close {
        delta += "\"}"
        buffer.closed = true
    }
    return delta
}

public func inferGrammarInputProperty(tool: AITool) throws -> String {
    guard tool.parameters["type"]?.value as? String == "object" else {
        throw ValidationError.constrainedSampling("grammar constrained sampling requires an object parameter schema")
    }
    guard let required = tool.parameters["required"]?.value as? [Any],
          required.count == 1,
          let inputProperty = required[0] as? String else {
        throw ValidationError.constrainedSampling(
            "grammar constrained sampling requires exactly one required string property"
        )
    }
    guard let properties = tool.parameters["properties"]?.value as? [String: Any],
          let property = properties[inputProperty] as? [String: Any] else {
        throw ValidationError.constrainedSampling(
            "grammar constrained sampling requires a properties entry for \(inputProperty)"
        )
    }
    guard property["type"] as? String == "string" else {
        throw ValidationError.constrainedSampling(
            "grammar constrained sampling property \(inputProperty) must have type string"
        )
    }
    return inputProperty
}

public func resolveJsonSchemaStrictSampling(
    tool: AITool,
    supportsStrictMode: Bool
) throws -> Bool? {
    guard case .jsonSchema(let strictness) = tool.constrainedSampling else {
        return nil
    }

    if supportsStrictMode { return true }
    if strictness == .require {
        throw ValidationError.constrainedSampling(
            "Tool \"\(tool.name)\" requires JSON-schema constrained sampling, but strict tools are unsupported."
        )
    }
    return nil
}

public func resolveGrammarConstrainedSampling(
    tool: AITool,
    supportsOpenAIGrammarTools: Bool
) throws -> GrammarConstrainedSampling? {
    guard case .grammar(let variants) = tool.constrainedSampling else {
        return nil
    }
    guard supportsOpenAIGrammarTools else { return nil }

    let larkDefinition = variants[.openAILark]
    let regexDefinition = variants[.openAIRegex]
    let hasLarkDefinition = larkDefinition?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    let hasRegexDefinition = regexDefinition?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    guard hasLarkDefinition || hasRegexDefinition else {
        throw ValidationError.constrainedSampling(
            "Tool \"\(tool.name)\" cannot use grammar constrained sampling: no supported grammar variant was provided."
        )
    }

    do {
        return GrammarConstrainedSampling(
            format: hasLarkDefinition ? .lark : .regex,
            definition: hasLarkDefinition ? larkDefinition! : regexDefinition!,
            inputProperty: try inferGrammarInputProperty(tool: tool)
        )
    } catch {
        let message = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
        throw ValidationError.constrainedSampling(
            "Tool \"\(tool.name)\" cannot use grammar constrained sampling: \(message)."
        )
    }
}

public func createGrammarToolInputProperties(
    tools: [AITool]?,
    supportsOpenAIGrammarTools: Bool
) throws -> [String: String] {
    var properties: [String: String] = [:]
    for tool in tools ?? [] {
        if let grammar = try resolveGrammarConstrainedSampling(
            tool: tool,
            supportsOpenAIGrammarTools: supportsOpenAIGrammarTools
        ) {
            properties[tool.name] = grammar.inputProperty
        }
    }
    return properties
}

private func jsonStringLiteral(_ value: String) -> String {
    guard let data = try? JSONSerialization.data(
        withJSONObject: value,
        options: [.fragmentsAllowed, .withoutEscapingSlashes]
    ), let string = String(data: data, encoding: .utf8) else {
        return "\"\""
    }
    return string
}
