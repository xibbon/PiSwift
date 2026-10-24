import Foundation
import Synchronization
import PiSwiftAI
import PiSwiftChord
import PiSwiftDurable
import PiSwiftDurableTesting
import Testing

private final class E10Models: CodemodeModels {
    let chat: FakeDurableModels
    let classifier = ClassifierModel(id: "judge", name: "Judge", api: .typesafeSystemOne, provider: "test", baseUrl: "https://example.invalid", input: [.text], cost: .init(input: 0, output: 0, cacheRead: 0, cacheWrite: 0), contextWindow: 1000, headers: ["authorization": "secret"])
    let painter = ImageModel(id: "painter", name: "Painter", api: .openrouterImages, provider: "test", baseUrl: "https://example.invalid", input: [.text], output: [.image], cost: .init(input: 0, output: 0, cacheRead: 0, cacheWrite: 0))
    struct State: Sendable { var classify = 0; var images = 0; var inFlight = 0; var maxInFlight = 0; var catalog = 0 }
    let state = Mutex(State())
    let gate = HarnessChatSignal(), atFour = HarnessChatSignal()
    let hold: Bool
    init(_ chat: FakeDurableModels, hold: Bool = false) { self.chat = chat; self.hold = hold }
    func getModel(provider: String, modelId: String) -> Model? { chat.getModel(provider: provider, modelId: modelId) }
    func streamSimple(model: Model, context: PiSwiftAI.Context, options: SimpleStreamOptions) -> AssistantMessageEventStream { chat.streamSimple(model: model, context: context, options: options) }
    func getModelsOfType(_ type: ModelType, provider: String?) -> [AnyModel] {
        state.withLock { $0.catalog += 1 }
        return ([AnyModel.classifier(classifier), .image(painter)] + chat.models.map(AnyModel.chat)).filter { $0.type == type && (provider == nil || $0.provider == provider) }
    }
    func getAvailableOfType(_ type: ModelType, provider: String?, context: ChordContext) async throws -> [AnyModel] {
        if hold { await atFour.wait() }
        return getModelsOfType(type, provider: provider)
    }
    func classify(model: ClassifierModel, context: ClassifierContext, operation: ChordContext) async throws -> ClassifierResult {
        #expect(model.baseUrl == "https://example.invalid")
        let count = state.withLock { s in s.classify += 1; s.inFlight += 1; s.maxInFlight = max(s.maxInFlight, s.inFlight); return s.inFlight }
        if count == 4 { atFour.signal() }
        defer { state.withLock { $0.inFlight -= 1 } }
        if hold {
            try await awaitWithContext(Task { await self.gate.wait() }, operation)
        }
        if context.state["fail"]?.value as? Bool == true {
            return .init(api: model.api, provider: model.provider, model: model.id, stopReason: .error, errorMessage: "quota exceeded", timestamp: 0)
        }
        var usage = Usage(input: 10, output: 2, cacheRead: 0, cacheWrite: 0, totalTokens: 12)
        usage.cost = .init(input: 0.001, output: 0.0002, cacheRead: 0, cacheWrite: 0, total: 0.0012)
        return .init(api: model.api, provider: model.provider, model: model.id, answers: ["good": .bool(probability: 1)], usage: usage, timestamp: 0)
    }
    func generateImages(model: ImageModel, context: ImagesContext, operation: ChordContext) async throws -> AssistantImages {
        state.withLock { $0.images += 1 }
        return .init(api: model.api, provider: model.provider, model: model.id, output: [.image(.init(data: e10PNG, mimeType: "image/png"))], stopReason: .stop, timestamp: 0)
    }
}
private let e10ClassifierContext: JSONValue = ["state": [:], "questions": ["good": ["type": "bool", "instructions": "Is it good?", "criteria": ["true": "yes", "false": "no"]]]]
private let e10ClassifierModel: JSONValue = ["provider": "test", "id": "judge", "headers": ["authorization": "evil"], "baseUrl": "https://evil.invalid"]

