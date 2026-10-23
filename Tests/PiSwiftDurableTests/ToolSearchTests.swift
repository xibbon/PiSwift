import PiSwiftAI
import PiSwiftChord
import PiSwiftDurable
import Testing

private func searchApi(_ candidates: [ToolRegistration]) throws -> ToolExecutionApi {
    var api = try toolTestApi()
    let agent = Agent(deferred: candidates)
    api.agent = { _ in agent }
    return api
}

private func searchCandidate(_ name: String, description: String, parameters: JSONObject = ["type": "object"]) throws -> ToolRegistration {
    try ToolRegistration(name: name, description: description, parameters: parameters, deferred: true) { _, _, _ in .init(output: []) }
}

@Suite struct ToolSearchTests {
    @Test func searchIsModelOnlyAndReplaySafe() throws {
        let tool = try createToolSearchTool()
        #expect(tool.name == TOOL_SEARCH_TOOL_NAME)
        #expect(tool.callers == [.model])
        #expect(tool.replay == .safe)
        #expect(tool.deferred == nil)
        let extensionValue = try createToolSearchExtension()
        #expect(extensionValue.name == "tool-search")
        #expect(extensionValue.tools.map(\.name) == ["tool_search"])
        let registry = createRegistry()
        try registry.install(extensionValue)
        let agent = resolveAgent(snapshot: registry.snapshot())
        #expect(agent.tools.map(\.name) == ["tool_search"])
        #expect(agent.callable.isEmpty)
        #expect(agent.deferred.isEmpty)
    }

    @Test(arguments: ["", " \n\t", "\u{FEFF}\u{00A0}\u{2028}\u{3000}"])
    func blankQueryFails(query: String) async throws {
        await #expect(throws: ToolSearchError.emptyQuery) {
            try await createToolSearchTool().execute(["query": .string(query)], searchApi([]), .background)
        }
    }

    @Test(arguments: [0.0, -1.0, 0.5, 1.5, -3.5])
    func invalidLimitFails(limit: Double) async throws {
        await #expect(throws: ToolSearchError.invalidLimit) {
            try await createToolSearchTool().execute(["query": "issue", "limit": .number(limit)], searchApi([]), .background)
        }
    }

    @Test func schemaRejectsInvalidArgumentTypes() async throws {
        let values: [JSONValue] = [[:], ["query": .null], ["query": []], ["query": [:]],
            ["query": "issue", "limit": "one"], ["query": "issue", "limit": false]]
        for value in values {
            await #expect(throws: (any Error).self) {
                try await createToolSearchTool().execute(value, searchApi([]), .background)
            }
        }
        #expect(String(describing: ToolSearchError.emptyQuery) == "query must not be empty")
        #expect(String(describing: ToolSearchError.invalidLimit) == "limit must be a positive integer")
    }

    @Test func argumentsUseTheExistingToolValidationRules() async throws {
        let candidate = try searchCandidate("issue_42", description: "Issue")
        let tool = try createToolSearchTool()
        let api = try searchApi([candidate])
        for value: JSONValue in [["query": 42], ["query": "issue", "limit": "1"], ["query": "issue", "limit": .null]] {
            let result = try await tool.execute(value, api, .background)
            #expect(result.control?.addTools == ["issue_42"])
        }
    }

    @Test func defaultLimitIsEightAndEqualRanksKeepCatalogOrder() async throws {
        let candidates = try (1...10).map { try searchCandidate("candidate_\($0)", description: "  issue\r\nSecond line  ") }
        let tool = try createToolSearchTool()
        let api = try searchApi(candidates)
        let first = try await tool.execute(["query": "issue"], api, .background)
        let expected = Array(candidates.prefix(8)).map(\.name)
        #expect(DEFAULT_TOOL_SEARCH_LIMIT == 8)
        #expect(try first.details?.decode(ToolSearchToolDetails.self) == .init(loaded: expected))
        #expect(first.control == .init(addTools: expected))
        #expect(toolResultText(first) == "Loaded 8 tools. They are available from your next call:\n" +
            expected.map { "- \($0): issue" }.joined(separator: "\n"))
        let replay = try await tool.execute(["query": "issue"], api, .background)
        #expect(replay.details == first.details)
        #expect(replay.control == first.control)
        #expect(toolResultText(replay) == toolResultText(first))
        let large = try await tool.execute(["query": "issue", "limit": 1e20], api, .background)
        #expect(large.control?.addTools == candidates.map(\.name))
    }

    @Test func metadataSearchTraversesSchemaAndUsesCurrentDeclaration() async throws {
        var candidate = try searchCandidate("plain", description: "Neutral", parameters: [
            "type": "object", "description": "rootdescription", "properties": [
                "propertyneedle": ["description": "propertydescription"],
                "array": ["items": ["description": "itemdescription"]],
                "choice": ["anyOf": [["description": "anydescription"]],
                           "oneOf": [["description": "onedescription"]],
                           "allOf": [["description": "alldescription"]]]
            ]
        ])
        candidate.declaration.parameters["description"] = AnyCodable("currentdescription")
        let ignored = try searchCandidate("ignored", description: "Neutral", parameters: [
            "type": "object", "default": "defaultneedle", "enum": ["enumneedle"],
            "properties": ["flag": ["default": "ignoredneedle"]]
        ])
        let api = try searchApi([candidate, ignored])
        let tool = try createToolSearchTool()
        for query in ["plain", "currentdescription", "propertyneedle", "propertydescription", "itemdescription", "anydescription", "onedescription", "alldescription"] {
            let result = try await tool.execute(["query": .string(query)], api, .background)
            #expect(result.control?.addTools == ["plain"], "Metadata query: \(query)")
        }
        for query in ["defaultneedle", "enumneedle", "ignoredneedle", "rootdescription", "the and", "\u{0085}"] {
            let result = try await tool.execute(["query": .string(query)], api, .background)
            #expect(result.details == ["loaded": []])
            #expect(result.control == nil)
            #expect(toolResultText(result) == "No matching tools found.")
        }
    }
}
