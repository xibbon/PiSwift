import Foundation
import Testing
@testable import PiCodexImageGen
@testable import PiCodexImageGenDurable
import PiSwiftAI
import PiSwiftAgent
import PiSwiftChord
import PiSwiftCodingAgent
import PiSwiftDurable
import PiSwiftDurableTesting

/// The harness model catalog: the test models, with the fake for other calls.
private struct CatalogModels: DurableModels {
    let base = FakeDurableModels()
    var clientIdentity: ClientIdentity? { base.clientIdentity }
    func getModel(provider: String, modelId: String) -> Model? {
        [chatGPTModel, anthropicModel].first { $0.provider == provider && $0.id == modelId }
    }
    func streamSimple(model: Model, context: PiSwiftAI.Context, options: SimpleStreamOptions) -> AssistantMessageEventStream {
        base.streamSimple(model: model, context: context, options: options)
    }
    func completeSimple(model: Model, context: PiSwiftAI.Context, options: SimpleStreamOptions) async -> AssistantMessage {
        await base.completeSimple(model: model, context: context, options: options)
    }
    func fetchDeferred(model: Model, handle: DeferredHandle, options: DeferredFetchOptions) async -> AssistantMessage {
        await base.fetchDeferred(model: model, handle: handle, options: options)
    }
    func cancelDeferred(model: Model, handle: DeferredHandle, options: DeferredCancelOptions) async throws {
        try await base.cancelDeferred(model: model, handle: handle, options: options)
    }
}

private func images(_ result: ToolExecutionResult) -> [ImageContent] {
    (result.output ?? []).compactMap { block -> ImageContent? in
        if case .image(let image) = block { return image }
        return nil
    }
}

private func requestBody(_ client: FakeHTTPClient, _ index: Int = 0) throws -> [String: Any] {
    try #require(client.requests.withLock { $0.count > index ? $0[index] : nil }?.httpBody
        .flatMap { try JSONSerialization.jsonObject(with: $0) as? [String: Any] })
}

@Suite("PiCodexImageGen durable", .timeLimit(.minutes(1)))
struct CodexImageGenDurableTests {
    struct Fixture {
        let client: FakeHTTPClient
        let agentDir = makeTempDir()
        let cwd = makeTempDir()
        let imageExtension: PiSwiftDurable.Extension

        init(replies: [FakeHTTPClient.Reply]) throws {
            client = FakeHTTPClient(replies)
            let agentDir = agentDir
            imageExtension = try makeDurableExtension(
                agentDir: agentDir, modelRegistry: makeRegistry(), defaultCwd: cwd,
                environment: CodexImageGenEnvironment(httpClient: client, admission: ImageAdmission(),
                                                      agentDir: { "/unused" }, artifactRoot: { makeTempDir() },
                                                      random: { 0 }))
        }

        func run(_ arguments: JSONObject, model: Model, env: (any ExecutionEnv)? = nil) async throws -> ToolExecutionResult {
            let tool = try #require(imageExtension.tools.first)
            let ref = ModelRef(provider: model.provider, modelId: model.id)
            let cwd = cwd
            let api = ToolExecutionApi(taskId: try TaskID(2), conversationId: rootConversationID, callId: "call_1",
                                       registry: .init(), models: CatalogModels(), env: env,
                                       agent: { _ in Agent(model: ref, cwd: cwd) })
            return try await tool.execute(.object(arguments), api, .background)
        }
    }

    @Test func extensionHasOnlyTheInlineTool() throws {
        let fixture = try Fixture(replies: [])
        #expect(fixture.imageExtension.tools.map(\.name) == CodexImageGen.durableToolNames)
    }

    @Test func onlyTheModelCanCallTheTool() throws {
        // Codemode scripts must not spend image quota or receive image bytes.
        let fixture = try Fixture(replies: [])
        #expect(fixture.imageExtension.tools.first?.callers == [.model])
    }

