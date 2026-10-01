import Foundation
import Testing
import PiSwiftAI
import PiSwiftCodingAgent

private func c3ExtensionReply(_ model: Model) -> AssistantMessageEventStream {
    let stream = AssistantMessageEventStream()
    let message = AssistantMessage(
        content: [.text(TextContent(text: "custom provider response"))],
        api: model.api, provider: model.provider, model: model.id,
        usage: Usage(input: 1, output: 3, cacheRead: 0, cacheWrite: 0, totalTokens: 4),
        stopReason: .stop
    )
    stream.push(.textDelta(contentIndex: 0, delta: "custom provider response", partial: message))
    stream.push(.done(reason: .stop, message: message))
    stream.end(message)
    return stream
}

@Test(.timeLimit(.minutes(1)), arguments: [false, true])
func c3ExtensionRegistryStreamsWithResolvedAuth(simple: Bool) async throws {
    let auth = AuthStorage(":memory:")
    let registry = ModelRegistry(auth)
    let observed = LockedState<[String]>([])
    registry.registerProvider(HookProviderConfig(
        provider: "extension-provider", api: .openAICompletions,
        baseUrl: "https://example.invalid/v1", apiKey: "extension-key",
        streamSimple: { model, context, options in
            observed.withLock { values in
                values.append(options?.apiKey ?? "")
                values.append(context.messages.last?.role ?? "")
            }
            return c3ExtensionReply(model)
        },
        models: [HookProviderModel(id: "custom-model")]
    ), sourceId: "c3")
    let model = try #require(registry.find("extension-provider", "custom-model"))
    let context = Context(messages: [.user(UserMessage(content: .text("Hello")))])
    let stream = simple
        ? registry.streamSimple(model: model, context: context)
        : registry.stream(model: model, context: context)
    var deltas: [String] = []
    for await event in stream {
        if case .textDelta(_, let delta, _) = event { deltas.append(delta) }
    }
    let result = await stream.result()
    #expect(observed.withLock { $0 } == ["extension-key", "user"])
    #expect(deltas == ["custom provider response"])
    #expect(result.stopReason == .stop)
    guard case .some(.text(let text)) = result.content.first else {
        Issue.record("Expected custom provider text")
        return
    }
    #expect(text.text == "custom provider response")
}

@Test func c3ExtensionToolWithoutParametersFailsAtRegistration() {
    let registered = LockedState(false)
    let registrationError = LockedState<String?>(nil)
    let result = ExtensionLoader.load(
        InlineExtension(name: "missing-parameters") { api in
            let registration = api.registerTool(CustomTool(
                name: "noop", label: "No-op", description: "Do nothing",
                execute: { _, _, _, _, _ in CustomToolResult(content: []) }
            ))
            registered.withLock { $0 = api.tools["noop"] != nil }
            if case .failure(let error) = registration {
                registrationError.withLock { $0 = error.localizedDescription }
            }
        },
        cwd: FileManager.default.temporaryDirectory.path,
        eventBus: createEventBus()
    )
    #expect(result.hook == nil)
    #expect(registered.withLock { $0 } == false)
    #expect(registrationError.withLock { $0 }?.contains("must define an object parameter schema") == true)
    #expect(result.error?.localizedDescription.contains("must define an object parameter schema") == true)
}

@Test func c3LateToolRegistrationReportsMissingSchema() {
    let apiBox = LockedState<HookAPI?>(nil)
    let result = ExtensionLoader.load(
        InlineExtension(name: "late-schema") { api in apiBox.withLock { $0 = api } },
        cwd: FileManager.default.temporaryDirectory.path,
        eventBus: createEventBus()
    )
    guard let api = apiBox.withLock({ $0 }), let hook = result.hook else {
        Issue.record("Expected loaded extension")
        return
    }
    defer { hook.dispose() }
    let registration = api.registerTool(CustomTool(
        name: "late-noop", label: "Late no-op", description: "Do nothing",
        execute: { _, _, _, _, _ in CustomToolResult(content: []) }
    ))
    guard case .failure(let error) = registration else {
        Issue.record("Expected registration error")
        return
    }
    #expect(error.localizedDescription.contains("must define an object parameter schema"))
    #expect(hook.currentTools()["late-noop"] == nil)
}

@Test func c3ExtensionToolGuidelinesArePublicMetadata() throws {
    let tool = CustomTool(
        name: "review", label: "Review", description: "Review files", parameters: [:],
        execute: { _, _, _, _, _ in CustomToolResult(content: []) },
        promptGuidelines: ["Read the diff first."]
    )
    #expect(tool.promptGuidelines == ["Read the diff first."])
    let data = Data(#"{"name":"review","label":"Review","description":"Review files","parameters":{"type":"object"},"promptGuidelines":["Read the diff first."]}"#.utf8)
    let definition = try JSONDecoder().decode(ToolDefinition.self, from: data)
    #expect(definition.promptGuidelines == ["Read the diff first."])
}

@Test func c3ExtensionToolGuidelinesAppearOnlyWhileToolIsActive() throws {
    let tool = CustomTool(
        name: "review", label: "Review", description: "Review files", parameters: [:],
        execute: { _, _, _, _, _ in CustomToolResult(content: []) },
        promptGuidelines: ["  Read the diff first.  ", "Read the diff first."]
    )
    let options = BuildSystemPromptOptions(
        selectedToolNames: [tool.name], cwd: "/tmp", contextFiles: [], skills: [],
        toolGuidelines: [tool.name: tool.promptGuidelines ?? []]
    )
    let activeRules = try buildSystemPromptSections(options)["rules"] ?? ""
    #expect(activeRules.components(separatedBy: "Read the diff first.").count == 2)

    var inactiveOptions = options
    inactiveOptions.selectedToolNames = []
    let inactiveRules = try buildSystemPromptSections(inactiveOptions)["rules"] ?? ""
    #expect(!inactiveRules.contains("Read the diff first."))
}
