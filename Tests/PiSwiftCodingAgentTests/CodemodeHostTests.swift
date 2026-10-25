import Foundation
import Testing
import PiSwiftAI
import PiSwiftAgent
@testable import PiSwiftCodingAgent
@testable import PiSwiftCodemodeRuntime

private func hostContext(_ tool: AgentTool,
                         execute: @escaping NestedToolExecute) -> CustomToolContext {
    var context = CustomToolContext(sessionManager: .inMemory(),
        modelRegistry: ModelRegistry(AuthStorage(":memory:")), model: nil,
        isIdle: { true }, hasPendingMessages: { false }, abort: {},
        events: createEventBus(), sendMessage: { _, _ in })
    context.setNestedToolHost(tools: [tool], execute: execute)
    return context
}

private func hostText(_ result: AgentToolResult) -> String {
    result.content.compactMap { block in
        if case .text(let text) = block {
            return text.text
        }
        return nil
    }.joined(separator: "\n")
}

private func hostWaitUntil(_ predicate: @escaping @Sendable () -> Bool) async throws {
    for _ in 0..<100 {
        if predicate() {
            return
        }
        try await Task.sleep(for: .milliseconds(50))
    }
}

private actor HostNativeRelease {
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if released {
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        guard !released else {
            return
        }
        released = true
        for waiter in waiters {
            waiter.resume()
        }
        waiters.removeAll()
    }
}

private final class HostPendingModels: CodemodeModelRuntime, Sendable {
    let release = HostNativeRelease()
    private let counts = LockedState((started: 0, completed: 0))
    let onStart: @Sendable () -> Void
    let classifier = ClassifierModel(id: "judge", name: "Judge", api: .typesafeSystemOne,
        provider: "host-test", baseUrl: "https://classifier.test", input: [.text],
        cost: ModelCost(input: 0, output: 0, cacheRead: 0, cacheWrite: 0), contextWindow: 1000)
    let image = ImageModel(id: "painter", name: "Painter", api: .openrouterImages,
        provider: "host-test", baseUrl: "https://image.test", input: [.text], output: [.image],
        cost: ModelCost(input: 0, output: 0, cacheRead: 0, cacheWrite: 0))

    init(onStart: @escaping @Sendable () -> Void = {}) { self.onStart = onStart }
    var started: Int { counts.withLock { $0.started } }
    var completed: Int { counts.withLock { $0.completed } }

    func getModelsOfType(_ type: ModelType, provider: String?) -> [AnyModel] {
        guard provider == nil || provider == "host-test" else { return [] }
        switch type {
        case .classifier: return [.classifier(classifier)]
        case .image: return [.image(image)]
        case .chat: return []
        }
    }

    func getAvailableOfType(_ type: ModelType, provider: String?) async -> [AnyModel] {
        getModelsOfType(type, provider: provider)
    }

    func getModelOfType(_ type: ModelType, provider: String, modelId: String) -> AnyModel? {
        getModelsOfType(type, provider: provider).first { $0.catalog.id == modelId }
    }

    private func waitForResult() async {
        counts.withLock { $0.started += 1 }
        onStart()
        // This provider continues after cancellation. The host must keep its outcome unknown.
        await release.wait()
        counts.withLock { $0.completed += 1 }
    }

    func classify(_ model: ClassifierModel, context: ClassifierContext,
                  options: ClassifierOptions?) async -> ClassifierResult {
        await waitForResult()
        return ClassifierResult(api: model.api, provider: model.provider, model: model.id,
                                usage: Usage(input: 1, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 1))
    }

    func generateImages(_ model: ImageModel, context: ImagesContext,
                        options: ImagesOptions?) async -> AssistantImages {
        await waitForResult()
        return AssistantImages(api: model.api, provider: model.provider, model: model.id,
                               usage: Usage(input: 1, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 1),
                               stopReason: .stop)
    }
}

private func hostModelCall(_ type: ModelType) -> String {
    if type == .image {
        return #"models.generateImages({provider:'host-test',id:'painter'}, {input:[{type:'text',text:'Draw'}]})"#
    }
    return #"models.classify({provider:'host-test',id:'judge'}, {state:{},questions:{ok:{type:'bool',instructions:'Check',criteria:{true:'yes',false:'no'}}}})"#
}

