import CoreFoundation
import Foundation
import PiSwiftSchema
import Synchronization

/// Errors that can occur during tool validation.
public enum ValidationError: Error, LocalizedError {
    case toolNotFound(String)
    case invalidArguments(toolName: String, message: String)
    case validationFailed(toolName: String, errors: [SchemaValidationError], receivedArguments: [String: AnyCodable])
    case schemaMissing(String)
    case constrainedSampling(String)
    case unsupportedStrictSchema(String)

    public var errorDescription: String? {
        switch self {
        case .toolNotFound(let name):
            return "Tool \"\(name)\" not found"
        case .invalidArguments(let toolName, let message):
            return "Invalid arguments for tool \"\(toolName)\": \(message)"
        case .validationFailed(let toolName, let errors, let receivedArguments):
            let lines = errors.map { $0.errorDescription ?? "Unknown error" }.joined(separator: "\n")
            let source = toolArgumentsSource(receivedArguments)
            let json = toolSchemaObject(receivedArguments, source: validOrderSource(source, arguments: receivedArguments)).stringify(indent: 2)
            return "Validation failed for tool \"\(toolName)\":\n\(lines)\n\nReceived arguments:\n\(json)"
        case .schemaMissing(let name):
            return "Tool \"\(name)\" has no parameter schema"
        case .constrainedSampling(let message), .unsupportedStrictSchema(let message):
            return message
        }
    }
}

private struct CachedToolValidator {
    let parameters: [String: AnyCodable]
    let validator: CoercingValidator
}

private let toolValidators = Mutex([CachedToolValidator]())

private func validator(for tool: AITool) throws -> CoercingValidator {
    if let cached = toolValidators.withLock({ cache -> CoercingValidator? in
        guard let index = cache.lastIndex(where: { $0.parameters == tool.parameters }) else { return nil }
        let value = cache.remove(at: index)
        cache.append(value)
        return value.validator
    }) { return cached }
    let compiled = try compileCoercing(toolSchemaObject(tool.parameters),
                                       options: .init(formats: standardFormats, unresolvedRefs: .reject))
    return toolValidators.withLock { cache in
        if let index = cache.lastIndex(where: { $0.parameters == tool.parameters }) {
            return cache[index].validator
        }
        if cache.count == 256 { cache.removeFirst() }
        cache.append(CachedToolValidator(parameters: tool.parameters, validator: compiled))
        return compiled
    }
}

/// Finds a tool by name and validates its call arguments.
public func validateToolCall(tools: [AITool], toolCall: ToolCall) throws -> [String: AnyCodable] {
    guard let tool = tools.first(where: { $0.name == toolCall.name }) else {
        throw ValidationError.toolNotFound(toolCall.name)
    }
    return try validateToolArguments(tool: tool, toolCall: toolCall)
}

/// Validates and coerces tool arguments with pi-schema.
public func validateToolArguments(tool: AITool, toolCall: ToolCall) throws -> [String: AnyCodable] {
    if let error = toolCall.argumentsError, !error.isEmpty {
        throw ValidationError.invalidArguments(toolName: toolCall.name, message: error)
    }
    guard tool.name == toolCall.name else { throw ValidationError.toolNotFound(toolCall.name) }
    let compiled = try validator(for: tool)
    let order = validOrderSource(toolCall.argumentsJSON, arguments: toolCall.arguments)
    let input = toolSchemaObject(toolCall.arguments, source: order)
    switch compiled.parse(input) {
    case .ok(let result):
        if schemaEqual(result, input) { return toolCall.arguments }
        guard case .object(let object) = result else { return toolCall.arguments }
        return Dictionary(uniqueKeysWithValues: object.map { ($0.key, toolAnyCodable($0.value)) })
    case .failed(let issues):
        let errors = issues.map { SchemaValidationError(path: toolValidationPath($0.path), message: $0.message) }
        throw ValidationError.validationFailed(toolName: toolCall.name, errors: errors,
                                               receivedArguments: order == nil ? withoutArgumentOrder(toolCall.arguments) : toolCall.arguments)
    }
}

