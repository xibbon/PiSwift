import Foundation
import Testing
@testable import PiSwiftAI

private func toolReferenceModel(id: String, provider: String = "anthropic") -> Model {
    Model(
        id: id,
        name: id,
        api: .anthropicMessages,
        provider: provider,
        baseUrl: "https://api.anthropic.com",
        reasoning: false,
        input: [.text],
        cost: ModelCost(input: 0, output: 0, cacheRead: 0, cacheWrite: 0),
        contextWindow: 200_000,
        maxTokens: 8_192
    )
}

private func injectedAnthropicPayload(
    _ payload: [String: Any],
    deferredToolNames: Set<String>,
    toolResultAddedNames: [String: [String]] = [:],
    isOAuthToken: Bool = false
) throws -> [String: Any] {
    let body = try JSONSerialization.data(withJSONObject: payload)
    let updatedBody = try #require(injectAnthropicRequestBody(
        body: body,
        ttl: nil,
        metadataUserId: nil,
        deferredToolNames: deferredToolNames,
        toolResultAddedNames: toolResultAddedNames,
        isOAuthToken: isOAuthToken
    ))
    return try #require(JSONSerialization.jsonObject(with: updatedBody) as? [String: Any])
}

@Test(arguments: [
    ("claude-opus-4-5", "anthropic", true),
    ("claude-opus-4-1", "anthropic", false),
    ("claude-haiku-4-5", "anthropic", false),
    ("claude-opus-4-5", "openrouter", false),
    ("claude-sonnet-5", "anthropic", true),
    ("claude-opus-4-20250514", "anthropic", false),
])
func anthropicDefaultToolReferenceSupport(
    id: String,
    provider: String,
    expected: Bool
) {
    #expect(defaultSupportsToolReferences(model: toolReferenceModel(id: id, provider: provider)) == expected)
}

@Test func anthropicDeferredToolDefinitionsInjectDeferLoading() throws {
    let payload: [String: Any] = [
        "model": "claude-opus-4-5",
        "messages": [["role": "user", "content": "Hello"]],
        "tools": [
            ["name": "lookup", "input_schema": ["type": "object"]],
            ["name": "search", "input_schema": ["type": "object"]],
        ],
    ]

    let updated = try injectedAnthropicPayload(payload, deferredToolNames: ["search"])
    let tools = try #require(updated["tools"] as? [[String: Any]])

    #expect(tools[0]["defer_loading"] == nil)
    #expect(tools[1]["defer_loading"] as? Bool == true)
}

@Test func anthropicToolReferencesDisplaceContentAfterAllToolResultsAndDeduplicate() throws {
    let payload: [String: Any] = [
        "model": "claude-opus-4-5",
        "messages": [[
            "role": "user",
            "content": [
                [
                    "type": "tool_result",
                    "tool_use_id": "call-1",
                    "content": "first output",
                    "is_error": true,
                ],
                [
                    "type": "tool_result",
                    "tool_use_id": "call-2",
                    "content": "second output",
                    "is_error": false,
                ],
            ],
        ]],
    ]

    let updated = try injectedAnthropicPayload(
        payload,
        deferredToolNames: ["search"],
        toolResultAddedNames: [
            "call-1": ["search"],
            "call-2": ["search"],
        ]
    )
    let messages = try #require(updated["messages"] as? [[String: Any]])
    let blocks = try #require(messages[0]["content"] as? [[String: Any]])

    #expect(blocks.count == 3)
    #expect(blocks[0]["type"] as? String == "tool_result")
    #expect(blocks[0]["tool_use_id"] as? String == "call-1")
    #expect(blocks[0]["is_error"] as? Bool == true)
    let references = try #require(blocks[0]["content"] as? [[String: Any]])
    #expect(references.count == 1)
    #expect(references[0]["type"] as? String == "tool_reference")
    #expect(references[0]["tool_name"] as? String == "search")

    #expect(blocks[1]["type"] as? String == "tool_result")
    #expect(blocks[1]["content"] as? String == "second output")
    #expect(blocks[2]["type"] as? String == "text")
    #expect(blocks[2]["text"] as? String == "first output")
}

@Test func anthropicToolReferencesDeduplicateAcrossTheTranscript() throws {
    let payload: [String: Any] = [
        "model": "claude-opus-4-5",
        "messages": [
            [
                "role": "user",
                "content": [[
                    "type": "tool_result",
                    "tool_use_id": "call-1",
                    "content": "first output",
                    "is_error": false,
                ]],
            ],
            ["role": "assistant", "content": [["type": "text", "text": "Continue"]]],
            [
                "role": "user",
                "content": [[
                    "type": "tool_result",
                    "tool_use_id": "call-2",
                    "content": "second output",
                    "is_error": false,
                ]],
            ],
        ],
    ]

    let updated = try injectedAnthropicPayload(
        payload,
        deferredToolNames: ["search"],
        toolResultAddedNames: [
            "call-1": ["search"],
            "call-2": ["search"],
        ]
    )
    let messages = try #require(updated["messages"] as? [[String: Any]])
    let firstBlocks = try #require(messages[0]["content"] as? [[String: Any]])
    let secondBlocks = try #require(messages[2]["content"] as? [[String: Any]])

    #expect(firstBlocks[0]["content"] is [[String: Any]])
    #expect(secondBlocks[0]["content"] as? String == "second output")
    #expect(secondBlocks.count == 1)
}

@Test func anthropicOAuthToolReferencesUseClaudeCodeToolNames() throws {
    let payload: [String: Any] = [
        "model": "claude-opus-4-5",
        "messages": [[
            "role": "user",
            "content": [[
                "type": "tool_result",
                "tool_use_id": "call-1",
                "content": "read output",
                "is_error": false,
            ]],
        ]],
        // convertAnthropicTools has already normalized this fixed-type payload name.
        "tools": [["name": "Read", "input_schema": ["type": "object"]]],
    ]

    let updated = try injectedAnthropicPayload(
        payload,
        deferredToolNames: ["Read"],
        toolResultAddedNames: ["call-1": ["read"]],
        isOAuthToken: true
    )
    let tools = try #require(updated["tools"] as? [[String: Any]])
    let messages = try #require(updated["messages"] as? [[String: Any]])
    let blocks = try #require(messages[0]["content"] as? [[String: Any]])
    let references = try #require(blocks[0]["content"] as? [[String: Any]])

    #expect(tools[0]["name"] as? String == "Read")
    #expect(tools[0]["defer_loading"] as? Bool == true)
    #expect(references[0]["tool_name"] as? String == "Read")
}
