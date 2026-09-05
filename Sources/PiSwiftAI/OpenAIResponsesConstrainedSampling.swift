import Foundation
import OpenAI

struct OpenAIResponsesGrammarTool: Sendable {
    let name: String
    let description: String
    let format: GrammarConstrainedSampling.Format
    let definition: String

    var payload: [String: Any] {
        [
            "type": "custom",
            "name": name,
            "description": description,
            "format": [
                "type": "grammar",
                "syntax": format.rawValue,
                "definition": definition,
            ],
        ]
    }
}

struct OpenAIResponsesConstrainedSamplingMiddleware: OpenAIMiddleware {
    let supportsStrictMode: Bool
    let grammarTools: [String: OpenAIResponsesGrammarTool]
    let grammarToolInputProperties: [String: String]

    func intercept(request: URLRequest) -> URLRequest {
        return rewritingOpenAIRequestBody(request) { payload in
            if var tools = payload["tools"] as? [[String: Any]] {
                for index in tools.indices {
                    guard let name = tools[index]["name"] as? String else { continue }
                    if let grammar = grammarTools[name] {
                        tools[index] = grammar.payload
                    } else if !supportsStrictMode {
                        tools[index].removeValue(forKey: "strict")
                    }
                }
                payload["tools"] = tools
            }

            if var input = payload["input"] as? [[String: Any]] {
                var grammarCallIds = Set<String>()
                for index in input.indices {
                    guard input[index]["type"] as? String == "function_call",
                          let name = input[index]["name"] as? String,
                          let inputProperty = grammarToolInputProperties[name],
                          let arguments = input[index]["arguments"] as? String,
                          let data = arguments.data(using: .utf8),
                          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                          let grammarInput = object[inputProperty] as? String else { continue }
                    if let callId = input[index]["call_id"] as? String {
                        grammarCallIds.insert(callId)
                    }
                    input[index]["type"] = "custom_tool_call"
                    input[index]["input"] = sanitizeSurrogates(grammarInput)
                    input[index].removeValue(forKey: "arguments")
                    input[index].removeValue(forKey: "status")
                }
                for index in input.indices {
                    guard input[index]["type"] as? String == "function_call_output",
                          let callId = input[index]["call_id"] as? String,
                          grammarCallIds.contains(callId) else { continue }
                    input[index]["type"] = "custom_tool_call_output"
                }
                payload["input"] = input
            }
            return true
        }
    }
}

func makeOpenAIResponsesConstrainedSamplingMiddleware(
    tools: [AITool]?,
    supportsStrictMode: Bool,
    supportsOpenAIGrammarTools: Bool
) throws -> OpenAIResponsesConstrainedSamplingMiddleware {
    var grammarTools: [String: OpenAIResponsesGrammarTool] = [:]
    for tool in tools ?? [] {
        if let grammar = try resolveGrammarConstrainedSampling(
            tool: tool,
            supportsOpenAIGrammarTools: supportsOpenAIGrammarTools
        ) {
            grammarTools[tool.name] = OpenAIResponsesGrammarTool(
                name: tool.name,
                description: tool.description,
                format: grammar.format,
                definition: grammar.definition
            )
        }
    }
    return OpenAIResponsesConstrainedSamplingMiddleware(
        supportsStrictMode: supportsStrictMode,
        grammarTools: grammarTools,
        grammarToolInputProperties: try createGrammarToolInputProperties(
            tools: tools,
            supportsOpenAIGrammarTools: supportsOpenAIGrammarTools
        )
    )
}

func validateResponsesGrammarReplay(
    messages: [Message],
    grammarToolInputProperties: [String: String]
) throws {
    guard !grammarToolInputProperties.isEmpty else { return }
    for message in messages {
        guard case .assistant(let assistant) = message else { continue }
        for case .toolCall(let toolCall) in assistant.content {
            guard let property = grammarToolInputProperties[toolCall.name] else { continue }
            _ = try getGrammarToolInput(
                toolName: toolCall.name,
                arguments: toolCall.arguments,
                inputProperty: property
            )
        }
    }
}

func openAIResponsesURL(baseUrl: String, provider: String = "") -> URL {
    var trimmed = baseUrl
    while trimmed.hasSuffix("/") { trimmed.removeLast() }
    if trimmed.hasSuffix("/responses") { return URL(string: trimmed)! }
    if provider.lowercased() == "github-copilot" || !(URL(string: trimmed)?.path ?? "").isEmpty {
        return URL(string: "\(trimmed)/responses")!
    }
    return URL(string: "\(trimmed)/v1/responses")!
}
