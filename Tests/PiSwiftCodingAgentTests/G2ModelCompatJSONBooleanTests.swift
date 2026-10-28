import Foundation
import Testing
import PiSwiftAI
import PiSwiftCodingAgent

private func g2ModelCompat(_ json: String) throws -> OpenAICompat? {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("g2-model-compat-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let config = "{\"providers\":{\"g2-local\":{\"baseUrl\":\"https://example.invalid/v1\",\"api\":\"openai-completions\",\"models\":[{\"id\":\"demo\",\"compat\":\(json)}]}}}"
    try Data(config.utf8).write(to: root.appendingPathComponent("models.json"))
    let registry = ModelRegistry(AuthStorage(":memory:"), root.path,
        modelsStore: InMemoryModelsStore(), networkEnabled: false)
    return try #require(registry.find("g2-local", "demo")).compat
}

@Test(arguments: [
    "supportsStore", "supportsDeveloperRole", "supportsReasoningEffort", "supportsUsageInStreaming",
    "requiresToolResultName", "requiresAssistantAfterToolResult", "requiresThinkingAsText", "requiresMistralToolIds",
    "supportsStrictMode", "supportsThinkingTokenBudget", "supportsLongCacheRetention", "sendSessionIdHeader",
    "supportsEagerToolInputStreaming", "sendSessionAffinityHeaders", "requiresReasoningContentOnAssistantMessages"
])
func g2ModelCompatFlagsRequireJSONBooleans(_ field: String) throws {
    for literal in ["0", "1", "false", "true"] {
        let compat = try g2ModelCompat("{\"\(field)\":\(literal)}")
        let encoded = try compat.map { try JSONDecoder().decode([String: AnyCodable].self, from: JSONEncoder().encode($0)) }
        let expected: Bool? = literal == "true" ? true : literal == "false" ? false : nil
        #expect(encoded?[field]?.value as? Bool == expected)
    }
}

@Test(arguments: ["allow_fallbacks", "require_parameters", "zdr", "enforce_distillable_text"])
func g2ModelRoutingFlagsRequireJSONBooleans(_ field: String) throws {
    for literal in ["0", "1", "false", "true"] {
        let compat = try g2ModelCompat("{\"openRouterRouting\":{\"\(field)\":\(literal)}}")
        let encoded = try compat?.openRouterRouting.map {
            try JSONDecoder().decode([String: AnyCodable].self, from: JSONEncoder().encode($0))
        }
        let expected: Bool? = literal == "true" ? true : literal == "false" ? false : nil
        #expect(encoded?[field]?.value as? Bool == expected)
    }
}
