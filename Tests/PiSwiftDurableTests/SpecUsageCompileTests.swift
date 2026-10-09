import Foundation
import Testing
import PiSwiftAI
import PiSwiftChord
import PiSwiftDurable

// Port of durable/test/spec-usage.test.ts at v1.1.0. These functions are
// compiled with normal imports. No function below starts a harness or a request.
// TypeScript-only shapes: Type.Object is a JSON Schema plus Decodable arguments;
// object spread is a mutable value copy; phase unions use TaskCheckpoint;
// live getters use HarnessSettingsProvider; property drafts use JSONDraft.
// The upstream CodingTools/read/edit/bash factories are not in this module.
// The application supplies their ToolRegistration values and environment factory.
private struct SpecPlan: Codable, Sendable { var enabled = false }
private struct SpecContainer: Codable, Sendable { var image = "node:22" }
private struct SpecToolArgs: Decodable, Sendable { var task: String }
private struct SpecReceipt: Codable, Sendable { var id: String }
private struct SpecPaymentResult: Codable, Sendable { var entryId: EntryID }
private struct SpecCharge: TaskCheckpoint {
    enum Phase: String, Codable, Sendable { case prepare, charge }
    var phase: Phase = .prepare
    var key: String?
}
private struct SpecFollow: TaskCheckpoint {
    enum Phase: String, Codable, Sendable { case follow }
    var phase: Phase = .follow
}
private struct SpecHold: TaskCheckpoint {
    enum Phase: String, Codable, Sendable { case hold }
    var phase: Phase = .hold
}
private struct SpecReport: TaskCheckpoint {
    enum Phase: String, Codable, Sendable { case report }
    var phase: Phase = .report
}
private enum SpecUsageError: Error { case childFailed, absentAnswer, absentKey }
private typealias SpecPayment = TaskDefinition<JSONValue, SpecCharge, SpecPaymentResult, NoTaskHooks>

private struct SpecDependencies: Sendable {
    let read: ToolRegistration
    let edit: ToolRegistration
    let bash: ToolRegistration
    let venvBash: ToolRegistration
    let codingTools: Extension
    let models: any DurableModels
    let storage: any DurableStorage
    let session: Session
    let conversationId: ConversationID
    let renderAgentsMd: @Sendable () -> String?
    let renderSkills: @Sendable () -> String?
    let isDangerous: @Sendable (ToolCall) -> Bool
    let writes: @Sendable (ToolCall) -> Bool
    let secondPass: @Sendable (AssistantMessage, HookApi, ChordContext) async throws -> GenerationYield?
    let metric: @Sendable (String, Duration) -> Void
    let answerText: @Sendable (ToolExecutionApi, EntryID, ChordContext) async throws -> String
    let charge: @Sendable (String) async throws -> SpecReceipt
    let cancel: @Sendable (SpecCharge) async throws -> Void
    let newKey: @Sendable () -> String
    let settings: @Sendable () -> HarnessSettings
    let localEnv: @Sendable (String) -> any ExecutionEnv
    let containerEnv: @Sendable (String, String, ChordContext) async throws -> any ExecutionEnv
}

