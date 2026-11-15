import Foundation
import Testing
@testable import PiCodexImageGen
import PiSwiftAI
import PiSwiftAgent
import PiSwiftChord
import PiSwiftCodingAgent
import PiSwiftDurable
import PiSwiftDurableTesting

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

        func run(_ arguments: JSONObject, model: Model) async throws -> ToolExecutionResult {
            let tool = try #require(imageExtension.tools.first)
            let ref = ModelRef(provider: model.provider, modelId: model.id)
            let cwd = cwd
            let api = ToolExecutionApi(taskId: try TaskID(2), conversationId: rootConversationID, callId: "call_1",
                                       registry: .init(), models: FakeDurableModels(),
                                       agent: { _ in Agent(model: ref, cwd: cwd) })
            return try await tool.execute(.object(arguments), api, .background)
        }
    }

    @Test func extensionHasOnlyTheInlineTool() throws {
        let fixture = try Fixture(replies: [])
        #expect(fixture.imageExtension.tools.map(\.name) == CodexImageGen.durableToolNames)
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
        let image = try #require(result.output?.compactMap { block -> ImageContent? in
            if case .image(let image) = block { return image }
            return nil
        }.first)
        #expect(image.data == pngBytes.base64EncodedString())
        let savedPath = try #require(result.details?.objectValue?["savedPath"]?.stringValue)
        #expect(savedPath.hasPrefix("\(fixture.agentDir)/generated-images/"))
        #expect(FileManager.default.contents(atPath: savedPath) == pngBytes)
        let body = try #require(fixture.client.requests.withLock { $0.first }?.httpBody
            .flatMap { try JSONSerialization.jsonObject(with: $0) as? [String: Any] })
        #expect(body["model"] as? String == chatGPTModel.id)
    }

    @Test func entryBlocksReadUserAndToolResultImages() throws {
        let user = Message.user(UserMessage(content: .blocks([.image(ImageContent(data: "AAAA", mimeType: "image/png"))])))
        let entry = try EntryRecord(id: EntryID(1), conversationId: rootConversationID, kind: "message",
                                    model: [durableJSON(fromFoundation: messageToJSONObject(user))])
        let blocks = durableEntryBlocks(entry)
        #expect(blocks.count == 1)
        #expect(blocks.first?.count == 1)
    }
}
