import Foundation
import PiSwiftAI
import PiSwiftChord
import PiSwiftDurable
import PiSwiftDurableTesting
import Testing
@testable import PiSwiftCodingAgentDurable

private struct D10Approval: Codable, Sendable { let allow: Bool }
private struct D10ChildCheckpoint: TaskCheckpoint {
    enum Phase: String, Codable, Sendable { case run, joined }
    let phase: Phase
}

private struct D10HostFixture: Sendable {
    let base: URL
    let setup: HarnessChatSetup
    let opened: OpenDurableResult

    static func open(_ setup: HarnessChatSetup) async throws -> Self {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("D10-v16-\(UUID())")
        let agent = base.appendingPathComponent("agent")
        let cwd = base.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: agent, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)
        let opened = try await openDurable(.init(cwd: cwd.path, transcriptMode: .paged), dependencies: .init(
            agentDirectory: agent.path, makeModels: { _ in
                .init(models: setup.models, available: setup.models.models,
                      initial: { _ in .init(model: .init(provider: "faux", modelId: "faux-1")) })
            }, clock: setup.clock, registry: setup.registry))
        return .init(base: base, setup: setup, opened: opened)
    }

    var view: DurableHostView { opened.hostView.hostCurrent() }
    func close() async {
        await opened.close()
        try? FileManager.default.removeItem(at: base)
    }
    func wait(_ condition: @escaping @Sendable (DurableHostView) -> Bool) async throws {
        let (updates, continuation) = AsyncStream<Void>.makeStream()
        let subscription = opened.hostView.subscribe { continuation.yield(()) }
        defer { subscription.cancel(); continuation.finish() }
        continuation.yield()
        for await _ in updates {
            if condition(view) { return }
        }
        throw CancellationError()
    }
}

@Suite("PiSwiftCodingAgentDurableTests.D10V16Host", .timeLimit(.minutes(2)))
struct D10V16HostTests {
    @Test func keptInputSurvivesAbortAndRunsOnNextInput() async throws {
        let setup = HarnessChatSetup(clock: TestClock(now: 1_000))
        let held = HarnessGatedResponse(message: chatAssistant("first"))
        setup.models.setResponses([held.step])
        let fixture = try await D10HostFixture.open(setup)
        defer { Task { await fixture.close() } }
        await fixture.opened.hostController.submit("first", whenBusy: .followUp)
        await held.reached.wait()
        let keptID = try await fixture.opened.hostController.submitInput(.text("keep me"),
            whenBusy: .followUp, onAbort: .keep)
        try await fixture.wait { $0.keptInputs.first?.id == keptID }
        #expect(fixture.view.keptInputs.first?.onAbort == .keep)
        await fixture.opened.hostController.abort()
        try await fixture.wait { $0.live.run == nil && $0.keptInputs.first?.id == keptID }
        #expect(fixture.view.inbox.items.map(\.id).contains(keptID))
        setup.models.setResponses([.message(chatAssistant("kept answer")),
                                   .message(chatAssistant("next answer"))])
        await fixture.opened.hostController.submit("next", whenBusy: .followUp)
        try await fixture.wait { $0.keptInputs.isEmpty && $0.live.run == nil &&
            $0.rows.contains { row in
                if case .entry(let entry) = row.item {
                    return (try? entry.messages()?.contains { textOf($0) == "next answer" }) == true
                }
                return false
            }
        }
        #expect(fixture.view.inbox.items.isEmpty)
        await fixture.close()
    }