private func e10ModelRun(_ plan: @escaping DeterministicCodemodeSandbox.Plan, hold: Bool = false,
    beforeWait: (@Sendable (E10Models) async -> Void)? = nil) async throws -> (JSONValue, E10Models, UsageState?) {
    let setup = HarnessChatSetup(), sandbox = DeterministicCodemodeSandbox(plan: plan)
    let models = E10Models(setup.models, hold: hold)
    try setup.registry.install(createCodemodeExtension(options: .init(sandbox: sandbox)))
    setup.models.setResponses([.message(e10Call()), .message(chatAssistant("done"))])
    let opened = try await e10Open(setup: setup, models: models, env: FakeExecutionEnv())
    let submission = try await opened.root.submit(.input(content: .text("go")), context: .background)
    if let beforeWait { await beforeWait(models) }
    #expect(try await submission.wait(context: .background).status == "done")
    try await opened.harness.waitForIdle(context: .background)
    let message = try await e10Message(opened.root)
    let usage = try await opened.harness.snapshot(UsageDoc, conversationId: opened.root.id, context: .background)
    #expect(setup.reports.values.isEmpty)
    try await opened.harness.close(context: .background)
    return (message, models, usage)
}

@Suite(.timeLimit(.minutes(1)))
struct CodemodeModelTests {
    @Test func catalogStripsCredentialHeaders() async throws {
        let (message, models, _) = try await e10ModelRun { state in
            if state.seq == 0 { return .init(calls: [
                .init(target: .global, name: "models.getModelsOfType", args: ["classifier", "test"]),
                .init(target: .global, name: "models.getModelOfType", args: ["classifier", "test", "judge"]),
                .init(target: .global, name: "models.getAvailableOfType", args: ["image"])]) }
            if state.deliveries.count < 3 { return .init() }
            let values = Dictionary(uniqueKeysWithValues: state.deliveries.map { ($0.id, e10Value($0.outcome) ?? .null) })
            return .init(result: .init(value: [values[1]?[0]?["id"] ?? .null, values[2]?["id"] ?? .null,
                .bool(values[2]?["headers"] != nil), values[3]?[0]?["id"] ?? .null]))
        }
        #expect(e10Text(message).contains("[\"judge\",\"judge\",false,\"painter\"]"))
        #expect(models.state.withLock { $0.catalog } == 3)
    }
    @Test func internalNestedClassifierUsageAndHiddenListings() async throws {
        let (message, models, usage) = try await e10ModelRun { state in
            if state.seq == 0 {
                #expect(!state.options.tools.contains { $0.name.contains("models") })
                return .init(calls: [.init(target: .global, name: "models.classify", args: [e10ClassifierModel, e10ClassifierContext]),
                    .init(target: .global, name: "searchTools", args: ["classify generate images models"]),
                    .init(target: .global, name: "describeTool", args: ["pi.codemode.models.classify"])])
            }
            guard state.deliveries.count == 3 else { return .init() }
            let values = Dictionary(uniqueKeysWithValues: state.deliveries.map { ($0.id, e10Value($0.outcome) ?? .null) })
            return .init(result: .init(value: [values[1]?["stopReason"] ?? .null, values[1]?["answers"]?["good"]?["probability"] ?? .null,
                .number(Double(values[2]?.arrayValue?.count ?? -1)), .bool(values[3] != .null)]))
        }
        #expect(e10Text(message).contains("[\"stop\",1,0,false]"))
        #expect(models.state.withLock { $0.classify } == 1)
        #expect(message["details"]?["calls"]?[0]?["name"] == "models.classify")
        #expect(message["details"]?["calls"]?[0]?["status"] == "ok")
        #expect(abs((usage?.tools["pi.codemode.models.classify"]?.cost.total ?? 0) - 0.0012) < 0.000001)
    }
    @Test func failedModelResolvesItsProgramResult() async throws {
        var context = e10ClassifierContext.objectValue!; context["state"] = ["fail": true]
        let input = JSONValue.object(context)
        let (message, _, _) = try await e10ModelRun { state in
            if state.seq == 0 { return .init(calls: [.init(target: .global, name: "models.classify", args: [e10ClassifierModel, input])]) }
            let value = e10Value(state.deliveries[0].outcome)
            return .init(result: .init(value: [value?["stopReason"] ?? .null, value?["errorMessage"] ?? .null]))
        }
        #expect(e10Text(message).contains("[\"error\",\"quota exceeded\"]"))
        #expect(message["details"]?["calls"]?[0]?["status"] == "error")
    }
    @Test func badClassifierContextStopsBeforeRequest() async throws {
        let (message, models, _) = try await e10ModelRun { state in
            if state.seq == 0 { return .init(calls: [.init(target: .global, name: "models.classify", args: [e10ClassifierModel, ["prompt": "x"]])]) }
            if case .failure(let message, _) = state.deliveries[0].outcome { return .init(result: .init(value: .string(message))) }
            Issue.record("Bad classifier context resolved"); return .init(result: .init())
        }
        #expect(e10Text(message).contains("context.state must be an object"))
        #expect(e10Text(message).contains("Expected context:"))
        #expect(models.state.withLock { $0.classify } == 0)
    }
    @Test func atMostFourModelsInFlight() async throws {
        let (message, models, _) = try await e10ModelRun({ state in
            if state.seq == 0 { return .init(calls: (0..<8).map { _ in .init(target: .global, name: "models.classify", args: [e10ClassifierModel, e10ClassifierContext]) }) }
            return state.deliveries.count == 8 ? .init(result: .init(value: 8)) : .init()
        }, hold: true, beforeWait: { models in
            await models.atFour.wait()
            #expect(models.state.withLock { $0.inFlight } == 4)
            models.gate.signal()
        })
        #expect(e10Text(message).hasSuffix("8"))
        #expect(models.state.withLock { $0.classify } == 8)
        #expect(models.state.withLock { $0.maxInFlight } == 4)
    }
    @Test func queuedModelsDoNotStartAfterOutcome() async throws {
        let ended = HarnessChatSignal()
        let (_, models, _) = try await e10ModelRun({ state in
            if state.seq == 0 { return .init(calls: (0..<6).map { _ in .init(target: .global, name: "models.classify", args: [e10ClassifierModel, e10ClassifierContext]) } + [.init(target: .global, name: "models.getAvailableOfType", args: ["image"])]) }
            if state.deliveries.contains(where: { $0.id == 7 }) { ended.signal(); return .init(result: .init(value: .string(String(repeating: "x", count: 60000)))) }
            return .init()
        }, hold: true, beforeWait: { models in
            await ended.wait()
            models.gate.signal()
        })
        #expect(models.state.withLock { $0.classify } == 4)
    }
    @Test func generatedImagesNoteAndShownImages() async throws {
        for show in [false, true] {
            let (message, models, _) = try await e10ModelRun { state in
                if state.seq == 0 { return .init(calls: [.init(target: .global, name: "models.generateImages", args: [["provider": "test", "id": "painter"], ["input": [["type": "text", "text": "a cat"]]]])]) }
                let images = e10Value(state.deliveries[0].outcome)?["output"]?.arrayValue ?? []
                let value: JSONValue? = show ? nil : .number(Double(images.count))
                return .init(result: .init(value: value, output: show ? [.image(data: e10PNG, mimeType: "image/png")] : []))
            }
            #expect(models.state.withLock { $0.images } == 1)
            #expect(e10Text(message).contains("Note: models.generateImages() returned 1 image") == !show)
            #expect(message["content"]?.arrayValue?.contains { $0["type"] == "image" } == show)
        }
    }
}