@Test(.timeLimit(.minutes(1)), arguments: [ModelType.classifier, .image], [false, true])
func codemodeHostPendingModelOutcomeIsUnknown(type: ModelType, abort: Bool) async throws {
    let signal = CancellationToken()
    let models = HostPendingModels(onStart: { if abort { signal.cancel() } })
    defer { Task { await models.release.release() } }
    let lateCalls = LockedState<[CodemodeNestedCall]>([])
    let result = try await executeCodemode(toolCallId: "pending-model",
        params: ["code": AnyCodable("await \(hostModelCall(type))")], signal: signal,
        options: CodemodeToolOptions(models: true, modelRuntime: models, defaultTimeoutMs: 3_000,
            recordLateCall: { _, call in lateCalls.withLock { $0.append(call) } }), forceWatchdog: true)
    #expect(result.isError == true)
    #expect(models.started == 1)
    #expect(models.completed == 0)
    let rows = try #require((result.details?.value as? [String: Any])?["calls"] as? [[String: Any]])
    #expect(rows.count == 1)
    #expect(rows.first?["status"] as? String == "outcome_unknown")
    #expect(hostText(result).contains("outcome unknown"))
    await models.release.release()
    try await hostWaitUntil { lateCalls.withLock { $0.contains { $0.status == .ok } } }
    let completed = try #require(lateCalls.withLock { $0.first { $0.status == .ok } })
    #expect(completed.name == (type == .image ? "models.generateImages" : "models.classify"))
    #expect(completed.error == nil)
    #expect(models.completed == 1)
}

@Test(.timeLimit(.minutes(1)), arguments: [ModelType.classifier, .image])
func codemodeHostQueuedModelsStayCancelled(type: ModelType) async throws {
    let signal = CancellationToken()
    let models = HostPendingModels()
    defer { Task { await models.release.release() } }
    let rowCount = LockedState(0)
    let lateCalls = LockedState<[CodemodeNestedCall]>([])
    let task = Task {
        try await executeCodemode(toolCallId: "queued-models",
            params: ["code": AnyCodable("await Promise.all(Array.from({length:5}, () => \(hostModelCall(type))))")],
            signal: signal, onUpdate: { update in
                let rows = (update.details?.value as? [String: Any])?["calls"] as? [[String: Any]] ?? []
                rowCount.withLock { $0 = rows.count }
            }, options: CodemodeToolOptions(models: true, modelRuntime: models, defaultTimeoutMs: 10_000,
                recordLateCall: { _, call in lateCalls.withLock { $0.append(call) } }), forceWatchdog: true)
    }
    try await hostWaitUntil { models.started == 4 && rowCount.withLock { $0 } == 5 }
    signal.cancel()
    let result = try await task.value
    let rows = try #require((result.details?.value as? [String: Any])?["calls"] as? [[String: Any]])
    #expect(models.started == 4)
    #expect(rows.filter { $0["status"] as? String == "outcome_unknown" }.count == 4)
    #expect(rows.filter { $0["status"] as? String == "cancelled" }.count == 1)
    await models.release.release()
    try await hostWaitUntil { lateCalls.withLock { $0.filter { $0.status == .ok }.count } == 4 }
    #expect(models.started == 4)
    #expect(models.completed == 4)
}

@Test(.timeLimit(.minutes(1))) func codemodeHostTimeoutOptions() async throws {
    #expect(CodemodeToolOptions().defaultTimeoutMs == nil)
    #expect(CodemodeToolOptions().maxTimeoutMs == nil)
    #expect(CodemodeExtensionOptions().defaultTimeoutMs == nil)
    let options = CodemodeToolOptions(defaultTimeoutMs: 50, maxTimeoutMs: 2_000,
                                      validationErrorPrefix: "validation: ")
    let timed = try await executeCodemode(toolCallId: "timeout", params: ["code": AnyCodable("while (true) {}")],
                                          options: options, forceWatchdog: true)
    #expect(timed.isError == true)
    #expect(hostText(timed).contains("50 ms"))
    let allowed = try await executeCodemode(toolCallId: "maximum",
        params: ["code": AnyCodable("// @options: {\"timeout_ms\":2000}\nreturn 1")], options: options)
    #expect(allowed.isError != true)
    for code in ["// @options: {\"timeout_ms\":2001}\nreturn 1", "// @options: {\"timeout_ms\":0}\nreturn 1"] {
        do {
            _ = try await executeCodemode(toolCallId: "invalid", params: ["code": AnyCodable(code)], options: options)
            Issue.record("Invalid timeout was accepted")
        } catch {
            #expect(error.localizedDescription.hasPrefix("validation: "))
        }
    }
}