    @Test func extensionChangeFollowsTheProvider() throws {
        let fixture = try Fixture(replies: [])
        let chatGPT = ModelRef(provider: chatGPTModel.provider, modelId: chatGPTModel.id)
        let other = ModelRef(provider: anthropicModel.provider, modelId: anthropicModel.id)
        guard case .clear = CodexImageGen.durableExtensionChange(for: chatGPT, in: fixture.imageExtension) else {
            Issue.record("Expected the default selection for a ChatGPT model")
            return
        }
        guard case .set(.edit(nil, let remove)) = CodexImageGen.durableExtensionChange(for: other, in: fixture.imageExtension) else {
            Issue.record("Expected a remove edit for another provider")
            return
        }
        #expect(remove?.map(\.name) == ["codex-image-gen"])
    }

    @Test func extensionChangeKeepsTheOtherEditsOfTheHost() throws {
        let fixture = try Fixture(replies: [])
        let chatGPT = ModelRef(provider: chatGPTModel.provider, modelId: chatGPTModel.id)
        let other = ModelRef(provider: anthropicModel.provider, modelId: anthropicModel.id)
        let extra = PiSwiftDurable.Extension(name: "extra")
        let removed = PiSwiftDurable.Extension(name: "removed")
        let base = ExtensionChange.edit(add: [extra], remove: [removed])

        guard case .set(.edit(let add, let remove)) = CodexImageGen.durableExtensionChange(
            for: other, in: fixture.imageExtension, base: base) else {
            Issue.record("Expected an edit for another provider")
            return
        }
        #expect(add?.map(\.name) == ["extra"])
        #expect(remove?.map(\.name) == ["removed", "codex-image-gen"])

        guard case .set(.edit(let add, let remove)) = CodexImageGen.durableExtensionChange(
            for: chatGPT, in: fixture.imageExtension, base: base) else {
            Issue.record("Expected an edit for a ChatGPT model")
            return
        }
        #expect(add?.map(\.name) == ["extra"])
        #expect(remove?.map(\.name) == ["removed"])

        guard case .set(.exact(let list)) = CodexImageGen.durableExtensionChange(
            for: chatGPT, in: fixture.imageExtension, base: .exact([extra])) else {
            Issue.record("Expected an exact selection")
            return
        }
        #expect(list.map(\.name) == ["extra", "codex-image-gen"])
        guard case .set(.exact(let list)) = CodexImageGen.durableExtensionChange(
            for: other, in: fixture.imageExtension, base: .exact([extra, fixture.imageExtension])) else {
            Issue.record("Expected an exact selection")
            return
        }
        #expect(list.map(\.name) == ["extra"])
    }

