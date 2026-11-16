import Foundation
import Testing
@testable import PiCodexImageGen
import PiSwiftAI
import PiSwiftAgent
import PiSwiftCodingAgent

/// Regression tests for the review findings.
@Suite("PiCodexImageGen review fixes", .timeLimit(.minutes(1)))
struct CodexImageGenReviewTests {
    @Test func usageCountersKeepZeroOneAndLargeValues() async throws {
        #expect(usageCounter(NSNumber(value: 0)) as? Int == 0)
        #expect(usageCounter(NSNumber(value: 1)) as? Int == 1)
        #expect(usageCounter(NSNumber(value: true)) == nil)
        #expect(usageCounter(NSNumber(value: -1)) == nil)
        #expect(usageCounter(NSNumber(value: Double.nan)) == nil)
        // Larger than Int.max: must not trap.
        #expect(usageCounter(NSNumber(value: 1e19)) as? Double == 1e19)
        #expect(usageCounter(NSNumber(value: 2.5)) as? Double == 2.5)

        // JSON 0 and 1 survive the full parse.
        let body = sse([
            ["type": "response.output_item.done", "item": imageItem()],
            ["type": "response.completed", "response": ["id": "resp_1", "usage": [
                "input_tokens": 0, "output_tokens": 1, "total_tokens": 1e19,
                "input_tokens_details": ["image_tokens": 1, "cached_tokens": 0],
            ]]],
        ])
        let parsed = try await parseCodexSse(ProviderHTTPResponse(statusCode: 200, body: body), secrets: [])
        let usage = try #require(parsed.usage?.value as? [String: Any])
        #expect(usage["input_tokens"] as? Int == 0)
        #expect(usage["output_tokens"] as? Int == 1)
        #expect(usage["total_tokens"] as? Double == 1e19)
        let details = try #require(usage["input_tokens_details"] as? [String: Any])
        #expect(details["image_tokens"] as? Int == 1)
        #expect(details["cached_tokens"] as? Int == 0)
    }

    @Test func responsesURLMatchesTheChatProvider() {
        #expect(codexResponsesURL(baseUrl: "https://proxy.example/codex/responses")?.absoluteString
                == "https://proxy.example/codex/responses")
        #expect(codexResponsesURL(baseUrl: "https://proxy.example/v1/responses")?.absoluteString
                == "https://proxy.example/v1/responses")
        #expect(codexResponsesURL(baseUrl: "https://chatgpt.com/backend-api/")?.absoluteString
                == "https://chatgpt.com/backend-api/codex/responses")
    }

    @Test func toolCallIdIsBoundedByUTF8Bytes() {
        let id = String(repeating: "é", count: 200) // 400 UTF-8 bytes
        let bounded = boundedToolCallId(id)
        #expect(bounded.utf8.count <= 256)
        #expect(bounded.utf8.count == 256)
        #expect(boundedToolCallId("call_1") == "call_1")
        let record = ArtifactRecord(artifact: ImageArtifact(path: "/tmp/a.png", mimeType: "image/png", byteCount: 1),
                                    toolCallId: bounded)
        #expect(artifactRecord(record.dictionary) != nil)
    }

    @Test func failedRegistrationRollsBackAndRetries() async throws {
        let harness = Harness(replies: [])
        let failing = LockedState(true)
        harness.api.setRegisterOwnedToolHandler { tool, path in
            if failing.withLock({ $0 }) && tool.name == CodexImageGen.listToolName {
                return .failure(.toolNameCollision(name: tool.name, ownerPath: "<other>", path: path))
            }
            return .success(())
        }
        try await harness.emitSessionStart(chatGPTModel)
        #expect(harness.api.tools.isEmpty)

        failing.withLock { $0 = false }
        try await harness.emitModelSelect(chatGPTModel)
        #expect(Set(harness.api.tools.keys) == Set(CodexImageGen.toolNames))
    }

    @Test func concurrentModelEventsLeaveAConsistentState() async throws {
        let harness = Harness(replies: [])
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<40 {
                group.addTask {
                    try await harness.emitModelSelect(index.isMultiple(of: 2) ? chatGPTModel : anthropicModel)
                }
            }
            try await group.waitForAll()
        }
        try await harness.emitModelSelect(anthropicModel)
        #expect(harness.api.tools.isEmpty)
        try await harness.emitModelSelect(chatGPTModel)
        #expect(Set(harness.api.tools.keys) == Set(CodexImageGen.toolNames))
    }

    @Test func abortStopsAStalledErrorBody() async throws {
        let terminated = LockedState(false)
        let sent = LockedState(false)
        let client = StalledErrorClient(sent: sent, terminated: terminated)
        let harness = Harness(replies: [])
        let api = HookAPI(events: createEventBus(), hookPath: "<test:error-body>")
        let agentDir = harness.agentDir
        registerCodexImageGen(api, environment: CodexImageGenEnvironment(
            httpClient: client, admission: ImageAdmission(), agentDir: { agentDir }))
        for handler in api.handlers["session_start"] ?? [] {
            _ = try await handler(SessionStartEvent(), harness.hookContext(chatGPTModel))
        }
        let tool = try require_tool(api, CodexImageGen.inlineToolName)
        let signal = CancellationToken()
        let run = Task {
            try await tool.execute("call_1", ["prompt": AnyCodable("x"), "save": AnyCodable("none")], nil,
                                   harness.toolContext(chatGPTModel), signal)
        }
        #expect(await waitUntil { sent.withLock { $0 } })
        signal.cancel()
        do {
            _ = try await run.value
            Issue.record("expected failure")
        } catch {
            #expect(error.localizedDescription
                    == "Image generation was aborted after dispatch. Image quota may have been consumed. No automatic retry was made.")
        }
        #expect(await waitUntil { terminated.withLock { $0 } })
    }

    @Test func agentDirIsUsedForGlobalSaves() throws {
        let dir = makeTempDir()
        let config = try resolveSaveConfig(save: nil, saveDir: nil, cwd: "/work", sessionId: "s1", agentDir: dir)
        #expect(config.outputDir == dir + "/generated-images/s1")
        let result = ExtensionLoader.load(CodexImageGen.inlineExtension(agentDir: dir), cwd: dir, eventBus: createEventBus())
        #expect(result.error == nil)
    }

    @Test func referencePathsUseTheReadToolRules() async throws {
        let dir = makeTempDir()
        // macOS screenshot names use a narrow no-break space before AM/PM.
        let actual = dir + "/Screenshot 2026-01-01 at 3.14.15\u{202F}PM.png"
        FileManager.default.createFile(atPath: actual, contents: pngBytes)
        let images = try await resolveInputImages(paths: ["Screenshot 2026-01-01 at 3.14.15 PM.png"], count: nil,
                                            cwd: dir, recent: [])
        #expect(images.count == 1)
    }
}

/// Returns HTTP 500 with a body that never ends until cancelled.
private final class StalledErrorClient: ProviderHTTPClient, Sendable {
    let sent: LockedState<Bool>
    let terminated: LockedState<Bool>

    init(sent: LockedState<Bool>, terminated: LockedState<Bool>) {
        self.sent = sent
        self.terminated = terminated
    }

    func send(_ request: URLRequest) async throws -> ProviderHTTPResponse {
        let terminated = terminated
        let body = AsyncThrowingStream<Data, Error> { continuation in
            continuation.yield(Data("{\"error\":".utf8))
            continuation.onTermination = { _ in terminated.withLock { $0 = true } }
        }
        sent.withLock { $0 = true }
        return ProviderHTTPResponse(statusCode: 500, body: body)
    }
}