@Test func codemodeHostTimeoutSettingsPersistAndMerge() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer {
        try? FileManager.default.removeItem(at: directory)
    }
    let manager = SettingsManager.create(directory.path, directory.path)
    #expect(manager.getCodemodeDefaultTimeoutMs() == nil)
    #expect(manager.getCodemodeMaxTimeoutMs() == nil)
    manager.setCodemodeDefaultTimeoutMs(60_000)
    manager.setCodemodeMaxTimeoutMs(600_000)
    let reloaded = SettingsManager.create(directory.path, directory.path)
    #expect(reloaded.getCodemodeDefaultTimeoutMs() == 60_000)
    #expect(reloaded.getCodemodeMaxTimeoutMs() == 600_000)
    var overrides = Settings()
    overrides.codemode = CodemodeSettings(defaultTimeoutMs: 30_000)
    reloaded.applyOverrides(overrides)
    #expect(reloaded.getCodemodeDefaultTimeoutMs() == 30_000)
    #expect(reloaded.getCodemodeMaxTimeoutMs() == 600_000)
    reloaded.setCodemodeDefaultTimeoutMs(0)
    #expect(reloaded.getCodemodeDefaultTimeoutMs() == 30_000)
    try Data(#"{"codemode":{"defaultTimeoutMs":true,"maxTimeoutMs":1.5}}"#.utf8)
        .write(to: directory.appendingPathComponent("settings.json"))
    let invalid = SettingsManager.create(directory.path, directory.path)
    #expect(invalid.getCodemodeDefaultTimeoutMs() == nil)
    #expect(invalid.getCodemodeMaxTimeoutMs() == nil)
}