private func toolValidationPath(_ pointer: String) -> String {
    if pointer.isEmpty { return "root" }
    return pointer.dropFirst().split(separator: "/", omittingEmptySubsequences: false).map {
        $0.replacingOccurrences(of: "~1", with: "/").replacingOccurrences(of: "~0", with: "~")
    }.joined(separator: ".")
}

private func withoutArgumentOrder(_ arguments: [String: AnyCodable]) -> [String: AnyCodable] {
    arguments.mapValues { value in
        var result = value
        result.toolArgumentsSource = nil
        return result
    }
}

private func validOrderSource(_ source: OrderedJSON?, arguments: [String: AnyCodable]) -> SchemaValue? {
    guard let source, let parsed = try? SchemaValue.parse(json: source.serialized(escapeSlashes: false)),
          schemaEqual(parsed, toolSchemaObject(arguments)) else { return nil }
    return parsed
}

private func toolSchemaObject(_ values: [String: AnyCodable], source: SchemaValue? = nil) -> SchemaValue {
    var object = SchemaObject()
    let keys: [String]
    if case .object(let sourceObject) = source { keys = sourceObject.keys }
    else { keys = values.keys.sorted(by: utf16Less) }
    for key in keys {
        if let value = values[key] { object[key] = toolSchemaValue(value.value, depth: 0, source: schemaMember(source, key)) }
    }
    return .object(object)
}

private func utf16Less(_ left: String, _ right: String) -> Bool {
    left.utf16.lexicographicallyPrecedes(right.utf16)
}

private func schemaMember(_ source: SchemaValue?, _ key: String) -> SchemaValue? {
    guard case .object(let object) = source else { return nil }
    return object[key]
}

private func toolSchemaValue(_ value: Any, depth: Int, source: SchemaValue? = nil) -> SchemaValue {
    // Keep one more wrapper than the library limit so parse reports its depth issue.
    if depth > 513 { return .null }
    if value is NSNull { return .null }
    if let boolean = jsonBoolean(value) { return .bool(boolean) }
    if let number = value as? NSNumber { return .number(number.doubleValue) }
    if let string = value as? String { return .string(string) }
    if let array = value as? [Any] {
        let sourceValues: [SchemaValue]
        if case .array(let values) = source { sourceValues = values } else { sourceValues = [] }
        return .array(array.enumerated().map { index, item in
            toolSchemaValue(item, depth: depth + 1, source: sourceValues.indices.contains(index) ? sourceValues[index] : nil)
        })
    }
    if let dictionary = value as? [String: Any] {
        var object = SchemaObject()
        let keys: [String]
        if case .object(let sourceObject) = source { keys = sourceObject.keys }
        else { keys = dictionary.keys.sorted(by: utf16Less) }
        for key in keys {
            if let item = dictionary[key] { object[key] = toolSchemaValue(item, depth: depth + 1, source: schemaMember(source, key)) }
        }
        return .object(object)
    }
    return .string(String(describing: value))
}

private func toolAnyCodable(_ value: SchemaValue) -> AnyCodable {
    switch value {
    case .null: return AnyCodable(NSNull())
    case .bool(let boolean): return AnyCodable(boolean)
    case .number(let number):
        if number.isFinite, number.rounded() == number, abs(number) <= 9_007_199_254_740_992,
           let integer = Int(exactly: number) { return AnyCodable(integer) }
        return AnyCodable(number)
    case .string(let string): return AnyCodable(string)
    case .array(let array): return AnyCodable(array.map { toolAnyCodable($0).value })
    case .object(let object):
        return AnyCodable(Dictionary(uniqueKeysWithValues: object.map { ($0.key, toolAnyCodable($0.value).value) }))
    }
}
