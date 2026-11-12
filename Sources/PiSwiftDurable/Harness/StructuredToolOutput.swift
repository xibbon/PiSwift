import Foundation
import PiSwiftAI
import PiSwiftChord

/// Checks the program channel after hooks. Model output uses a separate contract.
internal func structuredOutputError(_ tool: ToolRegistration, _ result: ToolExecutionResult) throws -> String? {
    guard let schema = tool.structuredOutputSchema else {
        return result.structuredOutput == nil ? nil : "Tool \(tool.name) returned structuredOutput but declares no structuredOutputSchema"
    }
    guard let value = result.structuredOutput else {
        return result.isError == true ? nil : "Tool \(tool.name) returned no structuredOutput"
    }
    guard let error = try structuredSchemaIssue(value, schema: schema) else { return nil }
    return "Tool \(tool.name) returned structuredOutput that does not match its schema: \(error.path): \(error.message)"
}

/// The one no-coercion path shared with PiSwiftAI's pi-schema boundary.
private func structuredSchemaIssue(_ value: JSONValue, schema: JSONObject) throws -> SchemaValidationError? {
    try validateStructuredToolOutput(schemaJSON: structuredJSON(.object(schema)), valueJSON: structuredJSON(value))
}

/// Serializes nested JSON without using the small test worker's call stack.
private func structuredJSON(_ root: JSONValue) throws -> String {
    enum Item { case value(JSONValue), text(String) }
    var pending: [Item] = [.value(root)]
    var result = ""
    while let item = pending.popLast() {
        switch item {
        case .text(let text): result += text
        case .value(let value):
            switch value {
            case .null, .bool, .number, .string: result += try value.jsonText()
            case .array(let values):
                pending.append(.text("]"))
                for index in values.indices.reversed() {
                    pending.append(.value(values[index]))
                    if index > 0 { pending.append(.text(",")) }
                }
                pending.append(.text("["))
            case .object(let object):
                let members = Array(object)
                pending.append(.text("}"))
                for index in members.indices.reversed() {
                    let member = members[index]
                    pending.append(.value(member.value))
                    pending.append(.text(":"))
                    pending.append(.text(try JSONValue.string(member.key).jsonText()))
                    if index > 0 { pending.append(.text(",")) }
                }
                pending.append(.text("{"))
            }
        }
    }
    return result
}

/// A diagnostic entry point retained for Durable's schema conformance tests.
internal func durableStructuredSchemaError(_ value: JSONValue, schema: JSONObject) -> String? {
    do {
        guard let issue = try structuredSchemaIssue(value, schema: schema) else { return nil }
        return "\(issue.path): \(issue.message)"
    } catch { return error.localizedDescription }
}
