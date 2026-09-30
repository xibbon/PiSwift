import Foundation
import Testing
import PiSwiftAI
import PiSwiftAgent
#if canImport(AppKit)
import AppKit
#endif
@testable import PiSwiftCodingAgent

private func c1Directory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("pi-c1-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private struct C1CatalogClient: ProviderHTTPClient {
    let seen: LockedState<URL?>
    func send(_ request: URLRequest) async throws -> ProviderHTTPResponse {
        seen.withLock { $0 = request.url }
        return ProviderHTTPResponse(statusCode: 200, body: Data("[]".utf8))
    }
}

@Test func c1SettingsToolModifiersWheelAndDeviceId() async throws {
    let root = try c1Directory()
    defer { try? FileManager.default.removeItem(at: root) }
    let project = root.appendingPathComponent("project")
    let config = project.appendingPathComponent(CONFIG_DIR_NAME)
    try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
    try Data(#"{"defaultTools":["read","bash"],"mouseWheelStep":7}"#.utf8)
        .write(to: root.appendingPathComponent("settings.json"))
    try Data(#"{"defaultTools":["-bash","+grep"],"deviceId":"project-id"}"#.utf8)
        .write(to: config.appendingPathComponent("settings.json"))
    let manager = SettingsManager.create(project.path, root.path)
    #expect(manager.getDefaultTools() == ["read", "grep"])
    #expect(manager.getFullscreenWheelScrollLines() == .lines(7))
    let deviceId = manager.getOrCreateDeviceId()
    #expect(deviceId != "project-id")
    #expect(manager.getOrCreateDeviceId() == deviceId)
    let concurrentIds = await withTaskGroup(of: String.self, returning: [String].self) { group in
        for _ in 0..<16 { group.addTask { manager.getOrCreateDeviceId() } }
        var values: [String] = []
        for await value in group { values.append(value) }
        return values
    }
    #expect(Set(concurrentIds) == [deviceId])
    manager.setFullscreenWheelScrollLines(.lines(120))
    #expect(manager.getFullscreenWheelScrollLines() == .lines(100))
    await manager.flush()
    let reloaded = SettingsManager.create(project.path, root.path)
    #expect(reloaded.getOrCreateDeviceId() == deviceId)
    let global = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("settings.json"))) as? [String: Any])
    #expect(global["fullscreenWheelScrollLines"] as? Int == 100)
    #expect(global["deviceId"] as? String == deviceId)
    var copy = manager.getSettings()
    copy.defaultTools = []
    #expect(manager.getDefaultTools() == ["read", "grep"])
}

@Test func c1DefaultToolModifiersStartFromBuiltins() {
    var settings = Settings()
    settings.defaultTools = ["-bash", "+grep", "+grep"]
    #expect(SettingsManager.inMemory(settings).getDefaultTools() == ["read", "edit", "write", "grep"])
    settings.defaultTools = []
    #expect(SettingsManager.inMemory(settings).getDefaultTools() == [])
    #expect(SettingsManager.inMemory().getFullscreenWheelScrollLines() == .auto)
    #expect((try? JSONEncoder().encode(WheelScrollLines.auto)) == Data(#""auto""#.utf8))
    #expect((try? JSONDecoder().decode(WheelScrollLines.self, from: Data("0".utf8))) == .lines(1))
}

@Test func c1BugReportOmitsDeviceId() throws {
    let input = BugReportMetadataInput(id: "c1", sessionId: "session", cwd: "/tmp", includeSession: false,
        includeSummary: false, messageCount: 0, thinkingLevel: "off",
        globalSettings: ["deviceId": AnyCodable("global-secret")],
        projectSettings: ["deviceId": AnyCodable("project-secret")])
    let metadata = collectBugReportMetadata(input, environment: [:])
    let bundle = try makeBugReportBundle(metadata: metadata, session: SessionManager.inMemory(), includeSession: false)
    let report = try #require(bugReportFiles(bundle).first).data
    #expect(!report.contains("global-secret") && !report.contains("project-secret"))
}