    @Test func refusesANonChatGPTModelBeforeTheNetwork() async throws {
        let fixture = try Fixture(replies: [FakeHTTPClient.Reply(status: 200, body: completedStream())])
        await #expect(throws: CodexImageError.self) {
            _ = try await fixture.run(["prompt": .string("fox")], model: anthropicModel)
        }
        #expect(fixture.client.requestCount == 0)
    }

    @Test func generatesAnInlineImageAndSavesUnderTheAgentDir() async throws {
        let fixture = try Fixture(replies: [FakeHTTPClient.Reply(status: 200, body: completedStream())])
        let result = try await fixture.run(["prompt": .string("a sword icon")], model: chatGPTModel)
        let image = try #require(images(result).first)
        #expect(image.data == pngBytes.base64EncodedString())
        let savedPath = try #require(result.details?.objectValue?["savedPath"]?.stringValue)
        #expect(savedPath.hasPrefix("\(fixture.agentDir)/generated-images/"))
        #expect(FileManager.default.contents(atPath: savedPath) == pngBytes)
        let body = try requestBody(fixture.client)
        #expect(body["model"] as? String == chatGPTModel.id)
    }

    @Test func theCacheKeyIsNotTheSequentialConversationID() async throws {
        let first = try Fixture(replies: [FakeHTTPClient.Reply(status: 200, body: completedStream())])
        let second = try Fixture(replies: [FakeHTTPClient.Reply(status: 200, body: completedStream())])
        _ = try await first.run(["prompt": .string("a"), "save": .string("none")], model: chatGPTModel)
        _ = try await second.run(["prompt": .string("b"), "save": .string("none")], model: chatGPTModel)
        let firstKey = try #require(try requestBody(first.client)["prompt_cache_key"] as? String)
        let secondKey = try #require(try requestBody(second.client)["prompt_cache_key"] as? String)
        #expect(firstKey != String(rootConversationID.rawValue))
        #expect(firstKey != secondKey)
    }

    @Test func pathsAndProjectSavesUseTheExecutionEnvironment() async throws {
        let fixture = try Fixture(replies: [FakeHTTPClient.Reply(status: 200, body: completedStream())])
        let env = FakeExecutionEnv(cwd: "/work")
        try await env.createDir("/work/img", options: CreateDirOptions(recursive: true), context: .background).get()
        try await env.writeFile("/work/img/a.png", content: .bytes([UInt8](pngBytes)), context: .background).get()

        let result = try await fixture.run([
            "prompt": .string("edit"), "referencedImagePaths": .array([.string("img/a.png")]), "save": .string("project"),
        ], model: chatGPTModel, env: env)

        let body = try requestBody(fixture.client)
        let content = ((body["input"] as? [[String: Any]])?.first?["content"]) as? [[String: Any]]
        #expect(content?.last?["image_url"] as? String == "data:image/png;base64,\(pngBytes.base64EncodedString())")
        let savedPath = try #require(result.details?.objectValue?["savedPath"]?.stringValue)
        #expect(savedPath.hasPrefix("/work/.pi/generated-images/"))
        #expect(try await env.readBinaryFile(savedPath, context: .background).get() == [UInt8](pngBytes))
        #expect(!FileManager.default.fileExists(atPath: "\(fixture.cwd)/.pi"))
    }

    @Test func rejectsBothImageSelectorsBeforeTheHistoryRead() async throws {
        let fixture = try Fixture(replies: [])
        await #expect(throws: CodexImageError.self) {
            _ = try await fixture.run([
                "prompt": .string("edit"), "referencedImagePaths": .array([.string("a.png")]),
                "numLastImagesToInclude": .number(3),
            ], model: chatGPTModel)
        }
        #expect(throws: CodexImageError.self) {
            _ = try ImageToolParams(["prompt": AnyCodable("p"), "numLastImagesToInclude": AnyCodable(9)])
        }
        #expect(fixture.client.requestCount == 0)
    }

    @Test func imageSourcesIncludeEveryMessageRoleInContextOrder() throws {
        let image = { (data: String) in ContentBlock.image(ImageContent(data: data, mimeType: "image/png")) }
        let messages: [Message] = [
            .user(UserMessage(content: .blocks([image("USER")]))),
            .assistant(AssistantMessage(content: [image("ASSISTANT")], api: chatGPTModel.api, provider: chatGPTModel.provider,
                                        model: chatGPTModel.id,
                                        usage: Usage(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0),
                                        stopReason: .stop)),
            .toolResult(ToolResultMessage(toolCallId: "t", toolName: "read", content: [image("TOOL")], isError: false)),
        ]
        let recent = selectRecentImages(durableImageSources(messages), count: 3)
        #expect(recent == [
            .inline(InputImage(data: "USER", mimeType: "image/png")),
            .inline(InputImage(data: "ASSISTANT", mimeType: "image/png")),
            .inline(InputImage(data: "TOOL", mimeType: "image/png")),
        ])
        #expect(selectRecentImages(durableImageSources(messages), count: 1) == [
            .inline(InputImage(data: "TOOL", mimeType: "image/png")),
        ])
    }
}
