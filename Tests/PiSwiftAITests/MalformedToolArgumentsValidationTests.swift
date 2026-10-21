import Foundation
import Testing
import PiSwiftAI

// Port of v1.3.0 packages/ai/test/validation.test.ts:211-227.
@Test(arguments: [false, true])
func malformedArgumentsFailBeforeSchemaValidation(emptySchema: Bool) throws {
    let parameters: [String: AnyCodable] = emptySchema ? [:] : [
        "type": AnyCodable("object"),
        "properties": AnyCodable(["value": ["type": "string"]]),
    ]
    let tool = AITool(name: "echo", description: "Echo tool", parameters: parameters)
    let diagnostic = "Invalid JSON\n\nReceived arguments:\n{\"value\":"
    let call = ToolCall(id: "tool-1", name: "echo", arguments: [:], argumentsError: diagnostic)

    do {
        _ = try validateToolArguments(tool: tool, toolCall: call)
        Issue.record("Malformed arguments passed validation")
    } catch let error as ValidationError {
        guard case .invalidArguments(let name, let message) = error else {
            Issue.record("Expected an invalid arguments error")
            return
        }
        #expect(name == "echo")
        #expect(message == diagnostic)
        #expect(error.localizedDescription == "Invalid arguments for tool \"echo\": \(diagnostic)")
    }
}

@Test func malformedArgumentsFailBeforeToolNameCheck() {
    let tool = AITool(name: "other", description: "Other tool", parameters: [:])
    let call = ToolCall(id: "tool-1", name: "echo", arguments: [:], argumentsError: "Invalid JSON")
    #expect(throws: ValidationError.self) {
        do {
            _ = try validateToolArguments(tool: tool, toolCall: call)
        } catch let error as ValidationError {
            #expect(error.errorDescription == "Invalid arguments for tool \"echo\": Invalid JSON")
            throw error
        }
    }
}

// Upstream validation.ts:318 checks a nonempty diagnostic.
@Test func emptyArgumentDiagnosticDoesNotRejectAValidCall() throws {
    let call = ToolCall(id: "empty-error", name: "optional", arguments: [:], argumentsError: "")
    let tool = AITool(name: "optional", description: "Optional arguments", parameters: [:])
    #expect(try validateToolArguments(tool: tool, toolCall: call).isEmpty)
}