@Test func c1RegistryKeepsChatReadsAndResolvesOtherTypes() async throws {
    let registry = ModelRegistry(AuthStorage(":memory:"))
    #expect(registry.getAll().count > 0)
    #expect(registry.getAllModels().count > registry.getAll().count)
    #expect(registry.getAllModels().filter { $0.type == .chat }.count == registry.getAll().count)
    let image = try #require(registry.getModelsOfType(.image).first)
    #expect(registry.getModelOfType(.image, provider: image.provider, modelId: image.id)?.id == image.id)
    if case .image(let model) = image {
        let result = await registry.generateImages(model, context: ImagesContext(input: []))
        #expect(result.stopReason == .error)
    }
    let classifier = try #require(registry.getModelsOfType(.classifier).first)
    #expect(registry.getModelOfType(.classifier, provider: "typesafe", modelId: "jev-latest") != nil)
    if case .classifier(let model) = classifier {
        let result = await registry.classify(model, context: ClassifierContext(state: [:], questions: [:]))
        #expect(result.stopReason == .error)
    }
    #expect(await registry.getAvailableOfType(.image).isEmpty)
}

@Test func c1ProviderWithoutModelListKeepsBuiltinImages() async throws {
    let root = try c1Directory()
    defer { try? FileManager.default.removeItem(at: root) }
    try Data(#"{"providers":{"openrouter":{"baseUrl":"https://example.invalid/images","apiKey":"test"}}}"#.utf8)
        .write(to: root.appendingPathComponent("models.json"))
    let registry = ModelRegistry(AuthStorage(":memory:"), root.path)
    let images = registry.getModelsOfType(.image, provider: "openrouter")
    #expect(!images.isEmpty)
    if case .image(let model) = try #require(images.first) {
        #expect(model.baseUrl == "https://example.invalid/images")
        #expect((await registry.resolveModelRequest(model)).auth.ok)
    }
}

@Test func c1BuiltinResolverAndReplacementWarning() async throws {
    let root = try c1Directory()
    defer { try? FileManager.default.removeItem(at: root) }
    var settings = Settings()
    settings.extensions = ["-builtin:mcp"]
    let manager = SettingsManager.inMemory(settings)
    let loader = DefaultResourceLoader(DefaultResourceLoaderOptions(
        cwd: root.path, agentDir: root.path, settingsManager: manager,
        builtinExtensions: ["mcp", "codemode"]
    ))
    await loader.reload()
    #expect(!loader.getExtensions().paths.contains("builtin:mcp"))
    #expect(loader.getExtensions().paths.contains("builtin:codemode"))
    let explicit = DefaultResourceLoader(DefaultResourceLoaderOptions(
        cwd: root.path, agentDir: root.path, settingsManager: manager,
        additionalExtensionPaths: ["builtin:mcp"], noExtensions: true,
        builtinExtensions: ["mcp", "codemode"]
    ))
    await explicit.reload()
    #expect(explicit.getExtensions().paths == ["builtin:mcp"])

    let bus = createEventBus()
    let builtIn = try #require(ExtensionLoader.load(InlineExtension(name: "mcp", builtin: true, replaceable: true) { api in
        api.registerCommand("mcp") { _, _ in }
    }, cwd: root.path, eventBus: bus).hook)
    let other = try #require(ExtensionLoader.load(InlineExtension(name: "other") { api in
        api.registerCommand("mcp") { _, _ in }
    }, cwd: root.path, eventBus: bus).hook)
    let result = omitReplacedExtensions([builtIn, other])
    #expect(result.hooks.map(\.path) == ["<inline:other>"])
    #expect(result.warnings.count == 1)
    #expect(result.warnings[0].path == "builtin:mcp")
    #expect(getSyntheticPathSource("builtin:read") == "builtin")
    #expect(isSyntheticPath("<inline:other>"))
}

