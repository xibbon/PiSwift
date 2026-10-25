import Foundation
import PiSwiftAI
import PiSwiftChord
import PiSwiftCodingAgent
@testable import PiSwiftCodingAgentDurable
import PiSwiftDurable
import PiSwiftDurableJSC
import PiSwiftDurableTesting
import Synchronization
import Testing

private struct H1HostPaths: Sendable {
    let directory: URL
    let cwd: URL
    let agent: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("h1-host-\(UUID())")
        cwd = directory.appendingPathComponent("project")
        agent = directory.appendingPathComponent("agent")
        try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: agent, withIntermediateDirectories: true)
        try Data("""
        {"defaultProvider":"faux","defaultModel":"faux-1",
         "retry":{"enabled":false},"compaction":{"enabled":false}}
        """.utf8).write(to: agent.appendingPathComponent("settings.json"))
    }

    func remove() { try? FileManager.default.removeItem(at: directory) }

    func open(_ models: any DurableModels, available: [Model],
              initial: ModelRef = .init(provider: "faux", modelId: "faux-1"),
              continueSession: Bool = false) async throws -> OpenDurableResult {
        try await openDurable(.init(cwd: cwd.path, continueSession: continueSession), dependencies: .init(
            agentDirectory: agent.path, makeModels: { _ in
                DurableRuntimeModels(models: models, available: available, initial: { _ in
                    InitialAgentModel(model: initial)
                })
            }))
    }

    func registry(settings: SettingsManager, sandbox: JSCCodemodeSandbox, internalPath: Bool,
                  report: @escaping @Sendable (any Error) -> Void = { _ in }) throws -> Registry {
        if internalPath {
            return try createCodingRegistry(settingsManager: settings, cwd: cwd.path,
                agentDirectory: agent.path, sandbox: sandbox, onReport: report)
        }
        return try createCodingRegistry(settingsManager: settings, cwd: cwd.path,
            sandbox: sandbox, onReport: report)
    }
}

private func h1HostCall(_ name: String, _ arguments: [String: AnyCodable], id: String = "host-code") -> AssistantMessage {
    var message = chatAssistant("", reason: .toolUse)
    message.content = [.toolCall(.init(id: id, name: name, arguments: arguments))]
    return message
}

private func h1HostLive(_ result: OpenDurableResult) throws -> LiveState {
    try JSONValue.object(result.view.current().conversation.docs["pi.live"] ?? [:]).decode(LiveState.self)
}

private func h1HostWait(_ result: OpenDurableResult, answer: String = "host done") async throws {
    try await eventually(timeout: .seconds(15)) {
        let entries = result.view.current().conversation.entries
        let idle = try h1HostLive(result).run == nil
        return try entries.contains { entry in
            guard entry.kind == "pi.assistant" else { return false }
            return try entry.messages()?.contains { textOf($0) == answer } ?? false
        } && idle
    }
    #expect(result.failure == nil)
}

private func h1HostResult(_ entries: [EntryRecord], name: String = "codemode") throws -> ToolResultMessage {
    for entry in entries where entry.kind == "pi.tool-result" {
        for message in try entry.messages() ?? [] {
            if case .toolResult(let result) = message, result.toolName == name { return result }
        }
    }
    throw TaskDefinitionError("Missing host tool result: \(name)")
}

private func h1HostOutput(_ result: ToolResultMessage) throws -> String {
    #expect(!result.isError)
    let text = result.content.compactMap { block -> String? in
        if case .text(let value) = block { return value.text }
        return nil
    }.joined()
    let marker = try #require(text.range(of: "\nOutput:\n"))
    return String(text[marker.upperBound...])
}

private func h1HostSubmit(_ root: Conversation) async throws {
    let submission = try await root.submit(.input(content: .text("Run the host tools")), context: .background)
    let outcome = settled { try await submission.wait(context: .background) }
    try await eventually(timeout: .seconds(15)) { outcome.isSettled }
    #expect(try #require(outcome.result).get().status == "done")
}

