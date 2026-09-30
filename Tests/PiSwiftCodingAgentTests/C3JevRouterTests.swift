import Foundation
import Testing
import PiSwiftAI
import PiSwiftCodingAgent

private struct C3JevState: Sendable {
    var phase: String
    var model: String

    init(phase: String, model: String) {
        self.phase = phase
        self.model = model
    }

    init?(_ value: AnyCodable?) {
        guard let object = value?.value as? [String: Any],
              let phase = object["phase"] as? String,
              let model = object["model"] as? String else { return nil }
        self.phase = phase
        self.model = model
    }

    var encoded: AnyCodable { AnyCodable(["phase": phase, "model": model]) }
}

/// Swift fixture for the upstream `examples/extensions/jev-router.ts` route.
private func c3RegisterJevRouter(_ registry: ModelRegistry) throws {
    let provider = "openai-codex"
    let sol = "gpt-5.6-sol"
    let terra = "gpt-5.6-terra"
    let luna = "gpt-5.6-luna"

    try registry.registerVirtualModel(VirtualModelDefinition(
        provider: "jev", id: "auto", name: "Auto (Jev)",
        thinkingLevels: [.low, .medium, .high, .xhigh],
        contextWindow: 272_000, maxTokens: 128_000,
        route: { request in
            func routeTo(_ id: String, state: C3JevState? = nil) throws -> ModelRoute {
                guard let model = registry.find(provider, id) else {
                    throw C3JevError.missingModel(id)
                }
                return ModelRoute(model: model, thinkingLevel: request.thinkingLevel, state: state?.encoded)
            }

            if request.reason == .direct { return try routeTo(luna) }
            if let state = C3JevState(request.state) {
                let lastUserIndex = request.messages.lastIndex { $0.role == "user" } ?? -1
                let edited = request.messages.dropFirst(lastUserIndex + 1).contains { message in
                    guard case .toolResult(let result) = message else { return false }
                    return (result.toolName == "edit" || result.toolName == "write") && !result.isError
                }
                if state.phase == "planning" && edited {
                    return try routeTo(luna, state: C3JevState(phase: "implementation", model: luna))
                }
                return try routeTo(state.model)
            }

            // Keep an existing planning model when the selected model changes to jev/auto.
            let previous = request.previous?.model
            let planning: String
            if previous?.provider == provider && (previous?.id == sol || previous?.id == terra) {
                planning = previous!.id
            } else if case .classifier(let classifier)? = registry.getModelOfType(
                .classifier, provider: "typesafe", modelId: "jev-latest") {
                let userText = request.messages.reversed().compactMap { message -> String? in
                    guard case .user(let user) = message else { return nil }
                    switch user.content {
                    case .text(let text): return text
                    case .blocks(let blocks):
                        return blocks.compactMap { block -> String? in
                            if case .text(let text) = block { return text.text }
                            return nil
                        }.joined(separator: "\n")
                    }
                }.first ?? ""
                let prompt = String(userText.prefix(16_000))
                let result = await registry.classify(classifier, context: ClassifierContext(
                    state: ["prompt": AnyCodable(prompt)], questions: [
                        "complexity": .choice(
                            instructions: "How demanding is the software engineering work requested in `prompt`?",
                            criteria: ["standard": "Ordinary work", "complex": "Hard work"])
                    ]), options: ClassifierOptions(signal: request.signal))
                if result.stopReason == .stop,
                   case .choice(_, let probabilities, _)? = result.answers["complexity"],
                   (probabilities["complex"] ?? 0) >= 0.5 {
                    planning = sol
                } else {
                    planning = terra
                }
            } else {
                planning = terra
            }
            return try routeTo(planning, state: C3JevState(phase: "planning", model: planning))
        }), sourceId: "jev-router")
}

private enum C3JevError: Error { case missingModel(String) }

