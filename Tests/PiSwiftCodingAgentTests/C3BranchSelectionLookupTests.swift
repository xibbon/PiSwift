import Testing
import PiSwiftAI
import PiSwiftCodingAgent

/// Port of v1.0.0 virtual-models.test.ts, getBranchSelection (#10198).
@Suite("C3 branch selection catalog lookups")
struct C3BranchSelectionLookupTests {
    private func model(_ id: String, provider: String = "faux", api: Api = .openAIResponses) -> Model {
        Model(id: id, name: id, api: api, provider: provider, baseUrl: "https://example.invalid",
              reasoning: false, input: [.text],
              cost: ModelCost(input: 0, output: 0, cacheRead: 0, cacheWrite: 0),
              contextWindow: 1_000, maxTokens: 100)
    }

    private func response(_ model: Model, stopReason: StopReason = .stop) -> AssistantMessage {
        AssistantMessage(content: [.text(TextContent(text: "ok"))], api: model.api,
                         provider: model.provider, model: model.id,
                         usage: Usage(input: 1, output: 1, cacheRead: 0, cacheWrite: 0, totalTokens: 2),
                         stopReason: stopReason)
    }

    private func select(_ session: SessionManager, models: [Model])
        -> (selection: (provider: String, modelId: String)?, lookups: [String]) {
        var lookups: [String] = []
        let selection = getBranchSelection(session.getBranch()) { provider, id in
            lookups.append("\(provider)/\(id)")
            return models.first { $0.provider == provider && $0.id == id }
        }
        return (selection, lookups)
    }

    @Test("Only the last model change needs a catalog lookup")
    func looksUpOnlyLastModelChange() {
        let small = model("small")
        let large = model("large")
        let virtual = model("auto", provider: "router", api: VIRTUAL_MODEL_API)
        let physicalSession = SessionManager.inMemory()
        physicalSession.appendModelChange(small.provider, small.id)
        for _ in 0..<100 { physicalSession.appendMessage(.assistant(response(large))) }
        let physical = select(physicalSession, models: [small, large, virtual])
        #expect(physical.selection?.provider == "faux")
        #expect(physical.selection?.modelId == "large")
        #expect(physical.lookups == ["faux/small"])

        let routedSession = SessionManager.inMemory()
        routedSession.appendModelChange(small.provider, small.id)
        routedSession.appendMessage(.assistant(response(small)))
        routedSession.appendModelChange(virtual.provider, virtual.id)
        for _ in 0..<100 { routedSession.appendMessage(.assistant(response(large))) }
        let routed = select(routedSession, models: [small, large, virtual])
        #expect(routed.selection?.provider == "router")
        #expect(routed.selection?.modelId == "auto")
        #expect(routed.lookups == ["router/auto"])
    }

    @Test("A last model change with no response needs no catalog lookup")
    func usesLastModelChangeWithoutLaterResponses() {
        let small = model("small")
        let virtual = model("auto", provider: "router", api: VIRTUAL_MODEL_API)
        let session = SessionManager.inMemory()
        session.appendModelChange(virtual.provider, virtual.id)
        session.appendMessage(.assistant(response(small)))
        session.appendModelChange(small.provider, small.id)
        let result = select(session, models: [small, virtual])
        #expect(result.selection?.provider == "faux")
        #expect(result.selection?.modelId == "small")
        #expect(result.lookups.isEmpty)
    }

    @Test("A physical response with no model change needs no catalog lookup")
    func usesLatestPhysicalResponseWithoutModelChange() {
        let small = model("small")
        let large = model("large")
        let virtual = model("auto", provider: "router", api: VIRTUAL_MODEL_API)
        let session = SessionManager.inMemory()
        session.appendMessage(.assistant(response(small)))
        session.appendMessage(.assistant(response(large)))
        // Failed routing leaves the virtual model on its message.
        session.appendMessage(.assistant(response(virtual, stopReason: .error)))
        let result = select(session, models: [small, large, virtual])
        #expect(result.selection?.provider == "faux")
        #expect(result.selection?.modelId == "large")
        #expect(result.lookups.isEmpty)
    }
}