@Suite(.timeLimit(.minutes(1)))
struct H1HostCodemodeTests {
    @Test(arguments: [false, true])
    func emptyDeferredSettingKeepsCodingToolsAndAddsCodemode(internalPath: Bool) async throws {
        let paths = try H1HostPaths()
        defer { paths.remove() }
        let sandbox = JSCCodemodeSandbox()
        do {
            let settings = SettingsManager.inMemory()
            #expect(settings.getDurableDeferredTools().isEmpty)
            let registry = try paths.registry(settings: settings, sandbox: sandbox, internalPath: internalPath)
            let names = registry.snapshot().tools().map { $0.tool.name }
            #expect(Array(names.prefix(4)) == ["read", "write", "edit", "bash"])
            #expect(names.contains("codemode"))
            #expect(!names.contains("tool_search"))
            #expect(names.contains("subagent") == internalPath)
            #expect(registry.snapshot().tools().allSatisfy { $0.tool.deferred != true })
            let agent = resolveAgent(snapshot: registry.snapshot())
            #expect(agent.tools.map(\.name) == ["read", "write", "edit", "bash", "codemode"]
                + (internalPath ? ["subagent"] : []))
            #expect(agent.callable.map(\.name) == ["read", "write", "edit", "bash",
                "pi.codemode.models.classify", "pi.codemode.models.generateImages"]
                + (internalPath ? ["subagent"] : []))
            await sandbox.close()
        } catch {
            await sandbox.close()
            throw error
        }
    }

    #if os(macOS)
    @Test func runtimeSearchLoadsDeferredToolsAndReportsUnknownNamesOnce() async throws {
        let paths = try H1HostPaths()
        defer { paths.remove() }
        let settings = SettingsManager.create(paths.cwd.path, paths.agent.path)
        settings.setDurableDeferredTools(["bash", "subagent", "missing-host-tool", "missing-host-tool"])
        let requests = Mutex<[[String]]>([])
        let models = FakeDurableModels(responses: [
            .factory { transcript, _, _, _ in
                requests.withLock { $0.append(getCurrentTools(transcript.messages).map(\.name)) }
                return h1HostCall("codemode", ["code": AnyCodable(
                    "return (await tools.bash({command: 'printf nested-deferred'})).output;")])
            },
            .factory { transcript, _, _, _ in
                requests.withLock { $0.append(getCurrentTools(transcript.messages).map(\.name)) }
                return h1HostCall("tool_search", ["query": AnyCodable("bash"), "limit": AnyCodable(1)], id: "search")
            },
            .factory { transcript, _, _, _ in
                requests.withLock { $0.append(getCurrentTools(transcript.messages).map(\.name)) }
                return h1HostCall("bash", ["command": AnyCodable("printf loaded-bash")], id: "loaded")
            },
            .message(chatAssistant("host done"))
        ])
        let result = try await paths.open(models, available: models.models)
        do {
            await result.controller.submit("Use and find deferred tools", whenBusy: .followUp)
            try await h1HostWait(result)
            let offered = requests.withLock { $0 }
            #expect(offered.count == 3)
            let first = try #require(offered.first), last = try #require(offered.last)
            #expect(!first.contains("bash") && !first.contains("subagent"))
            #expect(first.contains("tool_search") && first.contains("codemode"))
            #expect(offered[1] == first)
            #expect(last == first + ["bash"])
            #expect(try decodeAgentOf(result.view.current().conversation).modelTools == .edit(add: ["bash"]))
            #expect(try h1HostOutput(h1HostResult(result.view.current().conversation.entries)) == "nested-deferred")
            #expect(result.view.current().notices.map(\.message) == ["Unknown durable deferred tool: missing-host-tool"])
            #expect(result.view.current().notices.first?.level == .warning)
            await result.close()
        } catch {
            await result.close()
            throw error
        }
    }

    @Test(arguments: [false, true])
    func deferredBashLoadsForTheNextModelRequestAndStoresSelection(internalPath: Bool) async throws {
        let paths = try H1HostPaths()
        defer { paths.remove() }
        let sandbox = JSCCodemodeSandbox()
        let envs = ExecutionEnvs(defaultCwd: paths.cwd.path)
        let reports = Mutex<[String]>([])
        let requests = Mutex<[[String]]>([])
        var settings = Settings()
        settings.durableDeferredTools = ["bash", "unknown-host-tool", "bash", "unknown-host-tool"]
        let manager = SettingsManager.inMemory(settings)
        let models = FakeDurableModels(responses: [
            .factory { transcript, _, _, _ in
                requests.withLock { $0.append(getCurrentTools(transcript.messages).map(\.name)) }
                return h1HostCall("tool_search", ["query": AnyCodable("bash"), "limit": AnyCodable(1)], id: "search")
            },
            .factory { transcript, _, _, _ in
                requests.withLock { $0.append(getCurrentTools(transcript.messages).map(\.name)) }
                return h1HostCall("bash", ["command": AnyCodable("printf deferred-shell")], id: "bash")
            },
            .message(chatAssistant("host done"))
        ])
        var opened: Harness?
        do {
            let registry = try paths.registry(settings: manager, sandbox: sandbox, internalPath: internalPath,
                report: { error in reports.withLock { $0.append(String(describing: error)) } })
            #expect(reports.withLock { $0 } == ["Unknown durable deferred tool: unknown-host-tool"])
            let harness = try await Harness.open(storage: MemoryStorage(), options: .init(
                models: models, registry: registry, env: envs.factory), context: .background)
            opened = harness
            let root = try await harness.root(options: .init(agent: .init(
                model: .set(.init(provider: "faux", modelId: "faux-1")),
                extensions: .set(.exact(registry.snapshot().installed())),
                tools: .set(.exact(registry.snapshot().tools().map(\.tool))),
                cwd: .set(paths.cwd.path))), context: .background)
            #expect(try await root.agent(context: .background).deferred.map(\.name) == ["bash"])
            try await h1HostSubmit(root)
            let offered = requests.withLock { $0 }
            #expect(offered.count == 2)
            let first = try #require(offered.first), next = try #require(offered.last)
            #expect(!first.contains("bash") && first.contains("tool_search") && first.contains("codemode"))
            #expect(next == first + ["bash"])
            #expect(!next.contains("unknown-host-tool"))
            #expect(try await harness.snapshot(AgentDoc, conversationId: root.id, context: .background)?.modelTools == .edit(add: ["bash"]))
            let result = try h1HostResult(await allEntries(root), name: "bash")
            #expect(!result.isError && textOf(.toolResult(result))?.contains("deferred-shell") == true)
            #expect(reports.withLock { $0.count } == 1)
            try await harness.close(context: .background)
            await sandbox.close()
            await envs.cleanup(context: .background)
        } catch {
            try? await opened?.close(context: .background)
            await sandbox.close()
            await envs.cleanup(context: .background)
            throw error
        }
    }

    @Test func runtimeRestartReplaysCompletedReadAndBashAndKeepsNestedParents() async throws {
        let source = """
        const read = await tools.read({path: 'input.txt'});
        const shell = await tools.bash({command: 'printf "once\\n" >> finished.txt; printf host-shell'});
        try {
          await tools.bash({command: 'printf pending > pending.txt; if [ ! -f release ]; then sleep 60; fi'});
        } catch (_) {}
        return [read, shell.output];
        """
        // The complete run supplies the expected output for the resumed run.
        let completePaths = try H1HostPaths()
        defer { completePaths.remove() }
        try Data("original input".utf8).write(to: completePaths.cwd.appendingPathComponent("input.txt"))
        try Data().write(to: completePaths.cwd.appendingPathComponent("release"))
        let completeModels = FakeDurableModels(responses: [
            .message(h1HostCall("codemode", ["code": AnyCodable(source)])), .message(chatAssistant("host done"))
        ])
        let complete = try await completePaths.open(completeModels, available: completeModels.models)
        let expected: String
        do {
            await complete.controller.submit("Run the script", whenBusy: .followUp)
            try await h1HostWait(complete)
            expected = try h1HostOutput(h1HostResult(complete.view.current().conversation.entries))
            #expect(expected == "[\"original input\",\"host-shell\"]")
            await complete.close()
        } catch {
            await complete.close()
            throw error
        }

        let paths = try H1HostPaths()
        defer { paths.remove() }
        try Data("original input".utf8).write(to: paths.cwd.appendingPathComponent("input.txt"))
        let models = FakeDurableModels(responses: [
            .message(h1HostCall("codemode", ["code": AnyCodable(source)])), .message(chatAssistant("host done"))
        ])
        let first = try await paths.open(models, available: models.models)
        let sessionID = first.view.current().session.id
        do {
            await first.controller.submit("Run the script", whenBusy: .followUp)
            try await eventually(timeout: .seconds(15)) {
                let nested = try h1HostLive(first).nestedTools ?? []
                return nested.count == 3 && nested[0].status == .done && nested[1].status == .done
                    && nested[2].status == .running
                    && FileManager.default.fileExists(atPath: paths.cwd.appendingPathComponent("pending.txt").path)
            }
            let live = try h1HostLive(first)
            let parent = try #require(live.tools?.first { $0.name == "codemode" })
            let nested = try #require(live.nestedTools)
            #expect(nested.map(\.name) == ["read", "bash", "bash"])
            #expect(nested.allSatisfy { $0.parentCallId == parent.callId && $0.parentTaskId == parent.taskId })
            #expect(Set(nested.map(\.taskId)).count == 3)
            #expect(nested[0].summary?.isError == false && nested[1].summary?.isError == false)
            let closing = settled { await first.close() }
            try await eventually(timeout: .seconds(10)) { closing.isSettled }
            await first.close()
        } catch {
            await first.close()
            throw error
        }
        // A repeated read would return different data. A repeated bash would append a second line.
        try Data("changed after close".utf8).write(to: paths.cwd.appendingPathComponent("input.txt"))
        try Data().write(to: paths.cwd.appendingPathComponent("release"))
        let reopened = try await paths.open(models, available: models.models, continueSession: true)
        do {
            #expect(reopened.view.current().session.id == sessionID)
            try await h1HostWait(reopened)
            let entries = reopened.view.current().conversation.entries
            #expect(try h1HostOutput(h1HostResult(entries)) == expected)
            #expect(try String(contentsOf: paths.cwd.appendingPathComponent("finished.txt"), encoding: .utf8) == "once\n")
            #expect(entries.filter { $0.kind == "pi.user" }.count == 1)
            #expect(entries.filter { $0.kind == "pi.tool-result" }.count == 1)
            #expect(reopened.view.current().notices.isEmpty)
            #expect(models.state().callCount == 2)
            await reopened.close()
        } catch {
            await reopened.close()
            throw error
        }
    }
    #endif

    @Test func runtimeCatalogAndClassifierUseTheHostRegistryAndCredentials() async throws {
        let paths = try H1HostPaths()
        defer { paths.remove() }
        let provider = "h1-host-provider"
        let auth = AuthStorage.inMemory()
        auth.set(provider, credential: .apiKey(ApiKeyCredential(key: "host-classifier-key")))
        let registry = ModelRegistry(auth, paths.agent.path, modelsStore: InMemoryModelsStore(), networkEnabled: false)
        let chats = Mutex(0)
        let classified = Mutex<[ClassifierOptions]>([])
        let code = """
        const all = await models.getModelsOfType('classifier', 'h1-host-provider');
        const model = await models.getModelOfType('classifier', 'h1-host-provider', 'judge');
        const available = await models.getAvailableOfType('classifier', 'h1-host-provider');
        const result = await models.classify(model, {
          state: {input: 'host input'},
          questions: {ok: {type: 'bool', instructions: 'Check the input', criteria: {true: 'Accept', false: 'Reject'}}}
        });
        return [all.map(m => m.id), available.map(m => m.id), 'headers' in model,
          result.stopReason, result.answers.ok.probability];
        """
        registry.registerProvider(HookProviderConfig(
            provider: provider, api: .openAICompletions, baseUrl: "https://h1-host.invalid", authHeader: true,
            streamSimple: { model, _, options in
                #expect(options?.apiKey == "host-classifier-key")
                let index = chats.withLock { count in count += 1; return count }
                var message = index == 1
                    ? h1HostCall("codemode", ["code": AnyCodable(code)]) : chatAssistant("host done")
                message.provider = model.provider
                message.model = model.id
                let stream = AssistantMessageEventStream()
                stream.end(message)
                return stream
            }, classifiers: [.typesafeSystemOne: { model, context, options in
                classified.withLock { $0.append(options ?? .init()) }
                #expect(context.state["input"]?.value as? String == "host input")
                return ClassifierResult(api: model.api, provider: model.provider, model: model.id,
                    answers: ["ok": .bool(probability: 0.8)],
                    usage: Usage(input: 3, output: 2, cacheRead: 0, cacheWrite: 0, totalTokens: 5),
                    stopReason: .stop)
            }], models: [
                .chat(HookProviderModel(id: "conversation")),
                .classifier(HookProviderClassifierModel(id: "judge", api: .typesafeSystemOne,
                    contextWindow: 512, headers: ["X-Classifier": "host"]))
            ]), sourceId: "h1-host-test")
        let models = await RegistryCodemodeModels.create(registry: registry)
        let result = try await paths.open(models, available: models.getAvailableSnapshot(),
            initial: .init(provider: provider, modelId: "conversation"))
        do {
            await result.controller.submit("Classify the input", whenBusy: .followUp)
            try await h1HostWait(result)
            let message = try h1HostResult(result.view.current().conversation.entries)
            #expect(try h1HostOutput(message) == "[[\"judge\"],[\"judge\"],false,\"stop\",0.8]")
            #expect(chats.withLock { $0 } == 2)
            let options = try #require(classified.withLock { $0.first })
            #expect(classified.withLock { $0.count } == 1)
            #expect(options.apiKey == "host-classifier-key")
            #expect(providerHeaderValue(options.headers, name: "X-Classifier") == "host")
            #expect(options.signal != nil)
            #expect(result.view.current().notices.isEmpty)
            await result.close()
        } catch {
            await result.close()
            throw error
        }
    }
}