private func c3JevRegistry(complexity: Double, classifierCalls: LockedState<[String]>) throws -> ModelRegistry {
    let registry = ModelRegistry(AuthStorage(":memory:"))
    registry.registerProvider(HookProviderConfig(
        provider: "openai-codex", api: .openAIResponses, baseUrl: "https://example.invalid/v1",
        apiKey: "codex-key", models: [
            HookProviderModel(id: "gpt-5.6-sol", reasoning: true),
            HookProviderModel(id: "gpt-5.6-terra", reasoning: true),
            HookProviderModel(id: "gpt-5.6-luna", reasoning: true)
        ]), sourceId: "codex")
    registry.registerProvider(HookProviderConfig(
        provider: "typesafe", api: .openAIResponses, baseUrl: "https://example.invalid/v1",
        apiKey: "typesafe-key", classifiers: [.typesafeSystemOne: { model, context, _ in
            classifierCalls.withLock { $0.append(context.state["prompt"]?.value as? String ?? "") }
            return ClassifierResult(api: model.api, provider: model.provider, model: model.id,
                answers: ["complexity": .choice(choice: complexity >= 0.5 ? "complex" : "standard",
                                                 probabilities: ["standard": 1 - complexity, "complex": complexity],
                                                 confidence: max(complexity, 1 - complexity))])
        }], models: [.classifier(HookProviderClassifierModel(
            id: "jev-latest", api: .typesafeSystemOne, contextWindow: 64_000))]), sourceId: "typesafe")
    try c3RegisterJevRouter(registry)
    return registry
}

private func c3JevToolResult(_ name: String, failed: Bool = false) -> Message {
    .toolResult(ToolResultMessage(toolCallId: UUID().uuidString, toolName: name,
                                  content: [.text(TextContent(text: "done"))], isError: failed))
}

@Test func jevRouterClassifiesComplexWorkAndSwitchesAfterFirstEdit() async throws {
    let calls = LockedState<[String]>([])
    let registry = try c3JevRegistry(complexity: 0.8, classifierCalls: calls)
    let virtual = try #require(registry.find("jev", "auto"))
    let user: Message = .user(UserMessage(content: .text("Refactor the cache layer.")))

    let first = try await registry.resolveVirtualModel(virtual, messages: [user], reason: .user,
                                                        thinkingLevel: .high)
    #expect(first.model.id == "gpt-5.6-sol")
    #expect(first.thinkingLevel == .high)
    #expect(C3JevState(first.state)?.phase == "planning")
    #expect(calls.withLock { $0 } == ["Refactor the cache layer."])

    let read = try await registry.resolveVirtualModel(
        virtual, messages: [user, c3JevToolResult("read")], reason: .continuation,
        thinkingLevel: .high, state: first.state)
    #expect(read.model.id == "gpt-5.6-sol")
    #expect(read.state == nil)

    let edited = try await registry.resolveVirtualModel(
        virtual, messages: [user, c3JevToolResult("read"), c3JevToolResult("edit")],
        reason: .continuation, thinkingLevel: .high, state: first.state)
    #expect(edited.model.id == "gpt-5.6-luna")
    #expect(C3JevState(edited.state)?.phase == "implementation")

    let next = try await registry.resolveVirtualModel(
        virtual, messages: [.user(UserMessage(content: .text("Also add tests.")))], reason: .user,
        thinkingLevel: .high, state: edited.state)
    #expect(next.model.id == "gpt-5.6-luna")
    #expect(calls.withLock { $0 }.count == 1)
    let direct = try await registry.resolveVirtualModel(virtual, messages: [user], reason: .direct,
                                                         thinkingLevel: .high)
    #expect(direct.model.id == "gpt-5.6-luna")
    #expect(direct.state == nil)
}

@Test func jevRouterUsesTerraForStandardWorkAndIgnoresFailedEdits() async throws {
    let calls = LockedState<[String]>([])
    let registry = try c3JevRegistry(complexity: 0.2, classifierCalls: calls)
    let virtual = try #require(registry.find("jev", "auto"))
    let user: Message = .user(UserMessage(content: .text("Add a verbose flag.")))
    let first = try await registry.resolveVirtualModel(virtual, messages: [user], reason: .user,
                                                        thinkingLevel: .low)
    #expect(first.model.id == "gpt-5.6-terra")

    let failedEdit = try await registry.resolveVirtualModel(
        virtual, messages: [user, c3JevToolResult("edit", failed: true)],
        reason: .continuation, thinkingLevel: .low, state: first.state)
    #expect(failedEdit.model.id == "gpt-5.6-terra")
    let wrote = try await registry.resolveVirtualModel(
        virtual, messages: [user, c3JevToolResult("edit", failed: true), c3JevToolResult("write")],
        reason: .continuation, thinkingLevel: .low, state: first.state)
    #expect(wrote.model.id == "gpt-5.6-luna")
    #expect(calls.withLock { $0 }.count == 1)
}
