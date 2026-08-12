import Foundation

/// Errors that can occur during tool validation.
public enum ValidationError: Error, LocalizedError {
    case toolNotFound(String)
    case validationFailed(toolName: String, errors: [SchemaValidationError], receivedArguments: [String: AnyCodable])
    case schemaMissing(String)
    case constrainedSampling(String)

    public var errorDescription: String? {
        switch self {
        case .toolNotFound(let name):
            return "Tool \"\(name)\" not found"
        case .validationFailed(let toolName, let errors, let receivedArguments):
            let errorMessages = errors.map { $0.errorDescription ?? "Unknown error" }.joined(separator: "\n")
            let argsJson = formatArguments(receivedArguments)
            return "Validation failed for tool \"\(toolName)\":\n\(errorMessages)\n\nReceived arguments:\n\(argsJson)"
        case .schemaMissing(let name):
            return "Tool \"\(name)\" has no parameter schema"
        case .constrainedSampling(let message):
            return message
        }
    }
}

private func formatArguments(_ arguments: [String: AnyCodable]) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    if let data = try? encoder.encode(arguments),
       let json = String(data: data, encoding: .utf8) {
        return json
    }
    return String(describing: arguments)
}

/// Finds a tool by name and validates the tool call arguments against its JSON Schema.
/// - Parameters:
///   - tools: Array of tool definitions
///   - toolCall: The tool call from the LLM
/// - Returns: The validated (and potentially coerced) arguments
/// - Throws: ValidationError if tool is not found or validation fails
public func validateToolCall(tools: [AITool], toolCall: ToolCall) throws -> [String: AnyCodable] {
    guard let tool = tools.first(where: { $0.name == toolCall.name }) else {
        throw ValidationError.toolNotFound(toolCall.name)
    }
    return try validateToolArguments(tool: tool, toolCall: toolCall)
}

/// Validates tool call arguments against the tool's JSON Schema.
/// - Parameters:
///   - tool: The tool definition with JSON Schema
///   - toolCall: The tool call from the LLM
/// - Returns: The validated (and potentially coerced) arguments
/// - Throws: ValidationError with formatted message if validation fails
public func validateToolArguments(tool: AITool, toolCall: ToolCall) throws -> [String: AnyCodable] {
    guard tool.name == toolCall.name else {
        throw ValidationError.toolNotFound(toolCall.name)
    }

    // Convert tool parameters (AnyCodable) to a schema dictionary
    let schema = extractSchema(from: tool.parameters)

    // If no schema or empty schema, trust the arguments
    if schema.isEmpty {
        return toolCall.arguments
    }

    // Convert arguments to plain dictionary for validation
    let argumentsDict = extractValues(from: toolCall.arguments)

    // Validate using JSON Schema validator
    let validator = JSONSchemaValidator.shared
    let result = validator.validate(argumentsDict, against: schema, path: "root", coerceTypes: true)

    if result.isValid {
        // Return coerced values if available
        if let coerced = result.coercedValue as? [String: Any] {
            return convertToAnyCodable(coerced)
        }
        return toolCall.arguments
    }

    throw ValidationError.validationFailed(
        toolName: toolCall.name,
        errors: result.errors,
        receivedArguments: toolCall.arguments
    )
}

/// Extract a schema dictionary from AnyCodable parameters.
private func extractSchema(from parameters: [String: AnyCodable]) -> [String: Any] {
    var schema: [String: Any] = [:]

    for (key, value) in parameters {
        schema[key] = extractValue(from: value)
    }

    return schema
}

/// Extract a plain value from AnyCodable.
private func extractValue(from codable: AnyCodable) -> Any {
    let value = codable.value

    if value is NSNull {
        return NSNull()
    }

    if let dict = value as? [String: AnyCodable] {
        var result: [String: Any] = [:]
        for (k, v) in dict {
            result[k] = extractValue(from: v)
        }
        return result
    }

    if let array = value as? [AnyCodable] {
        return array.map { extractValue(from: $0) }
    }

    return value
}

/// Extract plain dictionary from AnyCodable arguments.
private func extractValues(from arguments: [String: AnyCodable]) -> [String: Any] {
    var result: [String: Any] = [:]
    for (key, value) in arguments {
        result[key] = extractValue(from: value)
    }
    return result
}

/// Convert a plain dictionary back to AnyCodable.
private func convertToAnyCodable(_ dict: [String: Any]) -> [String: AnyCodable] {
    dict.mapValues(AnyCodable.init)
}
