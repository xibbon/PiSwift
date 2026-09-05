import Foundation
import Testing
import PiSwiftAI
import PiSwiftCodingAgent

@Suite struct ParseCompatKeyTableTests {
    private static var extendedValues: [String: Any] {
        [
            "supportsFinishReason": false,
            "vllmPriority": 7,
            "supportsAdditionalTools": true,
            "supportsMaxOutputTokens": false,
            "supportsMidConvoEffort": true,
            "thinkingTokenBudgetField": "thinking_budget",
            "supportsOpenAIGrammarTools": true,
            "supportsToolSearch": false,
            "supportsTemperature": false,
            "supportsCacheControlOnTools": true,
            "forceAdaptiveThinking": true,
            "allowEmptySignature": false,
            "supportsStrictTools": true,
            "supportsToolReferences": false,
            "deferredToolsMode": "kimi",
            "sessionAffinityFormat": "openai-nosession",
            "chatTemplateKwargs": ["enable_thinking": true, "budget": 512],
            "chatTemplateArgs": ["effort": ["$var": "thinking.effort", "omitWhenOff": true]],
        ]
    }

    private static let baseKeys: Set<String> = [
        "supportsStore", "supportsDeveloperRole", "supportsReasoningEffort",
        "supportsUsageInStreaming", "maxTokensField", "requiresToolResultName",
        "requiresAssistantAfterToolResult", "requiresThinkingAsText", "requiresMistralToolIds",
        "thinkingFormat", "supportsStrictMode", "supportsThinkingTokenBudget",
        "openRouterRouting", "vercelGatewayRouting", "supportsLongCacheRetention",
        "sendSessionIdHeader", "supportsEagerToolInputStreaming", "cacheControlFormat",
        "sendSessionAffinityHeaders", "requiresReasoningContentOnAssistantMessages",
    ]

    // The parser does not accept these existing fields. Keep that behavior.
    private static let excludedKeys: Set<String> = [
        "reasoningEffortMap", "zaiToolStream", "supportsExplicitPromptCacheMode",
        "allowedFallbackModels",
    ]

    private static func declaredExtendedKeys() throws -> Set<String> {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/PiSwiftCodingAgent/Core/ModelRegistry.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let declaration = try #require(
            source.range(of: "private let extendedCompatKeys: Set<String> = ["),
            "The private compat key table must exist."
        )
        let tail = source[declaration.upperBound...]
        let end = try #require(tail.firstIndex(of: "]"), "The compat key table must have an end.")
        let entries = tail[..<end].split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        try #require(!entries.isEmpty && entries.allSatisfy { $0.hasPrefix("\"") && $0.hasSuffix("\"") },
                     "The compat key table must contain string literals.")
        let keys = Set(entries.map { String($0.dropFirst().dropLast()) })
        #expect(keys.count == entries.count)
        return keys
    }

    private static func parse(_ compat: [String: Any]) throws -> OpenAICompat? {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pi-compat-key-table-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let configuration: [String: Any] = [
            "providers": [
                "compat-key-table": [
                    "api": "openai-completions",
                    "baseUrl": "https://example.invalid/v1",
                    "models": [["id": "test-model", "compat": compat]],
                ],
            ],
        ]
        try JSONSerialization.data(withJSONObject: configuration)
            .write(to: directory.appendingPathComponent("models.json"))
        let registry = ModelRegistry(AuthStorage(":memory:"), directory.path)
        return try #require(registry.find("compat-key-table", "test-model")).compat
    }

    @Test func everyExtendedKeyHasAFieldAndParses() throws {
        let keys = try Self.declaredExtendedKeys()
        let fieldNames = Set(Mirror(reflecting: OpenAICompat()).children.compactMap(\.label))
        #expect(keys == Set(Self.extendedValues.keys))
        #expect(fieldNames == keys.union(Self.baseKeys).union(Self.excludedKeys))
        #expect(keys.isDisjoint(with: Self.baseKeys.union(Self.excludedKeys)))

        var input = Self.extendedValues
        input["supportsStore"] = false
        let parsed = try #require(try Self.parse(input))
        for field in Mirror(reflecting: parsed).children where keys.contains(field.label ?? "") {
            #expect(!Mirror(reflecting: field.value).children.isEmpty,
                    "The field \(field.label ?? "") must not be nil.")
        }
        let encoded = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(parsed)) as? [String: Any])
        #expect(NSDictionary(dictionary: encoded) == NSDictionary(dictionary: input))
    }

    @Test(arguments: Array(ParseCompatKeyTableTests.extendedValues.keys).sorted())
    func eachExtendedKeyParsesWithoutBaseKeys(_ key: String) throws {
        let value = try #require(Self.extendedValues[key])
        let parsed = try #require(try Self.parse([key: value]))
        let encoded = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(parsed)) as? [String: Any])
        #expect(NSDictionary(dictionary: encoded) == NSDictionary(dictionary: [key: value]))
    }

    @Test func emptyObjectReturnsNil() throws {
        #expect(try Self.parse([:]) == nil)
    }

    @Test func invalidExtendedValueKeepsBaseFieldsAndDropsExtendedFields() throws {
        let parsed = try #require(try Self.parse([
            "supportsStore": false,
            "supportsFinishReason": true,
            "vllmPriority": "invalid",
        ]))
        #expect(parsed.supportsStore == false)
        #expect(parsed.supportsFinishReason == nil)
        #expect(parsed.vllmPriority == nil)
    }

    @Test func invalidBaseValueDoesNotDiscardExtendedFields() throws {
        let parsed = try #require(try Self.parse([
            "maxTokensField": "invalid",
            "supportsFinishReason": false,
        ]))
        #expect(parsed.maxTokensField == nil)
        #expect(parsed.supportsFinishReason == false)
    }
}
