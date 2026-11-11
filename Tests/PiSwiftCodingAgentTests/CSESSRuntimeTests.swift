import Foundation
import Testing
import PiSwiftAI
import PiSwiftAgent
@testable import PiSwiftCodingAgent
#if canImport(AppKit)
import AppKit
#endif

private actor CSESSGate {
    private var opened = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async {
        if opened { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func open() { opened = true; continuation?.resume(); continuation = nil }
}

@Suite("v1.5.2 C-SESS runtime")
struct CSESSRuntimeTests {
    private func installReplyStream(_ session: AgentSession) {
        session.agent.streamFn = { model, _, _ in
            let stream = AssistantMessageEventStream()
            stream.push(.done(reason: .stop, message: AssistantMessage(
                content: [.text(TextContent(text: "ok"))], api: model.api,
                provider: model.provider, model: model.id,
                usage: Usage(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0),
                stopReason: .stop)))
            return stream
        }
    }

    private func installHangingStream(_ session: AgentSession) {
        session.agent.streamFn = { model, _, options in
            let stream = AssistantMessageEventStream()
            Task {
                while options.signal?.isCancelled != true {
                    try? await Task.sleep(nanoseconds: 5_000_000)
                }
                stream.push(.error(reason: .aborted, error: AssistantMessage(
                    content: [], api: model.api, provider: model.provider, model: model.id,
                    usage: Usage(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0),
                    stopReason: .aborted)))
            }
            return stream
        }
    }

    private func waitUntil(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<200 {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return condition()
    }
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("csess-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func session(_ cwd: String, manager: SessionManager? = nil,
                         model: Model? = nil, scope: [ScopedModel]? = nil,
                         tools: [String]? = nil) async throws -> AgentSession {
        let selected = model ?? getModel(provider: .openai, modelId: "gpt-4o-mini")
        return try await createAgentSession(CreateAgentSessionOptions(
            cwd: cwd, agentDir: cwd,
            authStorage: .inMemory([selected.provider: .apiKey(ApiKeyCredential(key: "test"))]),
            model: selected, scopedModels: scope, offline: true, toolNames: tools,
            resourceLoader: TestResourceLoader(), sessionManager: manager ?? .inMemory(cwd),
            settingsManager: .inMemory())).session
    }

    private func hookedSession(_ manager: SessionManager, _ api: HookAPI) -> AgentSession {
        let model = getModel(provider: .openai, modelId: "gpt-4o-mini")
        let auth = AuthStorage(":memory:")
        auth.setRuntimeApiKey(model.provider, "test")
        let registry = ModelRegistry(auth)
        let hook = LoadedHook(path: "csess", resolvedPath: "csess", handlers: api.handlers,
                              currentHandlers: { api.handlers }, commands: api.commands,
                              currentCommands: { api.commands }, isExtension: true)
        let runner = HookRunner([hook], manager.getCwd(), manager, registry)
        let agent = Agent(AgentOptions(initialState: AgentState(systemPrompt: "Test", model: model, tools: []),
                                       getApiKey: { _ in "test" }))
        let agentSession = AgentSession(config: AgentSessionConfig(agent: agent, sessionManager: manager,
            settingsManager: .inMemory(), resourceLoader: TestResourceLoader(),
            hookRunner: runner, modelRegistry: registry))
        installReplyStream(agentSession)
        return agentSession
    }

    // d0fe21308, branch-summarization.test.ts:135
    @Test("applies context edits to branch entries")
    func appliesContextEditsToBranchEntries() throws {
        let manager = SessionManager.inMemory()
        let model = getModel(provider: .openai, modelId: "gpt-4o-mini")
        let usage = Usage(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0)
        manager.appendMessage(.user(UserMessage(content: .text("Investigate login"))))
        let failed = manager.appendMessage(.assistant(AssistantMessage(
            content: [.text(TextContent(text: "FAILED_ATTEMPT"))], api: model.api,
            provider: model.provider, model: model.id, usage: usage,
            stopReason: .error, errorMessage: "lost")))
        _ = try manager.appendContextEdit(failed, nil)
        let success = manager.appendMessage(.assistant(AssistantMessage(
            content: [.text(TextContent(text: "ORIGINAL_TEXT"))], api: model.api,
            provider: model.provider, model: model.id, usage: usage, stopReason: .stop)))
        _ = try manager.appendContextEdit(success, .text("REPLACED_TEXT"))
        let text = prepareBranchEntries(manager.getEntries()).messages.compactMap { message -> String? in
            switch message {
            case .user(let user):
                if case .text(let content) = user.content { return content }
                return nil
            case .assistant(let assistant):
                return assistant.content.compactMap { block -> String? in
                    if case .text(let content) = block { return content.text }
                    return nil
                }.joined()
            default: return nil
            }
        }.joined(separator: "\n")
        #expect(text.contains("Investigate login"))
        #expect(!text.contains("FAILED_ATTEMPT"))
        #expect(!text.contains("ORIGINAL_TEXT"))
        #expect(text.contains("REPLACED_TEXT"))
    }

    // 269afc66a, branch-summarization.test.ts:47
    @Test("passes the thinking level only for reasoning-capable models")
    func passesThinkingLevelOnlyForReasoningModels() async throws {
        let manager = SessionManager.inMemory()
        manager.appendMessage(.user(UserMessage(content: .text("Summarize this"))))
        let seen = LockedState<[PiSwiftAI.ThinkingLevel?]>([])
        let stream: StreamFn = { model, _, options in
            seen.withLock { $0.append(options.reasoning) }
            let events = AssistantMessageEventStream()
            events.push(.done(reason: .stop, message: AssistantMessage(
                content: [.text(TextContent(text: "summary"))], api: model.api,
                provider: model.provider, model: model.id,
                usage: Usage(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0),
                stopReason: .stop)))
            return events
        }
        let reasoning = getModel(provider: .anthropic, modelId: "claude-sonnet-4-5")
        let nonreasoning = getModel(provider: .openai, modelId: "gpt-4o-mini")
        for (model, level): (Model, PiSwiftAI.ThinkingLevel?) in [
            (reasoning, .xhigh), (reasoning, nil), (nonreasoning, .high)
        ] {
            _ = await generateBranchSummary(manager.getEntries(), GenerateBranchSummaryOptions(
                model: model, apiKey: "test", thinkingLevel: level, signal: nil,
                customInstructions: nil, reserveTokens: nil, streamFn: stream))
        }
        #expect(seen.withLock { $0 } == [.xhigh, nil, nil])
    }

    // b9e3eef6c, system-prompt-updates.test.ts:56
    @Test("does not patch the prompt when the active tools are only reordered")
    func activeToolReorderKeepsDeclarationOrder() async throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let agentSession = try await session(dir.path, tools: ["read", "write"])
        defer { agentSession.dispose() }
        let before = agentSession.getActiveToolNames()
        #expect(before.count == 2)
        agentSession.setActiveToolsByName(before.reversed())
        #expect(agentSession.getActiveToolNames() == before)
    }

    // a63c4ec5c, suite/agent-session-queue.test.ts
    @Test("removes an image-only steering message after delivery")
    func removesImageOnlySteeringMessageAfterDelivery() async throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = getModel(provider: .openai, modelId: "gpt-4o-mini")
        let agentSession = try await session(dir.path, model: model)
        defer { agentSession.dispose() }
        let agent = agentSession.agent
        installReplyStream(agentSession)
        agent.appendMessage(.user(UserMessage(content: .text("first"))))
        agent.appendMessage(.assistant(AssistantMessage(content: [.text(TextContent(text: "ready"))],
            api: model.api, provider: model.provider, model: model.id,
            usage: Usage(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0), stopReason: .stop)))
        let png = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVQIHWP4z8DwHwAFgAI/ScL/nwAAAABJRU5ErkJggg=="
        agentSession.steer("", images: [ImageContent(data: png, mimeType: "image/png")])
        #expect(agentSession.pendingMessageCount == 1)
        try await agent.continue()
        #expect(agentSession.pendingMessageCount == 0)
    }

    // 4cf69332c, agent-session-queued-images.test.ts
    @Test("resizes images in steering, follow-up, and streaming prompt messages")
    func resizesImagesInQueuedMessages() async throws {
        #if canImport(AppKit)
        let bitmap = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 100, pixelsHigh: 100,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0))
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        let model = Model(id: "small-images", name: "Small images", api: .anthropicMessages,
            provider: "anthropic", baseUrl: "https://example.invalid", reasoning: false,
            input: [.text, .image], cost: ModelCost(input: 0, output: 0, cacheRead: 0, cacheWrite: 0),
            contextWindow: 1000, maxTokens: 100,
            inputLimits: ModelInputLimits(images: ModelImageInputLimits(
                resize: ModelImageResizeOptions(maxWidth: 20, maxHeight: 20))))
        let enqueueModel = Model(id: "wide-images", name: "Wide images", api: .anthropicMessages,
            provider: "anthropic", baseUrl: "https://example.invalid", reasoning: false,
            input: [.text, .image], cost: ModelCost(input: 0, output: 0, cacheRead: 0, cacheWrite: 0),
            contextWindow: 1000, maxTokens: 100,
            inputLimits: ModelInputLimits(images: ModelImageInputLimits(
                resize: ModelImageResizeOptions(maxWidth: 80, maxHeight: 80))))
        let agent = Agent(AgentOptions(initialState: AgentState(systemPrompt: "Test", model: enqueueModel, tools: []),
                                       getApiKey: { _ in "test" }))
        let settings = SettingsManager.inMemory()
        settings.setAutoResizeImages(true)
        let agentSession = AgentSession(config: AgentSessionConfig(agent: agent,
            sessionManager: .inMemory(), settingsManager: settings,
            resourceLoader: TestResourceLoader(), modelRegistry: ModelRegistry(AuthStorage(":memory:"))))
        defer { agentSession.dispose() }
        let source = ImageContent(data: png.base64EncodedString(), mimeType: "image/png")
        let gate = CSESSGate()
        let calls = LockedState<[[Message]]>([])
        let callIndex = LockedState(0)
        agent.streamFn = { model, context, _ in
            calls.withLock { $0.append(context.messages) }
            let index = callIndex.withLock { value -> Int in defer { value += 1 }; return value }
            let stream = AssistantMessageEventStream()
            Task {
                if index == 0 { await gate.wait() }
                stream.push(.done(reason: .stop, message: AssistantMessage(
                    content: [.text(TextContent(text: "ok"))], api: model.api,
                    provider: model.provider, model: model.id,
                    usage: Usage(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0),
                    stopReason: .stop)))
            }
            return stream
        }
        let active = Task { try? await agent.prompt("running") }
        #expect(await waitUntil { agent.state.isStreaming })
        agentSession.steer("steer", images: [source])
        _ = await agentSession.followUp("follow up", images: [source], source: .interactive)
        _ = try await agentSession.submitPrompt("streaming prompt", options: PromptOptions(images: [source], streamingBehavior: .followUp))
        guard case .user(let queued)? = agent.peekQueuedMessages().first,
              case .blocks(let pending) = queued.content,
              case .image(let pendingImage)? = pending.last else {
            Issue.record("Expected queued image")
            await gate.open()
            await active.value
            return
        }
        #expect(pendingImage.data == source.data)
        #expect(pendingImage.mimeType == source.mimeType)
        // The queued bytes remain original, and the delivery-time model supplies the 20 px limit.
        agent.model = model
        await gate.open()
        await active.value
        #expect(await waitUntil { callIndex.withLock { $0 >= 4 } })
        #expect(!agent.hasQueuedMessages())
        let delivered = agentSession.sessionManager.getEntries().compactMap { entry -> UserMessage? in
            guard case .message(let messageEntry) = entry, case .user(let user) = messageEntry.message else { return nil }
            return user
        }
        for label in ["steer", "follow up", "streaming prompt"] {
            let user = try #require(delivered.first { user in
                if case .blocks(let blocks) = user.content, case .text(let first)? = blocks.first {
                    return first.text.hasPrefix(label + "\n\n")
                }
                return false
            })
            guard case .blocks(let blocks) = user.content,
                  case .image(let image)? = blocks.last,
                  case .text(let text)? = blocks.first else { throw AgentSessionError.invalidBoundaryDraft }
            #expect(resizeImage(image).originalWidth <= 20)
            #expect(image.data != source.data)
            #expect(text.text.contains("original 100x100, displayed at 20x20"))
        }
        #expect(calls.withLock { calls in
            !calls.flatMap { $0 }.contains { message in
                guard case .user(let user) = message, case .blocks(let blocks) = user.content else { return false }
                return blocks.contains { block in
                    if case .image(let image) = block { return image.data == source.data }
                    return false
                }
            }
        })
        #endif
    }

    // v1.5.2 4cf69332c, utils/image-process.ts:91: the model sees the exact omission hint.
    @Test("queued image resize failure uses the upstream omission text")
    func queuedInvalidImageUsesUpstreamHint() async throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let agentSession = try await session(dir.path)
        defer { agentSession.dispose() }
        installReplyStream(agentSession)
        try await agentSession.agent.prompt("start")
        agentSession.steer("inspect", images: [ImageContent(data: "cG5n", mimeType: "image/png")])
        try await agentSession.agent.continue()
        let matchingUsers = agentSession.agent.state.messages.compactMap { message -> UserMessage? in
            guard case .user(let user) = message,
                  case .blocks(let blocks) = user.content,
                  case .text(let first)? = blocks.first,
                  first.text.hasPrefix("inspect") else { return nil }
            return user
        }
        let user = try #require(matchingUsers.first)
        guard case .blocks(let blocks) = user.content,
              case .text(let text)? = blocks.first else { throw AgentSessionError.invalidBoundaryDraft }
        #expect(text.text == "inspect\n\n[Image omitted: could not be resized below the inline image size limit.]")
        #expect(!blocks.contains { if case .image = $0 { return true }; return false })
    }

    // 7860ff528, suite/regressions/11451-thinking-level-after-tree-navigation.test.ts
    @Test("records the live thinking level on the new branch before the next prompt")
    func recordsLiveThinkingLevelOnNewBranch() async throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = getModel(provider: .anthropic, modelId: "claude-sonnet-4-5")
        let agentSession = try await session(dir.path, model: model)
        defer { agentSession.dispose() }
        installReplyStream(agentSession)
        agentSession.setThinkingLevel(.high)
        try await agentSession.prompt("one")
        let firstAnswer = try #require(agentSession.sessionManager.getLeafId())
        agentSession.setThinkingLevel(.low)
        try await agentSession.prompt("two")
        let navigation = await agentSession.navigateTree(firstAnswer)
        #expect(!navigation.cancelled)
        #expect(agentSession.sessionManager.buildSessionContext().thinkingLevel == "high")
        try await agentSession.prompt("three")
        #expect(agentSession.agent.state.thinkingLevel == .low)
        #expect(agentSession.sessionManager.buildSessionContext().thinkingLevel == "low")
    }

    // 7860ff528, suite/regressions/11451-thinking-level-after-tree-navigation.test.ts
    @Test("does not record a level that only differs from the branch by clamping")
    func doesNotRecordClampedThinkingLevel() async throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = getModel(provider: .anthropic, modelId: "claude-sonnet-4-5")
        let agentSession = try await session(dir.path, model: model)
        defer { agentSession.dispose() }
        installReplyStream(agentSession)
        agentSession.setThinkingLevel(.high)
        agentSession.sessionManager.appendThinkingLevelChange("xhigh")
        try await agentSession.prompt("one")
        let levels = agentSession.sessionManager.getBranch().compactMap { entry -> String? in
            if case .thinkingLevel(let value) = entry { return value.thinkingLevel }
            return nil
        }
        #expect(levels.last == "xhigh")
    }

    // c3b938e3e, suite/regressions/9221-reload-during-tool.test.ts
    @Test("rejects direct reload without invalidating an active tool's context")
    func reloadRejectsActiveResponse() async throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let agentSession = try await session(dir.path)
        defer { agentSession.dispose() }
        installHangingStream(agentSession)
        let active = Task { try? await agentSession.prompt("running") }
        #expect(await waitUntil { agentSession.isStreaming })
        await #expect(throws: AgentSessionError.self) { try await agentSession.reloadChecked() }
        #expect(AgentSessionError.reloadDuringResponse.localizedDescription ==
            "Wait for the current response to finish before reloading.")
        await #expect(throws: AgentSessionError.self) {
            try await agentSession.navigateTreeChecked("unknown")
        }
        #expect(AgentSessionError.treeNavigationDuringResponse.localizedDescription ==
            "Wait for the current response to finish before navigating the session tree.")
        #expect((await agentSession.navigateTree("unknown")).cancelled)
        await agentSession.abort()
        await active.value
    }

    // c3b938e3e and 8a3e163b0, reload and prompt during tree summarization.
    @Test("rejects reload during tree navigation")
    func reloadAndPromptRejectBranchSummary() async throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let agentSession = try await session(dir.path)
        defer { agentSession.dispose() }
        let target = agentSession.sessionManager.appendMessage(.user(UserMessage(content: .text("first"))))
        agentSession.sessionManager.appendMessage(.user(UserMessage(content: .text("second"))))
        installHangingStream(agentSession)
        let navigation = Task { await agentSession.navigateTree(target, summarize: true) }
        #expect(await waitUntil { agentSession.isCompacting })
        await #expect(throws: AgentSessionError.self) { try await agentSession.reloadChecked() }
        #expect(AgentSessionError.reloadDuringCompaction.localizedDescription ==
            "Wait for compaction to finish before reloading.")
        await #expect(throws: AgentSessionError.self) { try await agentSession.prompt("overlap") }
        #expect(AgentSessionError.promptDuringCompaction.localizedDescription ==
            "Cannot submit a prompt while compaction is in progress. Wait for compaction to finish and retry.")
        await #expect(throws: AgentSessionError.self) { try await agentSession.navigateTreeChecked(target) }
        agentSession.abortBranchSummary()
        _ = await navigation.value
    }

    // c3b938e3e, suite/regressions/9221-reload-during-tool.test.ts
    @Test("rejects reload during compaction")
    func reloadRejectsCompaction() async throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let agentSession = try await session(dir.path)
        defer { agentSession.dispose() }
        let gate = CSESSGate()
        let started = LockedState(false)
        let compacting = Task {
            await agentSession.runAutoCompaction(reason: .threshold, willRetry: false) {
                started.withLock { $0 = true }
                await gate.wait()
                return nil
            }
        }
        #expect(await waitUntil { started.withLock { $0 } })
        #expect(agentSession.isCompacting)
        await #expect(throws: AgentSessionError.self) { try await agentSession.reloadChecked() }
        await gate.open()
        await compacting.value
    }

    // c3b938e3e, suite/regressions/9221-reload-during-tool.test.ts
    @Test("still reloads and replaces the runner when idle")
    func idleReloadSucceeds() async throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let agentSession = try await session(dir.path)
        defer { agentSession.dispose() }
        try await agentSession.reloadChecked()
        let extensions = await agentSession.reloadExtensions()
        #expect(extensions.errors.isEmpty)
        #expect(agentSession.isIdle)
    }

    // c3b938e3e, suite/regressions/9221-reload-during-tool.test.ts
    @Test("rejects command reload without invalidating an active tool's context")
    func commandReloadLeavesRunningToolIntact() async throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = getModel(provider: .anthropic, modelId: "claude-sonnet-4-5")
        let gate = CSESSGate()
        let started = LockedState(false)
        let contextStayedActive = LockedState(false)
        let sessionBox = LockedState<AgentSession?>(nil)
        let shutdowns = LockedState(0)
        let api = HookAPI()
        api.on("session_shutdown") { (_: SessionShutdownEvent, _: HookContext) in
            shutdowns.withLock { $0 += 1 }
            return nil
        }
        api.registerCommand("reload-runtime") { _, _ in
            try await sessionBox.withLock { $0 }?.reloadChecked()
        }
        let tool = AgentTool(label: "Wait", name: "wait", description: "Wait before success",
                             parameters: ["type": AnyCodable("object")]) { _, _, _, _ in
            started.withLock { $0 = true }
            await gate.wait()
            contextStayedActive.withLock { $0 = sessionBox.withLock { $0?.hookRunner?.hasHandlers("session_shutdown") ?? false } }
            return AgentToolResult(content: [.text(TextContent(text: "tool succeeded"))])
        }
        let requests = LockedState(0)
        let agent = Agent(AgentOptions(
            initialState: AgentState(systemPrompt: "Test", model: model, tools: [tool]),
            streamFn: { model, _, _ in
                let first = requests.withLock { value in value += 1; return value == 1 }
                let events = AssistantMessageEventStream()
                let message = AssistantMessage(
                    content: first ? [.toolCall(ToolCall(id: "wait-1", name: "wait", arguments: [:]))]
                        : [.text(TextContent(text: "done"))],
                    api: model.api, provider: model.provider, model: model.id,
                    usage: Usage(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0),
                    stopReason: first ? .toolUse : .stop)
                events.push(.done(reason: first ? .toolUse : .stop, message: message))
                return events
            }, getApiKey: { _ in "test" }))
        let manager = SessionManager.create(dir.path, dir.path)
        let auth = AuthStorage(":memory:")
        auth.setRuntimeApiKey(model.provider, "test")
        let registry = ModelRegistry(auth)
        let hook = LoadedHook(path: "csess", resolvedPath: "csess", handlers: api.handlers,
                              currentHandlers: { api.handlers }, commands: api.commands,
                              currentCommands: { api.commands }, isExtension: true)
        let runner = HookRunner([hook], dir.path, manager, registry)
        let agentSession = AgentSession(config: AgentSessionConfig(agent: agent, sessionManager: manager,
            settingsManager: .inMemory(), resourceLoader: TestResourceLoader(), hookRunner: runner,
            modelRegistry: registry))
        sessionBox.withLock { $0 = agentSession }
        defer { agentSession.dispose() }
        let prompt = Task { try await agentSession.prompt("run tool") }
        #expect(await waitUntil { started.withLock { $0 } })
        await #expect(throws: AgentSessionError.self) { try await agentSession.reloadChecked() }
        await #expect(throws: AgentSessionError.self) { try await agentSession.prompt("/reload-runtime") }
        #expect(agentSession.hookRunner === runner)
        #expect(shutdowns.withLock { $0 } == 0)
        await gate.open()
        try await prompt.value
        #expect(contextStayedActive.withLock { $0 })
        let file = try #require(manager.getSessionFile())
        #expect(SessionManager.open(file).getEntries().contains { entry in
            guard case .message(let message) = entry,
                  case .toolResult(let result) = message.message else { return false }
            return result.content.contains { block in
                if case .text(let text) = block { return text.text == "tool succeeded" }
                return false
            }
        })
    }

    // 8a3e163b0, suite/regressions/9154-prompt-during-tree-navigation.test.ts
    @Test("allows a prompt from session_tree after the selected context is installed")
    func sessionTreeHookCanPromptAfterInstall() async throws {
        let manager = SessionManager.inMemory()
        let first = manager.appendMessage(.user(UserMessage(content: .text("first"))))
        manager.appendMessage(.user(UserMessage(content: .text("second"))))
        let sessionBox = LockedState<AgentSession?>(nil)
        let errors = LockedState<[String]>([])
        let api = HookAPI()
        api.on("session_tree") { (_: SessionTreeEvent, _: HookContext) in
            if let session = sessionBox.withLock({ $0 }) {
                do { try await session.prompt("from tree") }
                catch { errors.withLock { $0.append(error.localizedDescription) } }
            }
            return nil
        }
        let agentSession = hookedSession(manager, api)
        sessionBox.withLock { $0 = agentSession }
        defer { agentSession.dispose() }
        let result = await agentSession.navigateTree(first)
        #expect(!result.cancelled)
        #expect(errors.withLock { $0 }.isEmpty)
        #expect(await waitUntil {
            manager.getEntries().contains { entry in
                guard case .message(let value) = entry, case .user(let user) = value.message else { return false }
                switch user.content {
                case .text(let text): return text == "from tree"
                case .blocks(let blocks): return blocks.contains { block in
                    if case .text(let content) = block { return content.text == "from tree" }
                    return false
                }
                }
            }
        })
    }

    // 8a3e163b0, suite/regressions/9154-prompt-during-tree-navigation.test.ts
    @Test("does not clear a new navigation started from session_tree")
    func nestedNavigationKeepsItsGuard() async throws {
        let manager = SessionManager.inMemory()
        let first = manager.appendMessage(.user(UserMessage(content: .text("first"))))
        let second = manager.appendMessage(.user(UserMessage(content: .text("second"))))
        manager.appendMessage(.user(UserMessage(content: .text("third"))))
        let gate = CSESSGate()
        let started = LockedState(false)
        let beforeCount = LockedState(0)
        let treeCount = LockedState(0)
        let sessionBox = LockedState<AgentSession?>(nil)
        let api = HookAPI()
        api.on("session_before_tree") { (_: SessionBeforeTreeEvent, _: HookContext) in
            let count = beforeCount.withLock { value in value += 1; return value }
            if count == 2 {
                started.withLock { $0 = true }
                await gate.wait()
            }
            return nil
        }
        api.on("session_tree") { (_: SessionTreeEvent, _: HookContext) in
            let count = treeCount.withLock { value in value += 1; return value }
            if count == 1, let session = sessionBox.withLock({ $0 }) {
                _ = await session.navigateTree(second)
            }
            return nil
        }
        let agentSession = hookedSession(manager, api)
        sessionBox.withLock { $0 = agentSession }
        defer { agentSession.dispose() }
        let outer = Task { await agentSession.navigateTree(first) }
        #expect(await waitUntil { started.withLock { $0 } })
        #expect(agentSession.isCompacting)
        await #expect(throws: AgentSessionError.self) { try await agentSession.prompt("blocked") }
        await gate.open()
        _ = await outer.value
        #expect(!agentSession.isCompacting)
    }

    // 8a3e163b0, suite/regressions/9154-prompt-during-tree-navigation.test.ts
    @Test("rejects navigation during an awaited input or before_agent_start hook", arguments: ["input", "before_agent_start"])
    func navigationRejectsAwaitedPromptHook(_ stage: String) async throws {
        let manager = SessionManager.inMemory()
        let target = manager.appendMessage(.user(UserMessage(content: .text("first"))))
        manager.appendMessage(.user(UserMessage(content: .text("second"))))
        let gate = CSESSGate()
        let started = LockedState(false)
        let api = HookAPI()
        if stage == "input" {
            api.on("input") { (event: InputEvent, _: HookContext) in
                if event.text == "racing prompt" {
                    started.withLock { $0 = true }
                    await gate.wait()
                }
                return InputEventResult.continue
            }
        } else {
            api.on("before_agent_start") { (_: BeforeAgentStartEvent, _: HookContext) in
                started.withLock { $0 = true }
                await gate.wait()
                return nil
            }
        }
        let agentSession = hookedSession(manager, api)
        defer { agentSession.dispose() }
        let prompt = Task { try await agentSession.prompt("racing prompt") }
        #expect(await waitUntil { started.withLock { $0 } })
        await #expect(throws: AgentSessionError.self) { try await agentSession.navigateTreeChecked(target) }
        await gate.open()
        try await prompt.value
        #expect(!(try await agentSession.navigateTreeChecked(target)).cancelled)
    }

    // 8a3e163b0, suite/regressions/9154-prompt-during-tree-navigation.test.ts
    @Test("keeps navigation blocked when another prompt finishes preflight first")
    func secondHandledPromptDoesNotReleaseFirstPreflight() async throws {
        let manager = SessionManager.inMemory()
        let target = manager.appendMessage(.user(UserMessage(content: .text("first"))))
        manager.appendMessage(.user(UserMessage(content: .text("second"))))
        let gate = CSESSGate()
        let started = LockedState(false)
        let api = HookAPI()
        api.on("input") { (event: InputEvent, _: HookContext) in
            if event.text == "waiting prompt" {
                started.withLock { $0 = true }
                await gate.wait()
            }
            return InputEventResult.handled
        }
        let agentSession = hookedSession(manager, api)
        defer { agentSession.dispose() }
        let waiting = Task { try await agentSession.prompt("waiting prompt") }
        #expect(await waitUntil { started.withLock { $0 } })
        try await agentSession.prompt("handled immediately")
        await #expect(throws: AgentSessionError.self) { try await agentSession.navigateTreeChecked(target) }
        await gate.open()
        try await waiting.value
        #expect(!(try await agentSession.navigateTreeChecked(target)).cancelled)
    }

    // 8a3e163b0, suite/regressions/9154-prompt-during-tree-navigation.test.ts
    @Test("allows navigation after a prompt is handled during preflight")
    func navigationAfterHandledPreflight() async throws {
        let manager = SessionManager.inMemory()
        let target = manager.appendMessage(.user(UserMessage(content: .text("first"))))
        manager.appendMessage(.user(UserMessage(content: .text("second"))))
        let api = HookAPI()
        api.on("input") { (_: InputEvent, _: HookContext) in InputEventResult.handled }
        let agentSession = hookedSession(manager, api)
        defer { agentSession.dispose() }
        try await agentSession.prompt("not sent to the model")
        #expect(!(try await agentSession.navigateTreeChecked(target)).cancelled)
    }

    // 8a3e163b0, suite/regressions/9154-prompt-during-tree-navigation.test.ts
    @Test("allows navigation after a prompt is rejected during preflight")
    func navigationAfterRejectedPreflight() async throws {
        let manager = SessionManager.inMemory()
        let target = manager.appendMessage(.user(UserMessage(content: .text("first"))))
        manager.appendMessage(.user(UserMessage(content: .text("second"))))
        let model = Model(id: "unauthenticated", name: "Unauthenticated", api: .openAICompletions,
            provider: "csess-no-auth", baseUrl: "https://example.invalid", reasoning: false,
            input: [.text], cost: ModelCost(input: 0, output: 0, cacheRead: 0, cacheWrite: 0),
            contextWindow: 1000, maxTokens: 100)
        let agent = Agent(AgentOptions(initialState: AgentState(systemPrompt: "Test", model: model, tools: [])))
        let agentSession = AgentSession(config: AgentSessionConfig(agent: agent, sessionManager: manager,
            settingsManager: .inMemory(), resourceLoader: TestResourceLoader(),
            modelRegistry: ModelRegistry(AuthStorage(":memory:"))))
        defer { agentSession.dispose() }
        await #expect(throws: AgentSessionError.self) { try await agentSession.prompt("not sent to the model") }
        #expect(!(try await agentSession.navigateTreeChecked(target)).cancelled)
    }

    // 8a3e163b0, suite/regressions/9154-prompt-during-tree-navigation.test.ts
    @Test("allows navigation from an extension command")
    func navigationFromExtensionCommand() async throws {
        let manager = SessionManager.inMemory()
        let model = getModel(provider: .openai, modelId: "gpt-4o-mini")
        manager.appendMessage(.user(UserMessage(content: .text("first"))))
        let target = manager.appendMessage(.assistant(AssistantMessage(
            content: [.text(TextContent(text: "first response"))], api: model.api,
            provider: model.provider, model: model.id,
            usage: Usage(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0), stopReason: .stop)))
        manager.appendMessage(.user(UserMessage(content: .text("second"))))
        let sessionBox = LockedState<AgentSession?>(nil)
        let api = HookAPI()
        api.registerCommand("rewind") { _, _ in
            if let session = sessionBox.withLock({ $0 }) { _ = await session.navigateTree(target) }
        }
        let agentSession = hookedSession(manager, api)
        sessionBox.withLock { $0 = agentSession }
        defer { agentSession.dispose() }
        try await agentSession.prompt("/rewind")
        #expect(manager.getLeafId() == target)
    }

    // 8a3e163b0, suite/regressions/9154-prompt-during-tree-navigation.test.ts
    @Test("allows navigation from an extension agent_settled")
    func navigationFromAgentSettled() async throws {
        let manager = SessionManager.inMemory()
        let model = getModel(provider: .openai, modelId: "gpt-4o-mini")
        manager.appendMessage(.user(UserMessage(content: .text("first"))))
        let target = manager.appendMessage(.assistant(AssistantMessage(
            content: [.text(TextContent(text: "first response"))], api: model.api,
            provider: model.provider, model: model.id,
            usage: Usage(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0), stopReason: .stop)))
        manager.appendMessage(.user(UserMessage(content: .text("second"))))
        let sessionBox = LockedState<AgentSession?>(nil)
        let calls = LockedState(0)
        let api = HookAPI()
        api.on("agent_settled") { (_: AgentSettledEvent, _: HookContext) in
            let count = calls.withLock { value in value += 1; return value }
            if count == 1, let session = sessionBox.withLock({ $0 }) {
                _ = await session.navigateTree(target)
            }
            return nil
        }
        let agentSession = hookedSession(manager, api)
        sessionBox.withLock { $0 = agentSession }
        defer { agentSession.dispose() }
        try await agentSession.prompt("finish then rewind")
        #expect(manager.getLeafId() == target)
    }

    // 7a53c310a, suite/regressions/9124-runtime-dispose-tool-settlement.test.ts
    @Test("persists the aborted tool turn before disconnecting the session")
    func disposeWaitsForAbortedToolResult() async throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = getModel(provider: .anthropic, modelId: "claude-sonnet-4-5")
        let started = LockedState(false)
        struct ToolAborted: LocalizedError { var errorDescription: String? { "Operation aborted" } }
        let tool = AgentTool(label: "Wait", name: "wait", description: "Wait until aborted",
                             parameters: ["type": AnyCodable("object")]) { _, _, signal, _ in
            started.withLock { $0 = true }
            while signal?.isCancelled != true {
                try await Task.sleep(nanoseconds: 5_000_000)
            }
            throw ToolAborted()
        }
        let requests = LockedState(0)
        let agent = Agent(AgentOptions(
            initialState: AgentState(systemPrompt: "Test", model: model, tools: [tool]),
            streamFn: { model, _, _ in
                let count = requests.withLock { value in value += 1; return value }
                let events = AssistantMessageEventStream()
                let first = count == 1
                let message = AssistantMessage(
                    content: first ? [.toolCall(ToolCall(id: "wait-1", name: "wait", arguments: [:]))]
                        : [.text(TextContent(text: "done"))],
                    api: model.api, provider: model.provider, model: model.id,
                    usage: Usage(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0),
                    stopReason: first ? .toolUse : .stop)
                events.push(.done(reason: first ? .toolUse : .stop, message: message))
                return events
            }, getApiKey: { _ in "test" }))
        let manager = SessionManager.create(dir.path, dir.path)
        let auth = AuthStorage(":memory:")
        auth.setRuntimeApiKey(model.provider, "test")
        let agentSession = AgentSession(config: AgentSessionConfig(agent: agent, sessionManager: manager,
            settingsManager: .inMemory(), resourceLoader: TestResourceLoader(), modelRegistry: ModelRegistry(auth)))
        let runtime = AgentSessionRuntime(agentDir: dir.path, factory: { _ in
            throw AgentSessionRuntimeError.sessionCwdExists
        }, initialSession: agentSession)
        let prompt = Task { try? await agentSession.prompt("run tool") }
        #expect(await waitUntil { started.withLock { $0 } })
        await runtime.disposeAndWait()
        let file = try #require(manager.getSessionFile())
        let messages = SessionManager.open(file).getEntries().compactMap { entry -> AgentMessage? in
            if case .message(let value) = entry, value.message.role != "system" { return value.message }
            return nil
        }
        #expect(messages.map(\.role) == ["user", "assistant", "toolResult", "assistant"])
        if messages.count > 2, case .toolResult(let result) = messages[2] {
            #expect(result.isError)
            #expect(result.content.contains { block in
                if case .text(let text) = block { return text.text == "Operation aborted" }
                return false
            })
        } else {
            Issue.record("Expected persisted tool result")
        }
        await prompt.value
    }

    // 5732bac06, suite/agent-session-model-extension.test.ts
    @Test("cycles to the only scoped model and to the first scoped model from outside the scope")
    func cyclesToOnlyScopedModelOutsideScope() async throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let outside = getModel(provider: .openai, modelId: "gpt-4o-mini")
        let only = getModel(provider: .anthropic, modelId: "claude-sonnet-4-5")
        let agentSession = try await session(dir.path, model: outside, scope: [ScopedModel(model: only)])
        defer { agentSession.dispose() }
        agentSession.modelRegistry.authStorage.setRuntimeApiKey(only.provider, "test")
        let selected = try await agentSession.cycleModel()
        #expect(selected?.model.id == only.id)
        #expect(try await agentSession.cycleModel() == nil)
    }

    // 5732bac06, suite/agent-session-model-extension.test.ts: available-model path.
    @Test("cycles to the first available model from outside the available set")
    func cyclesToFirstAvailableModelOutsideSet() async throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let outside = getModel(provider: .openai, modelId: "gpt-4o-mini")
        let auth = AuthStorage(":memory:")
        auth.setRuntimeApiKey("anthropic", "test")
        let registry = ModelRegistry(auth, dir.path)
        let available = await registry.getAvailable()
        let first = try #require(available.first)
        #expect(!available.contains { $0.provider == outside.provider && $0.id == outside.id })
        let agent = Agent(AgentOptions(initialState: AgentState(systemPrompt: "Test", model: outside, tools: [])))
        let agentSession = AgentSession(config: AgentSessionConfig(agent: agent,
            sessionManager: .inMemory(dir.path), settingsManager: .inMemory(),
            resourceLoader: TestResourceLoader(), modelRegistry: registry))
        defer { agentSession.dispose() }
        let next = try await agentSession.cycleModel()
        #expect(next?.model.id == first.id)
        #expect(next?.model.provider == first.provider)
    }

    // 4ea883792, file-operations.test.ts: fork rollback after a failed replacement.
    @Test("fork rollback after a failed replacement")
    func failedFactoryLeavesCurrentSessionAndNoProvisionalFork() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let old = root.appendingPathComponent("old")
        let current = root.appendingPathComponent("current")
        let sessions = root.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: current, withIntermediateDirectories: true)
        let source = SessionManager.create(old.path, sessions.path)
        source.appendMessage(.user(UserMessage(content: .text("hello"))))
        let sourcePath = try #require(source.getSessionFile())
        try FileManager.default.removeItem(at: old)

        let initial = try await session(current.path)
        defer { initial.dispose() }
        struct FactoryFailure: Error {}
        let runtime = AgentSessionRuntime(agentDir: current.path, factory: { _ in throw FactoryFailure() },
                                          initialSession: initial)
        await #expect(throws: FactoryFailure.self) {
            try await runtime.forkMissingCwd(sourcePath, into: current.path, sessionDir: sessions.path)
        }
        #expect(runtime.session === initial)
        let files = try FileManager.default.contentsOfDirectory(atPath: sessions.path)
        #expect(files.filter { $0.hasSuffix(".jsonl") }.count == 1)
    }

    // 4ea883792, interactive-mode-import-command.test.ts: missing-cwd import leaves no copy.
    @Test("import of a missing-cwd session leaves no provisional copy")
    func missingCwdImportLeavesNoProvisionalCopy() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let old = root.appendingPathComponent("old")
        let current = root.appendingPathComponent("current")
        let sessions = root.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: current, withIntermediateDirectories: true)
        let source = SessionManager.create(old.path, sessions.path)
        source.appendMessage(.user(UserMessage(content: .text("hello"))))
        let sourcePath = try #require(source.getSessionFile())
        try FileManager.default.removeItem(at: old)
        let initial = try await session(current.path, manager: SessionManager.inMemory(current.path))
        defer { initial.dispose() }
        let runtime = AgentSessionRuntime(agentDir: current.path, factory: { _ in
            throw AgentSessionRuntimeError.sessionCwdExists
        }, initialSession: initial)
        await #expect(throws: AgentSessionRuntimeError.self) {
            try await runtime.importFromJsonl(sourcePath)
        }
        #expect(runtime.session === initial)
        let files = try FileManager.default.contentsOfDirectory(atPath: sessions.path)
        #expect(files.filter { $0.hasSuffix(".jsonl") }.count == 1)
    }

    // 4ea883792, agent-session-runtime.test.ts: extension veto removes the fork.
    @Test("removes the fork when an extension cancels the switch")
    func extensionVetoRemovesProvisionalFork() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let old = root.appendingPathComponent("old")
        let current = root.appendingPathComponent("current")
        let sessions = root.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: current, withIntermediateDirectories: true)
        let source = SessionManager.create(old.path, sessions.path)
        source.appendMessage(.user(UserMessage(content: .text("hello"))))
        let sourcePath = try #require(source.getSessionFile())
        try FileManager.default.removeItem(at: old)
        let api = HookAPI()
        api.on("session_before_switch") { (_: SessionBeforeSwitchEvent, _: HookContext) in
            SessionBeforeSwitchResult(cancel: true)
        }
        let initial = hookedSession(.inMemory(current.path), api)
        defer { initial.dispose() }
        let runtime = AgentSessionRuntime(agentDir: current.path, factory: { _ in
            throw AgentSessionRuntimeError.sessionCwdExists
        }, initialSession: initial)
        await #expect(throws: AgentSessionRuntimeError.self) {
            try await runtime.forkMissingCwd(sourcePath, into: current.path, sessionDir: sessions.path)
        }
        #expect(runtime.session === initial)
        let files = try FileManager.default.contentsOfDirectory(atPath: sessions.path)
        #expect(files.filter { $0.hasSuffix(".jsonl") }.count == 1)
    }

    // 4ea883792, interactive-mode-import-command.test.ts: canceled import leaves no copy.
    @Test("a cancelled import leaves no copied session")
    func cancelledImportLeavesNoCopy() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let old = root.appendingPathComponent("old")
        let current = root.appendingPathComponent("current")
        let originals = root.appendingPathComponent("originals")
        let imports = root.appendingPathComponent("imports")
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: current, withIntermediateDirectories: true)
        let source = SessionManager.create(old.path, originals.path)
        source.appendMessage(.user(UserMessage(content: .text("hello"))))
        let sourcePath = try #require(source.getSessionFile())
        let api = HookAPI()
        api.on("session_before_switch") { (_: SessionBeforeSwitchEvent, _: HookContext) in
            SessionBeforeSwitchResult(cancel: true)
        }
        let initial = hookedSession(.create(current.path, imports.path), api)
        defer { initial.dispose() }
        let result = try await initial.importFromJsonl(sourcePath, fallbackCwd: current.path)
        #expect(result.cancelled)
        let files = try FileManager.default.contentsOfDirectory(atPath: imports.path)
        #expect(files.filter { $0.hasSuffix(".jsonl") }.isEmpty)
        #expect(FileManager.default.fileExists(atPath: sourcePath))
    }
}