    @Test func pendingReviewAppearsAndSettlesThroughHost() async throws {
        let setup = HarnessChatSetup(clock: TestClock(now: 1_000))
        let token: SignalToken<D10Approval> = try defineSignal(name: "host.review", version: 1,
            schema: ["type": "object", "properties": ["allow": ["type": "boolean"]], "required": ["allow"]])
        let review = TaskDefinition<Int, D10ChildCheckpoint, JSONValue, NoTaskHooks>(
            name: "host.review-task", version: 1, initial: { _ in .init(phase: .run) },
            phase: { task, runtime, context in
                if task.checkpoint.phase == .run {
                    try await runtime.sleep(signals: [token.key("release")],
                        checkpoint: JSONValue(encoding: D10ChildCheckpoint(phase: .joined)), context: context)
                } else {
                    try await runtime.commit({ _, _ in .terminal(outcome: .completed(result: .object([:]))) }, context: context)
                }
            }, abort: { _, runtime, context in
                try await runtime.commit({ _, _ in .terminal(outcome: .aborted()) }, context: context)
            })
        try setup.registry.install(Extension(name: "review", hooks: [hook(GenerationHooks(
            onYield: { _, _, _ in GenerationYield(tasks: [try hookTask(review, input: 0)]) }))],
            tasks: [AnyTaskDefinition(review)]))
        setup.models.setResponses([.message(chatAssistant("Review this answer"))])
        let fixture = try await D10HostFixture.open(setup)
        defer { Task { await fixture.close() } }
        await fixture.opened.hostController.submit("Review", whenBusy: .followUp)
        try await fixture.wait { $0.pendingReview != nil && !$0.signalSleepingTasks.isEmpty }
        let pending = try #require(fixture.view.pendingReview)
        #expect(pending.tasks.count == 1)
        #expect(fixture.view.rows.contains { row in
            if case .entry(let entry) = row.item { return entry.id == pending.answer }
            return false
        })
        #expect(try await fixture.opened.hostController.deliverSignal(taskId: pending.tasks[0], token: token,
            key: "release", value: .init(allow: true)) == .delivered)
        try await fixture.wait { $0.pendingReview == nil && $0.live.run == nil }
        await fixture.close()
    }

    @Test func ownedChildParksToolAsWaitingUntilItAnswers() async throws {
        let setup = HarnessChatSetup(clock: TestClock(now: 1_000))
        let token: SignalToken<D10Approval> = try defineSignal(name: "host.child", version: 1,
            schema: ["type": "object", "properties": ["allow": ["type": "boolean"]], "required": ["allow"]])
        let child = TaskDefinition<Int, D10ChildCheckpoint, JSONValue, NoTaskHooks>(
            name: "host.child-task", version: 1, initial: { _ in .init(phase: .run) },
            phase: { task, runtime, context in
                if task.checkpoint.phase == .run {
                    try await runtime.sleep(signals: [token.key("child")],
                        checkpoint: JSONValue(encoding: D10ChildCheckpoint(phase: .joined)), context: context)
                } else {
                    try await runtime.commit({ _, _ in .terminal(outcome: .completed(result: .object([:]))) }, context: context)
                }
            }, abort: { _, runtime, context in
                try await runtime.commit({ _, _ in .terminal(outcome: .aborted()) }, context: context)
            })
        let tool = try ToolRegistration(name: "wait-child", description: "Wait", parameters: ["type": "object"],
            execute: { _, api, context in
                if api.wake != nil { return .result(.init(output: [.text(.init(text: "child answered"))])) }
                let childID = try await api.createTask(child, input: 0,
                    options: .init(ownership: .task(taskId: api.taskId)), context: context)
                return .park(.wait(on: [childID], policy: .allSettled))
            })
        try setup.registry.install(Extension(name: "child", tools: [tool], tasks: [AnyTaskDefinition(child)]))
        var request = chatAssistant("", reason: .toolUse)
        request.content = [.toolCall(.init(id: "wait-1", name: "wait-child", arguments: [:]))]
        setup.models.setResponses([.message(request), .message(chatAssistant("done"))])
        let fixture = try await D10HostFixture.open(setup)
        defer { Task { await fixture.close() } }
        await fixture.opened.hostController.submit("Wait for child", whenBusy: .followUp)
        try await fixture.wait { $0.parkedTools.first?.slot.status == .waiting }
        #expect(fixture.view.parkedTools.first?.slot.callId == "wait-1")
        let childID = try #require(fixture.view.tasks?.tasks.values.first { $0.kind == "host.child-task" }?.id)
        #expect(fixture.view.parkedTools.first?.waitingOn == [childID])
        #expect(fixture.view.parkedTools.first?.waitingPolicy == .allSettled)
        #expect(try await fixture.opened.hostController.deliverSignal(taskId: childID, token: token,
            key: "child", value: .init(allow: true)) == .delivered)
        try await fixture.wait { $0.live.run == nil && $0.toolDurationMs["wait-1"] != nil }
        #expect(fixture.view.parkedTools.isEmpty)
        await fixture.close()
    }

    @Test func approvalGateExposesKeyAndSettlesThroughHost() async throws {
        let setup = HarnessChatSetup(clock: TestClock(now: 1_000))
        let token: SignalToken<D10Approval> = try defineSignal(name: "host.approval", version: 1,
            schema: ["type": "object", "properties": ["allow": ["type": "boolean"]], "required": ["allow"]])
        let tool = try ToolRegistration(name: "guarded", description: "Guarded", parameters: ["type": "object"],
            execute: { _, _, _ in .result(.init(output: [.text(.init(text: "approved"))])) })
        try setup.registry.install(Extension(name: "guarded", tools: [tool], hooks: [hook(ToolHooks(
            beforeTool: { _, api, context in
                let decision = try await api.readSignal(token, key: "approval-1", context: context)
                switch decision {
                case nil: return .init(sleep: .init(until: 10_000, signals: [try token.key("approval-1")]))
                case .value(let value): return value.allow ? nil : .init(block: "Denied")
                case .expired: return .init(block: "Expired")
                }
            }))]))
        var request = chatAssistant("", reason: .toolUse)
        request.content = [.toolCall(.init(id: "guarded-1", name: "guarded", arguments: [:]))]
        setup.models.setResponses([.message(request), .message(chatAssistant("done"))])
        let fixture = try await D10HostFixture.open(setup)
        defer { Task { await fixture.close() } }
        await fixture.opened.hostController.submit("Run guarded", whenBusy: .followUp)
        try await fixture.wait { $0.parkedTools.first?.isGated == true }
        let gate = try #require(fixture.view.parkedTools.first)
        #expect(gate.phase == "call")
        #expect(gate.until == 10_000)
        #expect(gate.signals == [try token.key("approval-1")])
        let task = try #require(gate.slot.taskId)
        #expect(try await fixture.opened.hostController.deliverSignal(taskId: task, token: token,
            key: "approval-1", value: .init(allow: true)) == .delivered)
        try await fixture.wait { $0.live.run == nil && $0.toolDurationMs["guarded-1"] != nil }
        #expect(fixture.view.parkedTools.isEmpty)
        await fixture.close()
    }

    @Test func parkedSignalToolIsVisibleAndWokenThroughHost() async throws {
        let clock = TestClock(now: 1_000)
        let setup = HarnessChatSetup(clock: clock)
        let token: SignalToken<D10Approval> = try defineSignal(name: "host.answer", version: 1,
            schema: ["type": "object", "properties": ["allow": ["type": "boolean"]], "required": ["allow"]])
        let key = try token.key("person")
        let tool = try ToolRegistration(name: "ask", description: "Ask", parameters: ["type": "object"],
            execute: { _, api, _ in
                if api.wake == nil { return .park(.sleep(signals: [key])) }
                return .result(.init(output: [.text(.init(text: "answered"))]))
            })
        try setup.registry.install(Extension(name: "ask", tools: [tool]))
        var request = chatAssistant("", reason: .toolUse)
        request.content = [.toolCall(.init(id: "ask-1", name: "ask", arguments: [:]))]
        setup.models.setResponses([.message(request), .message(chatAssistant("done"))])
        let fixture = try await D10HostFixture.open(setup)
        defer { Task { await fixture.close() } }
        await fixture.opened.hostController.submit("Ask someone", whenBusy: .followUp)
        try await fixture.wait { $0.parkedTools.first?.slot.status == .sleeping &&
            $0.parkedTools.first?.signals == [key] }
        let parked = try #require(fixture.view.parkedTools.first)
        #expect(parked.signals == [key])
        #expect(parked.slot.callId == "ask-1")
        #expect(fixture.view.signalSleepingTasks.contains { $0.id == parked.slot.taskId && $0.signals == [key] })
        let id = try #require(parked.slot.taskId)
        clock.advance(by: 500)
        #expect(try await fixture.opened.hostController.deliverSignal(taskId: id, token: token,
            key: "person", value: .init(allow: true)) == .delivered)
        try await fixture.wait { $0.toolDurationMs["ask-1"] != nil && $0.live.run == nil }
        #expect(fixture.view.parkedTools.isEmpty)
        #expect((fixture.view.toolDurationMs["ask-1"] ?? 0) >= 500)
        await fixture.close()
    }
}
