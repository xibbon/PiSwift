import Foundation
import Testing
import PiSwiftAI
@testable import PiSwiftCodingAgent

private struct ClassifierRegistryV110Fixture {
    let directory: URL
    let auth = AuthStorage(":memory:")

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("classifier-registry-v110-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("{\"providers\":{}}".utf8)
            .write(to: directory.appendingPathComponent("models.json"))
    }

    func registry() -> ModelRegistry {
        ModelRegistry(auth, directory.path, modelsStore: InMemoryModelsStore(), networkEnabled: false)
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }
}

@Suite(.timeLimit(.minutes(1))) struct ClassifierRegistryV110Tests {
    @Test(arguments: [false, true])
    func openAIDecisionsAvailabilityUsesCredentialType(oauth: Bool) async throws {
        let fixture = try ClassifierRegistryV110Fixture()
        defer { fixture.remove() }
        if oauth {
            fixture.auth.set("openai", credential: .oauth(OAuthCredential(
                access: "access", refresh: "refresh",
                expires: Date().timeIntervalSince1970 * 1_000 + 3_600_000
            )))
        } else {
            fixture.auth.set("openai", credential: .apiKey(ApiKeyCredential(key: "secret")))
        }
        let registry = fixture.registry()
        let classifier = try #require(registry.getModelOfType(.classifier, provider: "openai", modelId: "gpt-6-luna"))
        #expect(classifier.type == .classifier)
        let chat = try #require(registry.find("openai", "gpt-6-luna"))
        #expect(chat.api == .openAIResponses)

        let availableClassifiers = await registry.getAvailableOfType(.classifier, provider: "openai")
        #expect(availableClassifiers.map(\.id) == (oauth ? [] : ["gpt-6-luna"]))
        let allClassifiers = await registry.getAvailableOfType(.classifier)
        #expect(allClassifiers.contains { $0.provider == "openai" && $0.id == "gpt-6-luna" } == !oauth)
        let availableChat = await registry.getAvailableOfType(.chat, provider: "openai")
        #expect(availableChat.contains { $0.id == "gpt-6-luna" })
        for available in [await registry.getAllAvailable(provider: "openai"), await registry.getAllAvailable()] {
            #expect(available.contains { $0.provider == "openai" && $0.id == "gpt-6-luna" && $0.type == .classifier } == !oauth)
            #expect(available.contains { $0.provider == "openai" && $0.id == "gpt-6-luna" && $0.type == .chat })
        }
    }

    @Test func imageCheckRunsBeforeAuthAndExtensionClassifier() async throws {
        let fixture = try ClassifierRegistryV110Fixture()
        defer { fixture.remove() }
        let registry = fixture.registry()
        let provider = "classifier-v110-\(UUID().uuidString)"
        let marker = fixture.directory.appendingPathComponent("auth-resolved")
        let markerPath = marker.path.replacingOccurrences(of: "'", with: "'\\''")
        let calls = LockedState<[String?]>([])
        registry.registerProvider(HookProviderConfig(
            provider: provider, api: .openAICompletions, baseUrl: "https://example.invalid",
            apiKey: "!touch '\(markerPath)'; printf resolved-key",
            classifiers: [.typesafeSystemOne: { model, _, options in
                calls.withLock { $0.append(options?.apiKey) }
                return ClassifierResult(api: model.api, provider: model.provider, model: model.id)
            }],
            models: [.classifier(HookProviderClassifierModel(
                id: "text-only", api: .typesafeSystemOne, input: [.text], contextWindow: 1_000
            ))]
        ), sourceId: provider)
        guard case .classifier(let model)? = registry.getModelOfType(.classifier, provider: provider, modelId: "text-only") else {
            Issue.record("Expected a classifier model")
            return
        }
        let rejected = await registry.classify(model, context: ClassifierContext(
            state: [:], questions: [:], images: [ImageContent(data: "aW1hZ2U=", mimeType: "image/png")]
        ))
        #expect(rejected.stopReason == .error)
        #expect(rejected.errorMessage == "Model \(provider)/text-only does not accept image input")
        #expect(!FileManager.default.fileExists(atPath: marker.path))
        #expect(calls.withLock { $0.isEmpty })

        let accepted = await registry.classify(model, context: ClassifierContext(state: [:], questions: [:], images: []))
        #expect(accepted.stopReason == .stop)
        #expect(FileManager.default.fileExists(atPath: marker.path))
        #expect(calls.withLock { $0 } == ["resolved-key"])
    }

    @Test func imageCheckReturnsInputErrorWhenAuthIsMissing() async throws {
        let fixture = try ClassifierRegistryV110Fixture()
        defer { fixture.remove() }
        let registry = fixture.registry()
        let provider = "classifier-no-auth-v110-\(UUID().uuidString)"
        let calls = LockedState(0)
        registry.registerProvider(HookProviderConfig(
            provider: provider, api: .openAICompletions, baseUrl: "https://example.invalid",
            authHeader: true,
            classifiers: [.typesafeSystemOne: { model, _, _ in
                calls.withLock { $0 += 1 }
                return ClassifierResult(api: model.api, provider: model.provider, model: model.id)
            }],
            models: [.classifier(HookProviderClassifierModel(
                id: "text-only", api: .typesafeSystemOne, input: [.text], contextWindow: 1_000
            ))]
        ), sourceId: provider)
        guard case .classifier(let model)? = registry.getModelOfType(.classifier, provider: provider, modelId: "text-only") else {
            Issue.record("Expected a classifier model")
            return
        }
        let rejected = await registry.classify(model, context: ClassifierContext(
            state: [:], questions: [:], images: [ImageContent(data: "aW1hZ2U=", mimeType: "image/png")]
        ))
        #expect(rejected.stopReason == .error)
        #expect(rejected.errorMessage == "Model \(provider)/text-only does not accept image input")
        for context in [ClassifierContext(state: [:], questions: [:]), ClassifierContext(state: [:], questions: [:], images: [])] {
            let result = await registry.classify(model, context: context)
            #expect(result.stopReason == .error)
            #expect(result.errorMessage == "No API key found for \"\(provider)\"")
        }
        #expect(calls.withLock { $0 } == 0)
    }
}