/// Compile the extension, hook, wrapper, tool, and task examples in sections 5 and 7.
private func specExtensions(_ app: SpecDependencies) throws -> (extensions: [Extension], payment: SpecPayment) {
    let contextFiles = defineExtension(Extension(name: "context-files", sections: [
        section("agents-md") { _, _ in app.renderAgentsMd() },
    ]))
    let skills = Extension(name: "skills", sections: [section("skills") { _, _ in app.renderSkills() }])
    let skillsV2 = Extension(name: "skills", sections: [section("skills") { _, _ in app.renderSkills() }])
    let coding = Extension(name: "coding", sections: [
        section("preamble", tag: false) { _, _ in "You are an expert coding assistant." },
        section("cwd") { input, _ in input.env.map { "Working directory: \($0.cwd)" } },
    ])
    let permissions = Extension(name: "permissions", hooks: [
        hook(toolTask, handlers: ToolHooks(beforeTool: { call, _, _ in
            app.isDangerous(call) ? BeforeToolResult(block: "Needs approval") : nil
        })),
    ])
    let reviewer = Extension(name: "reviewer", sections: [
        section("role") { _, _ in "You review diffs. Report problems as a list. Never edit files." },
    ], hooks: [hook(generationTask, handlers: GenerationHooks(onYield: app.secondPass))])
    let timing = Extension(name: "timing", wraps: [wrapTool(app.bash) { tool in
        var wrapped = tool
        wrapped.execute = { args, api, context in
            let start = ContinuousClock.now
            defer { app.metric("bash", start.duration(to: ContinuousClock.now)) }
            return try await tool.execute(args, api, context)
        }
        return wrapped
    }])
    let venv = Extension(name: "venv", tools: [app.venvBash])
    let planDoc = try ConversationDocToken<SpecPlan>(kind: "app.plan-mode", version: 1,
        fork: .current, initial: { SpecPlan() })
    let planMode = Extension(name: "plan-mode", hooks: [hook(toolTask, handlers: ToolHooks(
        beforeTool: { call, api, context in
            let plan = try await api.read.snapshot(planDoc, conversationId: api.conversationId, context: context)
            return plan?.enabled == true && app.writes(call) ? BeforeToolResult(block: "Plan mode: read-only") : nil
        }))])

    // Swift Sendable closures cannot capture a local value before initialization.
    // Removal uses the extension's stable name through an equal-name token.
    let subagent = Extension(name: "subagent", tools: [try defineTool(name: "subagent",
        description: "Run one task in a child conversation.", parameters: [
            "type": .string("object"), "properties": .object(["task": .object(["type": .string("string")])]),
            "required": .array([.string("task")]),
        ], args: SpecToolArgs.self, replay: .safe) { args, api, context in
            let child = try await api.commit({ tx in
                let existing = try await tx.scanConversations(.init(ownerTaskId: api.taskId), limit: 1).items.first
                if let existing { return existing.id }
                let created = try await tx.createConversation(ownership: .task(taskId: api.taskId))
                try await configure(tx: tx, conversationId: created.id,
                    change: AgentChange(extensions: .set(.edit(remove: [Extension(name: "subagent")]))))
                return created.id
            }, context: context)
            try await api.details(.object(["conversationId": .number(Double(child.rawValue))]), context)
            guard let handle = try await api.conversation(id: child, context: context) else { throw SpecUsageError.childFailed }
            let submission = try await handle.submit(.input(content: .text(args.task), requestId: "subagent:\(api.taskId.rawValue)"), context: context)
            let settled = try await submission.wait(context: context)
            guard settled.status == "done", let answer = settled.answer else { throw SpecUsageError.absentAnswer }
            return ToolExecutionResult(content: [.text(TextContent(text: try await app.answerText(api, answer, context)))])
        }])
    let anchor = TaskDefinition<JSONValue, SpecHold, JSONValue, NoTaskHooks>(name: "app.anchor", version: 1,
        initial: { _ in SpecHold() }, phase: { _, _, _ in }, abort: { _, _, _ in })
    let reporter = TaskDefinition<JSONValue, SpecReport, JSONValue, NoTaskHooks>(name: "app.reporter", version: 1,
        initial: { _ in SpecReport() }, phase: { _, _, _ in }, abort: { _, _, _ in })
    let subagentTools = Extension(name: "subagent-tools", tools: [app.read],
        tasks: [AnyTaskDefinition(anchor), AnyTaskDefinition(reporter)])
    let chat = Extension(name: "chat", sections: [section("preamble", tag: false) { _, _ in "You are a helpful assistant." }])

    let payment = defineTask(SpecPayment(name: "app.payment", version: 1, initial: { _ in SpecCharge() },
        phase: { task, runtime, context in
            switch task.checkpoint.phase {
            case .prepare:
                try await runtime.commit({ _, _ in
                    .running(checkpoint: try JSONValue(encoding: SpecCharge(phase: .charge, key: app.newKey())))
                }, context: context)
            case .charge:
                guard let key = task.checkpoint.key else { throw SpecUsageError.absentKey }
                let receipt = try await app.charge(key)
                try await runtime.commit({ tx, current in
                    let entry = try await tx.appendEntry(current.conversationId,
                        value: EntryDraft(kind: "app.receipt", data: try JSONValue(encoding: receipt)))
                    return .terminal(outcome: .completed(result: try JSONValue(encoding: SpecPaymentResult(entryId: entry.id))))
                }, context: context)
            }
        }, abort: { task, runtime, context in
            try await app.cancel(task.checkpoint)
            try await runtime.commit({ _, _ in .terminal(outcome: .aborted(reason: "user")) }, context: context)
        }))
    return ([contextFiles, skills, skillsV2, coding, permissions, reviewer, timing, venv, planMode, subagent, subagentTools, chat], payment)
}

/// Compile configured children and named subagents in sections 2.2 and 7.3.
private func specChildSequences(tx: Transaction, api: ToolExecutionApi, app: SpecDependencies) async throws {
    let child = try await tx.createConversation(ownership: .task(taskId: api.taskId))
    try await configure(tx: tx, conversationId: child.id, change: AgentChange(
        model: .set(ModelRef(provider: "anthropic", modelId: "haiku")),
        tools: .set(.exact([app.read])), cwd: .set("/worktree")))
    let anchor = TaskDefinition<JSONValue, SpecHold, JSONValue, NoTaskHooks>(name: "app.anchor", version: 1,
        initial: { _ in SpecHold() }, phase: { _, _, _ in }, abort: { _, _, _ in })
    let id = try await tx.createTask(anchor, input: .null, options: .init(ownership: .conversation(), background: true))
    let named = try await tx.createConversation(ownership: .task(taskId: id))
    try await configure(tx: tx, conversationId: named.id, change: AgentChange(
        extensions: .set(.edit(remove: [Extension(name: "subagent-tools")])),
        instructions: .set("You are the subagent \"review\". Answer the main agent's requests.")))
}

