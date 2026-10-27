import Testing
@testable import PiSwiftAI

@Suite("Client identity OpenCode sessions")
struct ClientIdentityOpenCodeTests {
    @Test func openCodeSessionRequiresNonemptySessionAndExactTarget() {
        func model(provider: String = "custom", baseUrl: String = "https://opencode.ai/zen/v1") -> Model {
            Model(id: "chat", name: "Test", api: .openAICompletions, provider: provider,
                baseUrl: baseUrl, reasoning: false, input: [.text],
                cost: ModelCost(input: 0, output: 0, cacheRead: 0, cacheWrite: 0), contextWindow: 8192, maxTokens: 1024)
        }
        #expect(openCodeSessionHeaders(model: model(), sessionId: "", headers: nil) == nil)
        #expect(openCodeSessionHeaders(model: model(), sessionId: nil, headers: nil) == nil)
        #expect(openCodeSessionHeaders(model: model(baseUrl: "https://opencode.ai.example/v1"), sessionId: "session", headers: nil) == nil)
        #expect(openCodeSessionHeaders(model: model(baseUrl: "https://gateway.example/opencode.ai"), sessionId: "session", headers: nil) == nil)
        #expect(providerHeaderValue(openCodeSessionHeaders(model: model(provider: "opencode-go", baseUrl: "https://gateway.example"), sessionId: "session", headers: nil), name: "x-opencode-session") == "session")
    }

    @Test func customOpenCodeKeepsOverridesAndDeletion() {
        let model = Model(id: "chat", name: "Test", api: .openAICompletions, provider: "custom",
            baseUrl: "https://opencode.ai/zen/v1", reasoning: false, input: [.text],
            cost: ModelCost(input: 0, output: 0, cacheRead: 0, cacheWrite: 0), contextWindow: 8192, maxTokens: 1024)
        #expect(providerHeaderValue(openCodeSessionHeaders(model: model, sessionId: "session-1", headers: nil), name: "x-opencode-session") == "session-1")
        #expect(providerHeaderValue(openCodeSessionHeaders(model: model, sessionId: "session-1", headers: ["X-OpenCode-Session": "configured"]), name: "x-opencode-session") == "configured")
        let deleted = openCodeSessionHeaders(model: model, sessionId: "session-1", headers: ["X-OpenCode-Session": nil])
        #expect(providerHeadersContain(deleted, name: "x-opencode-session"))
        #expect(providerHeaderValue(deleted, name: "x-opencode-session") == nil)
    }
}
