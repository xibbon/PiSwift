import Foundation
import Testing
@testable import PiCodexImageGen
import PiSwiftAI
import PiSwiftAgent
import PiSwiftCodingAgent

@Suite("PiCodexImageGen tools")
struct CodexImageGenToolTests {
    // MARK: Gating

    @Test func inlineExtensionRegistersOnlyLifecycleAndCommand() throws {
        let result = ExtensionLoader.load(CodexImageGen.inlineExtension, cwd: makeTempDir(), eventBus: createEventBus())
        #expect(result.error == nil)
        let hook = try #require(result.hook)
        #expect(hook.tools.isEmpty)
        #expect(hook.commands.keys.contains("image-artifacts"))
        #expect(hook.handlers.keys.contains("session_start"))
        #expect(hook.handlers.keys.contains("model_select"))
    }

    @Test func toolsExistOnlyInAChatGPTSession() async throws {
        let harness = Harness(replies: [])
        try await harness.emitSessionStart(anthropicModel)
        #expect(harness.api.tools.isEmpty)

        try await harness.emitModelSelect(chatGPTModel, previous: anthropicModel)
        #expect(Set(harness.api.tools.keys) == Set(CodexImageGen.toolNames))
        #expect(harness.api.tools[CodexImageGen.inlineToolName]?.exposure == .modelOnly)
        #expect(harness.api.tools[CodexImageGen.artifactToolName]?.exposure == .codemode)

        try await harness.emitModelSelect(anthropicModel, previous: chatGPTModel)
        #expect(harness.api.tools.isEmpty)

        try await harness.emitSessionStart(chatGPTModel)
        #expect(harness.api.tools.count == 3)
    }