// Swift uses a Sendable callback in place of the TypeScript settings class getters.
private struct SpecSettingsManager: Sendable {
    let timeoutMs: @Sendable () -> Int
    let autoCompact: @Sendable () -> Bool
    let setAutoCompact: @Sendable (Bool) -> Void
}
private func specLiveSettings(_ manager: SpecSettingsManager) -> HarnessSettingsProvider {
    manager.setAutoCompact(false)
    return HarnessSettingsProvider {
        HarnessSettings(stream: .init(timeoutMs: manager.timeoutMs()),
            compaction: .init(enabled: manager.autoCompact()))
    }
}

/// Compile host setup, settings, tool filters, extension reload, and environment selection.
private func specHostSequences(_ app: SpecDependencies, context: ChordContext) async throws {
    let extensions = try specExtensions(app).extensions
    let registry = createRegistry()
    for item in [app.codingTools] + extensions { try registry.install(item) }
    let provider = HarnessSettingsProvider { app.settings() }
    let options = HarnessOptions(models: app.models, registry: registry, settings: provider,
        env: { target, _ in app.localEnv(target.cwd ?? "/work") })
    let harness = try await Harness.open(storage: app.storage, options: options, context: context)
    let root = try await harness.root(options: .init(agent: AgentChange(
        model: .set(.init(provider: "anthropic", modelId: "sonnet")), cwd: .set("/work"))), context: context)
    try await root.configure(change: AgentChange(tools: .set(.remove([app.edit]))), context: context)
    try await root.configure(change: AgentChange(tools: .set(.remove([app.bash]))), context: context)
    try await root.configure(change: AgentChange(tools: .clear), context: context)
    try await root.configure(change: AgentChange(extensions: .set(.edit(add: [Extension(name: "venv")]))), context: context)
    let plan = try ConversationDocToken<SpecPlan>(kind: "app.plan-mode", version: 1, fork: .current, initial: { SpecPlan() })
    try await root.commit({ tx in
        try await tx.doc(plan, conversationId: root.id).set("enabled", .bool(true))
    }, context: context)
    registry.uninstall(Extension(name: "skills"))
    try await harness.close(context: context)

    let container = try ConversationDocToken<SpecContainer>(kind: "app.container", version: 1,
        fork: .current, initial: { SpecContainer() })
    let containerOptions = HarnessOptions(models: app.models, registry: createRegistry(), env: { target, context in
        if let value = try await target.read.snapshot(container, conversationId: target.conversationId, context: context) {
            return try await app.containerEnv(value.image, target.cwd ?? "/work", context)
        }
        return app.localEnv(target.cwd ?? "/work")
    })
    let containerHarness = try await Harness.open(storage: app.storage, options: containerOptions, context: context)
    try await containerHarness.close(context: context)
}

/// Compile table order and draft lifetime examples in sections 4 and 3.4.
private func specDocumentSequences(_ app: SpecDependencies, context: ChordContext) async throws {
    let follow = TaskDefinition<JSONValue, SpecFollow, JSONValue, NoTaskHooks>(name: "app.follow", version: 1,
        initial: { _ in SpecFollow() }, phase: { _, _, _ in }, abort: { _, _, _ in })
    let escaped: JSONDraft = try await app.session.commit({ tx in
        let _: ConversationRecord? = try await tx.conversation(app.conversationId)
        let live = try await tx.doc(LiveDoc, conversationId: app.conversationId)
        let _: EntryRecord = try await tx.appendEntry(app.conversationId, value: EntryDraft(kind: "app.message"))
        try live.remove("generation")
        let _: TaskID = try await tx.createTask(follow, input: .object([:]),
            options: .init(ownership: .conversation(), conversationId: app.conversationId))
        return live
    }, context: context)
    // This call compiles but throws after commit because the draft is revoked.
    try escaped.remove("generation")
}

@Suite struct SpecUsageCompileTests {
    @Test func publicSpecExamplesTypeCheckWithoutExecution() {
        let extensions: @Sendable (SpecDependencies) throws -> (extensions: [Extension], payment: SpecPayment) = specExtensions
        let child: @Sendable (Transaction, ToolExecutionApi, SpecDependencies) async throws -> Void = specChildSequences
        let host: @Sendable (SpecDependencies, ChordContext) async throws -> Void = specHostSequences
        let documents: @Sendable (SpecDependencies, ChordContext) async throws -> Void = specDocumentSequences
        let settings: @Sendable (SpecSettingsManager) -> HarnessSettingsProvider = specLiveSettings
        // The typed references make all examples part of this test's compile contract.
        #expect(type(of: extensions) == type(of: specExtensions))
        #expect(type(of: child) == type(of: specChildSequences))
        #expect(type(of: host) == type(of: specHostSequences))
        #expect(type(of: documents) == type(of: specDocumentSequences))
        #expect(type(of: settings) == type(of: specLiveSettings))
    }
}