@Test func c1BuiltinWarningsReachStartupDiagnosticsAndNoExtensions() async throws {
    let model = try #require(getModel(provider: .anthropic, modelId: "claude-sonnet-4-5"))
    let auth = AuthStorage.inMemory([model.provider: .apiKey(ApiKeyCredential(key: "test"))])
    let loads = LockedState(0)
    let builtin = InlineExtension(name: "mcp", builtin: true, replaceable: true) { api in
        loads.withLock { $0 += 1 }
        api.registerCommand("mcp") { _, _ in }
    }
    let replacement = InlineExtension(name: "other") { api in
        api.registerCommand("mcp") { _, _ in }
    }
    let base = CreateAgentSessionOptions(authStorage: auth, modelRegistry: ModelRegistry(auth), model: model,
        projectTrusted: false, noTools: .all, resourceLoader: TestResourceLoader(),
        inlineExtensions: [builtin, replacement], sessionManager: SessionManager.inMemory(),
        settingsManager: SettingsManager.inMemory())
    let result = await createAgentSession(base)
    defer { result.session.dispose() }
    #expect(result.diagnostics.contains { $0.path == "builtin:mcp" && $0.type == "warning" })
    #expect(loads.withLock { $0 } == 1)

    let disabled = await createAgentSession(CreateAgentSessionOptions(authStorage: auth,
        modelRegistry: ModelRegistry(auth), model: model, projectTrusted: false, noTools: .all,
        resourceLoader: TestResourceLoader(), inlineExtensions: [builtin], noExtensions: true,
        sessionManager: SessionManager.inMemory(), settingsManager: SettingsManager.inMemory()))
    defer { disabled.session.dispose() }
    #expect(loads.withLock { $0 } == 1)
    let explicit = await createAgentSession(CreateAgentSessionOptions(authStorage: auth,
        modelRegistry: ModelRegistry(auth), model: model, projectTrusted: false, noTools: .all,
        resourceLoader: TestResourceLoader(), additionalExtensionPaths: ["builtin:mcp"],
        inlineExtensions: [builtin], noExtensions: true,
        sessionManager: SessionManager.inMemory(), settingsManager: SettingsManager.inMemory()))
    defer { explicit.session.dispose() }
    #expect(loads.withLock { $0 } == 2)
}

@Test func c1RemoteCatalogRequestsAllTypes() async throws {
    let seen = LockedState<URL?>(nil)
    let provider = RemoteCatalogProvider(providerId: "openai", catalogBaseURL: "https://example.invalid",
        localGeneratedAt: nil, httpClient: C1CatalogClient(seen: seen), updateOverlay: { _ in })
    let context = RefreshModelsContext(credential: nil, stored: nil, allowNetwork: true, force: true,
        signal: CancellationToken(), publish: { _ in true })
    try await provider.refresh(context)
    let url = try #require(seen.withLock { $0 })
    #expect(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "types" })?.value == "chat,image,classifier")
    let chat = getModel(provider: .openai, modelId: "gpt-4o-mini")
    let image = ImageModel(id: chat.id, name: "Image", api: .openrouterImages, provider: chat.provider,
        baseUrl: chat.baseUrl, input: [.text], output: [.image], cost: chat.cost)
    let merged = provider.mergeModels(baseline: [AnyModel.chat(chat)], dynamic: [.image(image)])
    #expect(merged.count == 2)
}

@Test func c1GitDependencyFlagsAndPinnedTemporaryPath() throws {
    let root = try c1Directory()
    defer { try? FileManager.default.removeItem(at: root) }
    func manager(_ command: [String]) -> DefaultPackageManager {
        var settings = Settings()
        settings.npmCommand = command
        return DefaultPackageManager(cwd: root.path, agentDir: root.path,
            settingsManager: SettingsManager.inMemory(settings))
    }
    #expect(try manager(["npm"]).gitDependencyInstallArgs() == ["install", "--omit=dev", "--legacy-peer-deps"])
    #expect(try manager(["pnpm"]).gitDependencyInstallArgs().contains("--config.auto-install-peers=false"))
    #expect(try manager(["bun"]).gitDependencyInstallArgs() == ["install", "--omit=dev", "--omit=peer"])
    #expect(try manager(["mise", "exec", "node@20", "--", "npm"]).gitDependencyInstallArgs().contains("--legacy-peer-deps"))
    do {
        _ = try manager(["mise", "pnpm", "bun"]).gitDependencyInstallArgs()
        Issue.record("Expected an ambiguous package manager error")
    } catch {
        #expect(error.localizedDescription.contains("Ambiguous"))
    }
    let first = manager(["npm"]).temporaryGitDirectory(host: "github.com", path: "org/repo", ref: "one")
    let second = manager(["npm"]).temporaryGitDirectory(host: "github.com", path: "org/repo", ref: "two")
    #expect(first != second)
    #expect(first.hasSuffix("org/repo") && second.hasSuffix("org/repo"))
}