    @Test func executeRefusesANonChatGPTModelBeforeTheNetwork() async throws {
        let harness = Harness(replies: [FakeHTTPClient.Reply(status: 200, body: completedStream())])
        try await harness.emitSessionStart(chatGPTModel)
        await #expect(throws: CodexImageError.self) {
            _ = try await harness.run(CodexImageGen.inlineToolName, ["prompt": "fox"], model: anthropicModel)
        }
        #expect(harness.client.requestCount == 0)
    }

    @Test func invalidArgumentsRejectBeforeTheNetwork() async throws {
        let harness = Harness(replies: [])
        try await harness.emitSessionStart(chatGPTModel)
        for params: [String: Any] in [
            ["prompt": "  "],
            ["prompt": "fox", "outputFormat": "gif"],
            ["prompt": "fox", "background": "transparent", "outputFormat": "jpeg"],
            ["prompt": "fox", "save": "custom"],
            ["prompt": "fox", "numLastImagesToInclude": 1],
        ] {
            await #expect(throws: (any Error).self) { _ = try await harness.run(CodexImageGen.inlineToolName, params) }
        }
        #expect(harness.client.requestCount == 0)
    }

    // MARK: Inline generation

    @Test func inlineGenerationReturnsTheImageAndSavesACopy() async throws {
        let harness = Harness(replies: [FakeHTTPClient.Reply(status: 200, headers: ["x-request-id": "req_9"],
                                                             body: completedStream(extra: ["size": "16x16"]))])
        try await harness.emitSessionStart(chatGPTModel)
        let updates = LockedState<[String]>([])
        let result = try await harness.run(CodexImageGen.inlineToolName, ["prompt": "a sword icon"], updates: updates)

        let image = try #require(result.content.compactMap { block -> ImageContent? in
            if case .image(let image) = block { return image }
            return nil
        }.first)
        #expect(image.mimeType == "image/png")
        #expect(image.data == pngBytes.base64EncodedString())
        let info = details(result)
        #expect(info["model"] as? String == chatGPTModel.id)
        #expect(info["transport"] as? String == "codex-responses")
        #expect(info["requestId"] as? String == "req_9")
        let savedPath = try #require(info["savedPath"] as? String)
        #expect(savedPath == "\(harness.agentDir)/generated-images/\(sanitizePathPart(harness.session.getSessionId(), fallback: "session"))/ig_1.png")
        #expect(FileManager.default.contents(atPath: savedPath) == pngBytes)
        #expect(text(result).contains("Backend-reported size: 16x16."))
        #expect(updates.withLock { $0 }.contains("Codex image stage: generating."))
        #expect(result.structuredContent == nil)

        // The request uses the session's own credentials and model.
        let request = try #require(harness.client.requests.withLock { $0.first })
        #expect(request.url?.absoluteString == "https://chatgpt.com/backend-api/codex/responses")
        #expect(request.value(forHTTPHeaderField: "authorization") == "Bearer \(harness.token)")
        #expect(request.value(forHTTPHeaderField: "chatgpt-account-id") == testAccountId)
        let body = try #require(request.httpBody.flatMap { try JSONSerialization.jsonObject(with: $0) as? [String: Any] })
        #expect(body["model"] as? String == chatGPTModel.id)
        #expect(body["prompt_cache_key"] as? String == harness.session.getSessionId())
    }

    @Test func formatMismatchIsPreservedWithAWarning() async throws {
        let harness = Harness(replies: [FakeHTTPClient.Reply(status: 200, body: completedStream(jpegBytes))])
        try await harness.emitSessionStart(chatGPTModel)
        let result = try await harness.run(CodexImageGen.inlineToolName, ["prompt": "x", "save": "none"])
        #expect(details(result)["outputFormat"] as? String == "jpeg")
        #expect((details(result)["imageWarning"] as? String)?.contains("Requested png, but Codex returned jpeg") == true)
        #expect(details(result)["savedPath"] == nil)
        #expect(text(result).contains("Image was not saved to disk."))
    }

    @Test func transientFailuresRetryButQuotaDoesNot() async throws {
        let retrying = Harness(replies: [
            FakeHTTPClient.Reply(status: 503, headers: ["retry-after": "0.01"], body: Data()),
            FakeHTTPClient.Reply(status: 200, body: completedStream()),
        ])
        try await retrying.emitSessionStart(chatGPTModel)
        _ = try await retrying.run(CodexImageGen.inlineToolName, ["prompt": "x", "save": "none"])
        #expect(retrying.client.requestCount == 2)

        let quota = Harness(replies: [
            FakeHTTPClient.Reply(status: 429, body: try JSONSerialization.data(withJSONObject: ["error": ["code": "usage_limit_reached"]])),
            FakeHTTPClient.Reply(status: 200, body: completedStream()),
        ])
        try await quota.emitSessionStart(chatGPTModel)
        await #expect(throws: CodexRequestError.self) {
            _ = try await quota.run(CodexImageGen.inlineToolName, ["prompt": "x", "save": "none"])
        }
        #expect(quota.client.requestCount == 1)
    }

    @Test func connectionFailureIsNotRetried() async throws {
        let harness = Harness(replies: [])
        try await harness.emitSessionStart(chatGPTModel)
        do {
            _ = try await harness.run(CodexImageGen.inlineToolName, ["prompt": "x", "save": "none"])
            Issue.record("expected failure")
        } catch {
            #expect(error.localizedDescription.contains("No automatic retry was made"))
        }
        #expect(harness.client.requestCount == 1)
    }

    @Test func abortBeforeDispatchSaysNoRequestWasMade() async throws {
        let harness = Harness(replies: [FakeHTTPClient.Reply(status: 200, body: completedStream())])
        try await harness.emitSessionStart(chatGPTModel)
        let signal = CancellationToken()
        signal.cancel()
        do {
            _ = try await harness.run(CodexImageGen.inlineToolName, ["prompt": "x"], signal: signal)
            Issue.record("expected failure")
        } catch {
            #expect(error.localizedDescription == "Image generation was aborted before dispatch. No generation request was made.")
        }
        #expect(harness.client.requestCount == 0)
    }

    @Test func missingAccountIdFailsBeforeTheNetwork() async throws {
        let harness = Harness(replies: [FakeHTTPClient.Reply(status: 200, body: completedStream())], token: makeJWT(accountId: nil))
        try await harness.emitSessionStart(chatGPTModel)
        await #expect(throws: CodexImageError.self) {
            _ = try await harness.run(CodexImageGen.inlineToolName, ["prompt": "x"])
        }
        #expect(harness.client.requestCount == 0)
    }

    // MARK: Artifacts

    @Test func artifactGenerationReturnsPathsAndRecoveryRecords() async throws {
        let harness = Harness(replies: [FakeHTTPClient.Reply(status: 200, body: completedStream())])
        try await harness.emitSessionStart(chatGPTModel)
        let result = try await harness.run(CodexImageGen.artifactToolName, ["prompt": "x", "save": "none"])

        #expect(!result.content.contains { if case .image = $0 { return true } else { return false } })
        let output = structured(result)
        let artifact = try #require(output["artifact"] as? [String: Any])
        let path = try #require(artifact["path"] as? String)
        #expect(path.hasPrefix(harness.artifactRoot))
        #expect(artifact["byteCount"] as? Int == pngBytes.count)
        #expect(output["routingModel"] as? String == chatGPTModel.id)
        #expect(FileManager.default.contents(atPath: path) == pngBytes)
        #expect(FileManager.default.fileExists(atPath: path + ".json"))
        // A reservation anchor before dispatch, then the completed record on the same branch.
        #expect(harness.entries.types == [reservationEntryType, artifactEntryType])

        let list = try await harness.run(CodexImageGen.listToolName, [:])
        let listed = structured(list)
        #expect(listed["total"] as? Int == 1)
        let item = try #require((listed["artifacts"] as? [[String: Any]])?.first)
        #expect(item["availability"] as? String == "present")
        #expect((item["artifact"] as? [String: Any])?["path"] as? String == path)

        // Recent-image edits include the artifact original.
        let edit = Harness(replies: [FakeHTTPClient.Reply(status: 200, body: completedStream())])
        _ = edit.session.appendCustomEntry(artifactEntryType, ["artifact": artifact, "toolCallId": "call_0"])
        try await edit.emitSessionStart(chatGPTModel)
        let edited = try await edit.run(CodexImageGen.inlineToolName, ["prompt": "edit", "save": "none", "numLastImagesToInclude": 1])
        #expect(details(edited)["inputImageCount"] as? Int == 1)
    }

    @Test func listPaginationNeedsTheRevision() async throws {
        let session = SessionManager.inMemory(makeTempDir())
        for index in 0..<3 {
            _ = session.appendCustomEntry(artifactEntryType, [
                "artifact": ["path": "/nonexistent/\(index).png", "mimeType": "image/png", "byteCount": 1], "toolCallId": "\(index)"])
        }
        let first = structured(try listArtifacts(params: ["limit": AnyCodable(2)], entries: session.getBranch(), signal: nil))
        #expect((first["artifacts"] as? [[String: Any]])?.count == 2)
        #expect((first["artifacts"] as? [[String: Any]])?.first?["availability"] as? String == "missing")
        let next = try #require(first["nextOffset"] as? Int)
        let revision = try #require(first["revision"] as? String)
        #expect(throws: CodexImageError.self) {
            try listArtifacts(params: ["offset": AnyCodable(next)], entries: session.getBranch(), signal: nil)
        }
        let second = structured(try listArtifacts(params: ["offset": AnyCodable(next), "revision": AnyCodable(revision)],
                                                  entries: session.getBranch(), signal: nil))
        #expect((second["artifacts"] as? [[String: Any]])?.count == 1)
        #expect(second["nextOffset"] == nil)
    }

    @Test func imageArtifactsCommandListsBranchRecords() async throws {
        let harness = Harness(replies: [])
        let sent = LockedState<[String]>([])
        harness.api.setSendMessageHandler { message, _ in
            if case .text(let text) = message.content { sent.withLock { $0.append(text) } }
        }
        _ = harness.session.appendCustomEntry(artifactEntryType, [
            "artifact": ["path": "/tmp/x.png", "mimeType": "image/png", "byteCount": 3], "toolCallId": "c"])
        let command = try #require(harness.api.commands["image-artifacts"])
        let context = HookCommandContext(
            ui: NoOpHookUIContext(), hasUI: false, cwd: "/", sessionManager: harness.session,
            modelRegistry: harness.registry, model: { nil }, systemPrompt: { nil }, isIdle: { true }, abort: {},
            hasPendingMessages: { false }, waitForIdle: {},
            newSession: { _ in HookCommandResult(cancelled: true) },
            fork: { _ in HookCommandResult(cancelled: true) },
            navigateTree: { _, _ in HookCommandResult(cancelled: true) })
        try await command.handler("", context)
        #expect(sent.withLock { $0 }.first?.hasPrefix("/tmp/x.png (image/png, 3 bytes)") == true)
    }
}