@Test(.timeLimit(.minutes(1))) func codemodeHostRejectsCallsAfterResultAndBoundsRecords() async throws {
    let dispatches = LockedState(0)
    let result = await CodemodeSandbox.execute(code: "", tools: [], timeoutMs: 2_000,
        preludeSource: #"""
        (function(bridge) {
            return { run() {
                bridge("done", "true", "null", "[]");
                for (let i = 0; i < 300; i++) {
                    try {
                        bridge("call", String(i), "late", "x".repeat(1000));
                    } catch {}
                }
            }, settle() {}, stalled() {} };
        })
        """#,
        onCall: { _ in
            dispatches.withLock { $0 += 1 }
            return CodemodeRuntimeReply(ok: true)
        })
    #expect(result.execution.failure == nil)
    #expect(dispatches.withLock { $0 } == 0)
    #expect(result.rejectedCalls.count == 128)
    #expect(result.rejectedCalls.allSatisfy { ($0.argsJSON?.count ?? 0) <= 200 })
    #expect(result.rejectedCalls.allSatisfy { $0.signal.isCancelled })
}

@Test(.timeLimit(.minutes(1)), arguments: [false, true])
func codemodeHostDisablesLateCallsAfterTimeoutOrAbort(abort: Bool) async throws {
    let dispatches = LockedState(0)
    let signal = CancellationToken()
    let task = Task {
        await CodemodeSandbox.execute(code: "", tools: [], timeoutMs: abort ? 2_000 : 100,
            signal: signal, forceWatchdog: true,
            preludeSource: #"""
            (function(bridge) {
                return { run() {
                    bridge("output", "text", "started");
                    const end = Date.now() + 400;
                    while (Date.now() < end) {}
                    bridge("call", "1", "late", "{}");
                }, settle() {}, stalled() {} };
            })
            """#,
            onCall: { _ in
                dispatches.withLock { $0 += 1 }
                return CodemodeRuntimeReply(ok: true)
            })
    }
    if abort {
        try await Task.sleep(for: .milliseconds(100))
        signal.cancel()
    }
    let result = await task.value
    #expect(result.execution.failure?.kind == (abort ? .aborted : .timeout))
    try await hostWaitUntil { !result.rejectedCalls.isEmpty }
    #expect(dispatches.withLock { $0 } == 0)
    #expect(result.rejectedCalls.count == 1)
}

@Test(.timeLimit(.minutes(1))) func codemodeHostUnknownOutcomeRejectsStructuredSuccess() async throws {
    let tool = AgentTool(label: "change", name: "change", description: "Change", parameters: [:],
        execute: { _, _, _, _ in AgentToolResult(content: []) }, outputSchema: ["type": AnyCodable("object")])
    let context = hostContext(tool) { name, args, _ in
        AgentToolCallOutcome(toolCall: AgentToolCall(id: "operation-1", name: name, arguments: args),
            result: AgentToolResult(content: [.text(TextContent(text: "outcome_unknown: operation-1 may still be running"))],
                details: AnyCodable(["outcome": "unknown"]), structuredContent: AnyCodable(["ok": true])),
            isError: false)
    }
    let result = try await executeCodemode(toolCallId: "unknown",
        params: ["code": AnyCodable("await tools.change({})")], context: context)
    #expect(result.isError == true)
    #expect(hostText(result).contains("outcome_unknown: operation-1 may still be running"))
    #expect(hostText(result).contains("outcome unknown — inspect before retrying"))
    let rows = (result.details?.value as? [String: Any])?["calls"] as? [[String: Any]]
    #expect(rows?.first?["status"] as? String == "outcome_unknown")
    #expect(rows?.first?["id"] as? String == "operation-1")
}

@Test(.timeLimit(.minutes(1))) func codemodeHostPrefixesNestedSchemaValidationBeforeDispatch() async throws {
    let dispatches = LockedState(0)
    let tool = AgentTool(label: "read", name: "read", description: "Read",
        parameters: ["type": AnyCodable("object"),
                     "properties": AnyCodable(["path": ["type": "string"]]),
                     "required": AnyCodable(["path"])]) { _, _, _, _ in
        AgentToolResult(content: [])
    }
    let context = hostContext(tool) { name, args, _ in
        dispatches.withLock { $0 += 1 }
        return AgentToolCallOutcome(toolCall: AgentToolCall(id: "read-1", name: name, arguments: args),
                                   result: AgentToolResult(content: []), isError: false)
    }
    let result = try await executeCodemode(toolCallId: "validation",
        params: ["code": AnyCodable("try { await tools.read({}) } catch (e) { text(e.message) }")],
        context: context, options: CodemodeToolOptions(validationErrorPrefix: "validation: "))
    #expect(result.isError != true)
    #expect(hostText(result).contains("validation: "))
    #expect(dispatches.withLock { $0 } == 0)
}

@Test(.timeLimit(.minutes(1))) func codemodeHostPublishesLateRejectedCallAfterAbort() async throws {
    let signal = CancellationToken()
    let dispatches = LockedState(0)
    let statuses = LockedState<[String]>([])
    let caught = LockedState(false)
    let tool = AgentTool(label: "ready", name: "ready", description: "Ready", parameters: [:]) {
        _, _, _, _ in AgentToolResult(content: [])
    }
    let context = hostContext(tool) { name, args, _ in
        dispatches.withLock { $0 += 1 }
        Task {
            try? await Task.sleep(for: .milliseconds(50))
            signal.cancel()
        }
        return AgentToolCallOutcome(toolCall: AgentToolCall(id: "ready-1", name: name, arguments: args),
                                   result: AgentToolResult(content: []), isError: false)
    }
    let result = try await executeCodemode(toolCallId: "late-abort",
        params: ["code": AnyCodable("await tools.ready({}); const end = Date.now() + 400; while (Date.now() < end) {} try { await tools.ready({}) } catch (e) { await tools.ready({caught: e.message}) }")],
        signal: signal, onUpdate: { result in
            let rows = (result.details?.value as? [String: Any])?["calls"] as? [[String: Any]] ?? []
            statuses.withLock { $0 = rows.compactMap { $0["status"] as? String } }
            if rows.contains(where: { ($0["args"] as? String)?.contains("caught") == true }) {
                caught.withLock { $0 = true }
            }
        }, context: context, forceWatchdog: true)
    #expect(result.isError == true)
    try await hostWaitUntil { caught.withLock { $0 } }
    #expect(dispatches.withLock { $0 } == 1)
    #expect(statuses.withLock { $0 }.contains("rejected_after_end"))
    #expect(caught.withLock { $0 })
}

@Test(.timeLimit(.minutes(1))) func codemodeHostNamespaceIncludesCatalogVersion() async throws {
    let tool = AgentTool(label: "scene", name: "xo_scene", description: "Read scene", parameters: [:]) {
        _, _, _, _ in AgentToolResult(content: [])
    }
    let context = hostContext(tool) { name, args, _ in
        AgentToolCallOutcome(toolCall: AgentToolCall(id: "scene-1", name: name, arguments: args),
                            result: AgentToolResult(content: []), isError: false)
    }
    let result = try await executeCodemode(toolCallId: "namespace-version",
        params: ["code": AnyCodable("text(await describeNamespace('xo.scene'))")], context: context,
        options: CodemodeToolOptions(getToolNamespace: { _ in
            ToolNamespace(name: "xo.scene", version: "catalog-2")
        }))
    #expect(hostText(result).contains("\"version\":\"catalog-2\""))
}

@Test func codemodeHostUnknownNestedRecordRoundTrips() async throws {
    let host = NestedToolCallHost(getTools: { [] }, isSequential: { false },
        runToolCall: { call, _, _, _ in
            AgentToolCallOutcome(toolCall: call,
                result: AgentToolResult(content: [.text(TextContent(text: "outcome_unknown: inspect operation-1"))],
                                        details: AnyCodable(["outcome": "unknown"])), isError: false)
        }, emit: { _ in })
    let runner = NestedToolCallRunner(host: host)
    _ = await runner.execute(callerId: "outer", name: "change", args: [:])
    let summary = try #require(await runner.takeRecord(toolCallId: "outer"))
    let calls = try #require(summary.calls)
    #expect(calls.calls.first?.status == .outcomeUnknown)
    #expect(calls.calls.first?.error == "outcome_unknown: inspect operation-1")
    let data = try JSONEncoder().encode(calls)
    #expect(String(decoding: data, as: UTF8.self).contains("outcome_unknown"))
    let decoded = try JSONDecoder().decode(NestedToolCalls.self, from: data)
    #expect(decoded.calls.first?.status == .outcomeUnknown)
    let wire = try #require(nestedToolCallsFromJSONObject(nestedToolCallsToJSONObject(calls)))
    #expect(wire.calls.first?.status == .outcomeUnknown)
}

@Test(.timeLimit(.minutes(1)), arguments: [false, true])
func codemodeHostAbandonedNativeCallRemainsUnknownAndPublishesLateOutcome(abort: Bool) async throws {
    let signal = CancellationToken()
    let release = HostNativeRelease()
    defer {
        Task {
            await release.release()
        }
    }
    let dispatches = LockedState(0)
    let latest = LockedState<[[String: AnyCodable]]>([])
    let tool = AgentTool(label: "change", name: "change", description: "Change", parameters: [:]) {
        _, _, _, _ in AgentToolResult(content: [])
    }
    let context = hostContext(tool) { name, args, _ in
        dispatches.withLock { $0 += 1 }
        if abort {
            signal.cancel()
        }
        await release.wait()
        return AgentToolCallOutcome(toolCall: AgentToolCall(id: "late-native-1", name: name, arguments: args),
            result: AgentToolResult(content: [.text(TextContent(text: "outcome_unknown: inspect late-native-1"))],
                                    details: AnyCodable(["outcome": "unknown"])), isError: true)
    }
    let result = try await executeCodemode(toolCallId: "abandoned",
        params: ["code": AnyCodable("await tools.change({})")], signal: signal,
        onUpdate: { result in
            let rows = (result.details?.value as? [String: Any])?["calls"] as? [[String: Any]] ?? []
            latest.withLock { $0 = rows.map { $0.mapValues(AnyCodable.init) } }
        }, context: context, options: CodemodeToolOptions(defaultTimeoutMs: 3_000),
        forceWatchdog: true)
    await release.release()
    #expect(result.isError == true)
    #expect(dispatches.withLock { $0 } == 1)
    let rows = (result.details?.value as? [String: Any])?["calls"] as? [[String: Any]]
    #expect(rows?.first?["status"] as? String == "outcome_unknown")
    #expect(hostText(result).contains("outcome unknown — inspect before retrying: change"))
    try await hostWaitUntil { latest.withLock { $0.first?["id"]?.value as? String } == "late-native-1" }
    #expect(latest.withLock { $0.first?["status"]?.value as? String } == "outcome_unknown")
    #expect(latest.withLock { $0.first?["id"]?.value as? String } == "late-native-1")
    #expect(latest.withLock { $0.first?["error"]?.value as? String } == "outcome_unknown: inspect late-native-1")
}

@Test(.timeLimit(.minutes(1))) func codemodeHostExtensionPersistsLateNativeOutcomeAfterAbort() async throws {
    let model = getModel(provider: .openai, modelId: "gpt-4o-mini")
    let auth = AuthStorage(":memory:")
    auth.setRuntimeApiKey(model.provider, "test")
    let manager = SessionManager.inMemory()
    let agent = LockedState<Agent?>(nil)
    let native = InlineExtension(name: "late-native") { api in
        _ = api.registerTool(CustomTool(name: "change", label: "change", description: "Change",
            parameters: [:], execute: { _, _, _, _, _ in
                Task {
                    try? await Task.sleep(for: .milliseconds(50))
                    agent.withLock { $0 }?.abort()
                }
                try? await Task.sleep(for: .milliseconds(500))
                return AgentToolResult(content: [.text(TextContent(text: "outcome_unknown: inspect native-1"))],
                                       details: AnyCodable(["outcome": "unknown"]), isError: true)
            }, exposure: .codemode))
    }
    let created = try await createAgentSession(CreateAgentSessionOptions(authStorage: auth,
        model: model, offline: true, toolNames: ["codemode", "change"], resourceLoader: TestResourceLoader(),
        inlineExtensions: [createCodemodeExtension(), native], sessionManager: manager,
        settingsManager: .inMemory()))
    agent.withLock { $0 = created.session.agent }
    defer {
        agent.withLock { $0 = nil }
        created.session.dispose()
    }
    let responses = LockedState(0)
    created.session.agent.streamFn = { model, _, _ in
        let turn = responses.withLock { count in
            count += 1
            return count
        }
        let stream = AssistantMessageEventStream()
        let content: [ContentBlock] = turn == 1
            ? [.toolCall(ToolCall(id: "outer-late", name: "codemode",
                                 arguments: ["code": AnyCodable("await tools.change({})")]))]
            : [.text(TextContent(text: "done"))]
        let reason: StopReason = turn == 1 ? .toolUse : .stop
        let message = AssistantMessage(content: content,
            api: model.api, provider: model.provider, model: model.id,
            usage: Usage(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0), stopReason: reason)
        stream.push(.done(reason: reason, message: message))
        stream.end(message)
        return stream
    }
    try await created.session.prompt("change")
    try await hostWaitUntil {
        manager.getBranch().contains { entry in
            if case .custom(let value) = entry {
                return value.customType == CODEMODE_LATE_CALL_ENTRY_TYPE
            }
            return false
        }
    }
    let late = manager.getBranch().compactMap { entry -> CustomEntry? in
        if case .custom(let value) = entry, value.customType == CODEMODE_LATE_CALL_ENTRY_TYPE {
            return value
        }
        return nil
    }
    let entry = try #require(late.first)
    let data = try #require(entry.data?.value as? [String: Any])
    #expect(data["parentToolCallId"] as? String == "outer-late")
    let row = try #require(data["call"] as? [String: Any])
    #expect(row["name"] as? String == "change")
    #expect(row["status"] as? String == "outcome_unknown")
    #expect(row["error"] as? String == "outcome_unknown: inspect native-1")
    #expect(late.count <= 128)
}

/// A script that only a timeout can end, even when a timer fires late under load.
private let hostWaitingScript = "await tools.wait({})"

private func hostWaitingContext() -> CustomToolContext {
    let tool = AgentTool(label: "wait", name: "wait", description: "Wait", parameters: [:]) {
        _, _, _, _ in AgentToolResult(content: [])
    }
    return hostContext(tool) { name, args, options in
        while options.signal?.isCancelled != true {
            try? await Task.sleep(for: .milliseconds(20))
        }
        return AgentToolCallOutcome(toolCall: AgentToolCall(id: "wait-1", name: name, arguments: args),
                                   result: AgentToolResult(content: []), isError: true)
    }
}

@Test(.timeLimit(.minutes(1))) func codemodeHostMaximumLimitsScriptsWithoutTimeout() async throws {
    let timed = try await executeCodemode(toolCallId: "maximum-only", params: ["code": AnyCodable(hostWaitingScript)],
                                          context: hostWaitingContext(), options: CodemodeToolOptions(maxTimeoutMs: 100))
    #expect(timed.isError == true)
    #expect(hostText(timed).contains("100 ms"))
}

@Test(.timeLimit(.minutes(1))) func codemodeHostMaximumReducesLargerDefault() async throws {
    let options = CodemodeToolOptions(defaultTimeoutMs: 600_000, maxTimeoutMs: 1_000)
    let allowed = try await executeCodemode(toolCallId: "reduced", params: ["code": AnyCodable("return 1")], options: options)
    #expect(allowed.isError != true)
    let timed = try await executeCodemode(toolCallId: "reduced-wait", params: ["code": AnyCodable(hostWaitingScript)],
                                          context: hostWaitingContext(), options: options)
    #expect(timed.isError == true)
    #expect(hostText(timed).contains("1000 ms"))
}

@Test(.timeLimit(.minutes(1))) func codemodeHostCancelledBeforeDispatchIsNotUnknown() async throws {
    let signal = CancellationToken()
    let dispatches = LockedState(0)
    let tool = AgentTool(label: "change", name: "change", description: "Change", parameters: [:],
        execute: { _, _, _, _ in AgentToolResult(content: []) },
        prepareArguments: { _ in
            // The script ends while the call is still before dispatch.
            signal.cancel()
            try? await Task.sleep(for: .milliseconds(200))
            return nil
        })
    let context = hostContext(tool) { name, args, _ in
        dispatches.withLock { $0 += 1 }
        return AgentToolCallOutcome(toolCall: AgentToolCall(id: "change-1", name: name, arguments: args),
                                   result: AgentToolResult(content: []), isError: false)
    }
    let result = try await executeCodemode(toolCallId: "before-dispatch",
        params: ["code": AnyCodable("await tools.change({})")], signal: signal, context: context,
        options: CodemodeToolOptions(validationErrorPrefix: "validation: "), forceWatchdog: true)
    try await Task.sleep(for: .milliseconds(400))
    let rows = (result.details?.value as? [String: Any])?["calls"] as? [[String: Any]]
    #expect(rows?.first?["status"] as? String == "cancelled")
    #expect(!hostText(result).contains("outcome unknown"))
    #expect(dispatches.withLock { $0 } == 0)
}

@Test(.timeLimit(.minutes(1))) func codemodeHostDispatchesCallsMadeBeforeResult() async throws {
    let dispatched = LockedState<[String]>([])
    let result = await CodemodeSandbox.execute(code: "", tools: [], timeoutMs: 2_000,
        preludeSource: #"""
        (function(bridge) {
            return { run() {
                bridge("call", "1", "first", "{}");
                bridge("call", "2", "second", "{}");
                bridge("done", "true", "null", "[]");
            }, settle() {}, stalled() {} };
        })
        """#,
        onCall: { call in
            dispatched.withLock { $0.append(call.name) }
            return CodemodeRuntimeReply(ok: true)
        })
    #expect(result.execution.failure == nil)
    try await hostWaitUntil { dispatched.withLock { $0.count } == 2 }
    #expect(dispatched.withLock { $0 }.sorted() == ["first", "second"])
    #expect(result.rejectedCalls.isEmpty)
}

@Test(.timeLimit(.minutes(1))) func codemodeHostUnawaitedCallIsNotRejectedAfterEnd() async throws {
    let statuses = LockedState<Set<String>>([])
    let tool = AgentTool(label: "log", name: "log", description: "Log", parameters: [:]) {
        _, _, _, _ in AgentToolResult(content: [])
    }
    let context = hostContext(tool) { name, args, _ in
        AgentToolCallOutcome(toolCall: AgentToolCall(id: "log-1", name: name, arguments: args),
                            result: AgentToolResult(content: []), isError: false)
    }
    let result = try await executeCodemode(toolCallId: "unawaited",
        params: ["code": AnyCodable("tools.log({}); return 'ok'")],
        onUpdate: { update in
            let rows = (update.details?.value as? [String: Any])?["calls"] as? [[String: Any]] ?? []
            statuses.withLock { $0.formUnion(rows.compactMap { $0["status"] as? String }) }
        }, context: context)
    #expect(result.isError != true)
    try await hostWaitUntil { !statuses.withLock { $0 }.isDisjoint(with: ["ok", "cancelled"]) }
    #expect(!statuses.withLock { $0 }.isDisjoint(with: ["ok", "cancelled"]))
    #expect(!statuses.withLock { $0 }.contains("rejected_after_end"))
}

private final class HostRetentionProbe: Sendable {}

private struct HostWeakProbe: Sendable {
    weak var value: HostRetentionProbe?
}

@Test(.timeLimit(.minutes(1))) func codemodeHostAbandonedThreadReleasesCallState() async throws {
    let weakProbe = LockedState(HostWeakProbe())
    let started = Date()
    let abandoned: Bool
    do {
        let probe = HostRetentionProbe()
        weakProbe.withLock { $0.value = probe }
        let timed = try await executeCodemode(toolCallId: "abandoned-state",
            params: ["code": AnyCodable("const end = Date.now() + 5000; while (Date.now() < end) {}")],
            onUpdate: { _ in withExtendedLifetime(probe) {} },
            options: CodemodeToolOptions(defaultTimeoutMs: 50, lateCallWindow: .milliseconds(100)),
            forceWatchdog: true)
        // Under heavy load the timeout can fire late. Then the host did not abandon a running thread.
        abandoned = timed.isError == true && Date().timeIntervalSince(started) < 2
    }
    guard abandoned else {
        return
    }
    // The thread runs for 5 seconds. A release before that comes from the late call window.
    while weakProbe.withLock({ $0.value != nil }) && Date().timeIntervalSince(started) < 4 {
        try await Task.sleep(for: .milliseconds(50))
    }
    #expect(weakProbe.withLock { $0.value == nil })
}

@Test(.timeLimit(.minutes(1))) func codemodeHostRecordsEachLateRejectionOnce() async throws {
    let late = LockedState<[String]>([])
    let tool = AgentTool(label: "change", name: "change", description: "Change", parameters: [:]) {
        _, _, _, _ in AgentToolResult(content: [])
    }
    let context = hostContext(tool) { name, args, _ in
        AgentToolCallOutcome(toolCall: AgentToolCall(id: "change-1", name: name, arguments: args),
                            result: AgentToolResult(content: []), isError: false)
    }
    let code = "const later = async () => { for (let i = 0; i < 50; i++) await null; try { await tools.change({}) } catch {} }; later(); return 1"
    for run in 0..<20 {
        late.withLock { $0.removeAll() }
        // Watchdog mode returns at the result, as on iOS, so the rejection can arrive after completion.
        let result = try await executeCodemode(toolCallId: "late-\(run)", params: ["code": AnyCodable(code)],
            context: context, options: CodemodeToolOptions(recordLateCall: { _, call in
                late.withLock { $0.append(call.id) }
            }), forceWatchdog: true)
        try await Task.sleep(for: .milliseconds(100))
        let rows = (result.details?.value as? [String: Any])?["calls"] as? [[String: Any]] ?? []
        let returned = rows.compactMap { $0["id"] as? String }.filter { $0.contains("/rejected/") }
        let persisted = late.withLock { $0 }.filter { $0.contains("/rejected/") }
        #expect(returned.count + persisted.count == 1)
    }
}

@Test(.timeLimit(.minutes(1))) func codemodeHostPreparesNestedArgumentsOnce() async throws {
    let prepared = LockedState(0)
    let tool = AgentTool(label: "read", name: "read", description: "Read",
        parameters: ["type": AnyCodable("object"), "properties": AnyCodable(["path": ["type": "string"]]),
                     "required": AnyCodable(["path"])],
        execute: { _, _, _, _ in AgentToolResult(content: [.text(TextContent(text: "read"))]) },
        prepareArguments: { _ in
            prepared.withLock { $0 += 1 }
            return nil
        })
    let model = getModel(provider: .openai, modelId: "gpt-4o-mini")
    let assistant = AssistantMessage(content: [], api: model.api, provider: model.provider, model: model.id,
        usage: Usage(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0), stopReason: .toolUse)
    let context = hostContext(tool) { name, args, options in
        await runToolCall(AgentToolCall(id: "read-1", name: name, arguments: args),
            options: RunToolCallOptions(tools: [tool], assistantMessage: assistant,
                                        context: AgentContext(messages: [], tools: [tool]),
                                        signal: options.signal, argumentsPrepared: options.argumentsPrepared))
    }
    let result = try await executeCodemode(toolCallId: "prepare-once",
        params: ["code": AnyCodable("text(await tools.read({path: 'a'}))")], context: context,
        options: CodemodeToolOptions(validationErrorPrefix: "validation: "))
    #expect(result.isError != true)
    #expect(hostText(result).contains("read"))
    #expect(prepared.withLock { $0 } == 1)
}