@Test func c1CombineUsageKeepsOptionalFields() {
    let first = Usage(input: 1, output: 2, cacheRead: 3, cacheWrite: 4, cacheWrite1h: 2,
                      totalTokens: 10, cost: UsageCost(input: 1, output: 2, cacheRead: 3, cacheWrite: 4, total: 10))
    let second = Usage(input: 5, output: 6, cacheRead: 7, cacheWrite: 8, reasoning: 3,
                       totalTokens: 26, cost: UsageCost(input: 5, output: 6, cacheRead: 7, cacheWrite: 8, total: 26))
    let sum = combineUsage(first, second)
    #expect(sum.input == 6 && sum.output == 8 && sum.cacheRead == 10 && sum.cacheWrite == 12)
    #expect(sum.cacheWrite1h == 2 && sum.reasoning == 3)
    #expect(sum.totalTokens == 36 && sum.cost.total == 36)
}

@Test func c1SessionEntryCountAndExtensionSettingsCopy() async throws {
    let sessionManager = SessionManager.inMemory()
    #expect(sessionManager.getEntryCount() == 0)
    sessionManager.appendMessage(userMsg("first"))
    #expect(sessionManager.getEntryCount() == 1)

    let model = getModel(provider: .anthropic, modelId: "claude-sonnet-4-5")
    let auth = AuthStorage.inMemory([model.provider: .apiKey(ApiKeyCredential(key: "test"))])
    var settings = Settings()
    settings.defaultTools = ["read"]
    let settingsManager = SettingsManager.inMemory(settings)
    let seen = LockedState<[String]?>(nil)
    let result = await createAgentSession(CreateAgentSessionOptions(
        authStorage: auth, modelRegistry: ModelRegistry(auth), model: model,
        projectTrusted: false, noTools: .all, resourceLoader: TestResourceLoader(),
        hooks: [HookDefinition(path: "<c1:settings>") { api in
            api.registerCommand("settings-copy") { _, _ in
                var copy = api.getSettings()
                seen.withLock { $0 = copy.defaultTools }
                copy.defaultTools = []
            }
        }], sessionManager: SessionManager.inMemory(), settingsManager: settingsManager
    ))
    defer { result.session.dispose() }
    try await result.session.prompt("/settings-copy")
    #expect(seen.withLock { $0 } == ["read"])
    #expect(settingsManager.getDefaultTools() == ["read"])
}

@Test func c1PromptAndQueuedInputDispositions() async throws {
    let model = try #require(getModel(provider: .anthropic, modelId: "claude-sonnet-4-5"))
    let auth = AuthStorage.inMemory([model.provider: .apiKey(ApiKeyCredential(key: "test"))])
    let registry = ModelRegistry(auth)
    let agent = Agent(AgentOptions(
        initialState: AgentState(systemPrompt: "Test", model: model, tools: []),
        streamFn: { model, _, _ in
            let stream = AssistantMessageEventStream()
            let message = AssistantMessage(content: [.text(TextContent(text: "done"))], api: model.api,
                provider: model.provider, model: model.id,
                usage: Usage(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0), stopReason: .stop)
            Task {
                stream.push(.start(partial: message))
                stream.push(.done(reason: .stop, message: message))
            }
            return stream
        }, getApiKey: { _ in "test" }
    ))
    let bus = createEventBus()
    let recorded = LockedState<[String]>([])
    let hook = try #require(ExtensionLoader.load(InlineExtension(name: "input") { api in
        api.registerCommand("noop") { _, _ in }
        api.on("input") { (event: InputEvent, _: HookContext) in
            event.text == "intercept" ? InputEventResult.handled : InputEventResult.continue
        }
    }, cwd: "/tmp", eventBus: bus).hook)
    let sessionManager = SessionManager.inMemory()
    let settingsManager = SettingsManager.inMemory()
    let runner = HookRunner([hook], "/tmp", sessionManager, registry, settingsManager: settingsManager)
    let session = AgentSession(config: AgentSessionConfig(agent: agent, sessionManager: sessionManager,
        settingsManager: settingsManager, resourceLoader: TestResourceLoader(), hookRunner: runner,
        modelRegistry: registry))
    defer { session.dispose() }
    let options = PromptOptions(preflightResult: { disposition in recorded.withLock { $0.append(disposition.rawValue) } })
    try await session.prompt("/noop", options: options)
    try await session.prompt("intercept", options: options)
    try await session.prompt("start", options: options)
    #expect(recorded.withLock { $0 } == ["handled", "handled", "started"])
    #expect(await session.steer("intercept", source: .rpc) == .handled)
    #expect(await session.followUp("later", source: .rpc) == .queued)
}

@Test func c1ProviderStreamEventReachesExtension() async throws {
    let model = try #require(getModel(provider: .anthropic, modelId: "claude-sonnet-4-5"))
    let auth = AuthStorage.inMemory([model.provider: .apiKey(ApiKeyCredential(key: "test"))])
    let captured = LockedState<ProviderStreamEvent?>(nil)
    let result = await createAgentSession(CreateAgentSessionOptions(
        authStorage: auth, modelRegistry: ModelRegistry(auth), model: model,
        projectTrusted: false, noTools: .all, resourceLoader: TestResourceLoader(),
        hooks: [HookDefinition(path: "<c1:stream>") { api in
            api.on("provider_stream_event") { (event: ProviderStreamEvent, _: HookContext) in
                captured.withLock { $0 = event }
                return nil
            }
        }], sessionManager: SessionManager.inMemory(), settingsManager: SettingsManager.inMemory()
    ))
    defer { result.session.dispose() }
    try await result.session.agent.onProviderStreamEvent?(AnyCodable(["kind": "chunk"]), model)
    let event = try #require(captured.withLock { $0 })
    #expect(event.provider == model.provider && event.api == model.api && event.model == model.id)
    #expect((event.data.jsonValue as? [String: String])?["kind"] == "chunk")
}

@Test func c1RejectedPromptDoesNotReportDisposition() async throws {
    let model = try #require(getModel(provider: .anthropic, modelId: "claude-sonnet-4-5"))
    let auth = AuthStorage.inMemory([model.provider: .apiKey(ApiKeyCredential(key: "test"))])
    let recorded = LockedState<[String]>([])
    let agent = Agent(AgentOptions(initialState: AgentState(systemPrompt: "Test", model: model, tools: []),
        streamFn: { model, _, options in
            let stream = AssistantMessageEventStream()
            let message = AssistantMessage(content: [], api: model.api, provider: model.provider,
                model: model.id, usage: Usage(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0),
                stopReason: .aborted)
            Task {
                stream.push(.start(partial: message))
                while options.signal?.isCancelled != true { try? await Task.sleep(for: .milliseconds(5)) }
                stream.push(.error(reason: .aborted, error: message))
            }
            return stream
        }, getApiKey: { _ in "test" }))
    let session = AgentSession(config: AgentSessionConfig(agent: agent,
        sessionManager: SessionManager.inMemory(), settingsManager: SettingsManager.inMemory(),
        resourceLoader: TestResourceLoader(), modelRegistry: ModelRegistry(auth)))
    defer { session.dispose() }
    let first = try await session.submitPrompt("first")
    for _ in 0..<100 where !session.isStreaming { try? await Task.sleep(for: .milliseconds(5)) }
    #expect(session.isStreaming)
    do {
        _ = try await session.submitPrompt("reject", options: PromptOptions(preflightResult: { value in
            recorded.withLock { $0.append(value.rawValue) }
        }))
        Issue.record("Expected streaming prompt rejection")
    } catch {
        #expect(error.localizedDescription.contains("already processing"))
    }
    #expect(recorded.withLock { $0 }.isEmpty)
    _ = try await session.submitPrompt("queue", options: PromptOptions(streamingBehavior: .followUp,
        preflightResult: { value in recorded.withLock { $0.append(value.rawValue) } }))
    #expect(recorded.withLock { $0 } == ["queued"])
    await session.abort()
    _ = try? await first.value
}

#if canImport(AppKit)
@Test func c1ClipboardReadsFinderFileURLs() throws {
    let pasteboard = NSPasteboard.withUniqueName()
    defer { pasteboard.releaseGlobally() }
    let file = URL(fileURLWithPath: "/tmp/a file.txt")
    pasteboard.clearContents()
    #expect(pasteboard.writeObjects([file as NSURL]))
    #expect(readClipboardFilePaths(from: pasteboard) == [file.path])
    pasteboard.clearContents()
    #expect(readClipboardFilePaths(from: pasteboard) == nil)
}
#endif
