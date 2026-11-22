import Foundation
import PiSwiftAI
import PiSwiftChord
import PiSwiftDurable
import PiSwiftDurableTesting
import Testing
@testable import PiSwiftCodingAgentDurable

private struct ScenarioInput: Codable, Sendable { let label: String }
private struct ScenarioCheckpoint: TaskCheckpoint {
    enum Phase: String, Codable, Sendable { case run }
    let phase: Phase = .run
}

@Suite struct D10RunScenarioTests {
    @Test(.timeLimit(.minutes(1)))
    func plainAnswerHostSnapshot() async throws {
        let host = try await ScenarioHost.open()
        defer { host.remove() }
        host.setup.models.setResponses([.message(chatAssistant("Paris."))])
        await host.result.hostController.submit("Capital?", whenBusy: .followUp)
        try await host.waitForAnswer("Paris.")
        let view = try await host.snapshot()
        #expect(view.live.run == nil && view.live.generation == nil)
        #expect(view.ending == nil && view.inbox.items.isEmpty)
        try expectScenarioFixture("plain", view)
        try await host.close()
    }

    @Test(.timeLimit(.minutes(1)))
    func nestedToolHookReplacementAndAfterRunHostSnapshots() async throws {
        let reached = HarnessChatSignal(), release = HarnessChatSignal()
        let afterReached = HarnessChatSignal(), afterRelease = HarnessChatSignal()
        let setup = HarnessChatSetup(settings: .init(retry: .init(enabled: false)), clock: TestClock(now: 1000))
        let inner = try ToolRegistration(name: "inner", description: "Inner test", parameters: ["type": "object", "properties": [:]]) { _, _, _ in
            reached.signal()
            await release.wait()
            return .init(output: [.text(.init(text: "inner original"))])
        }
        let outer = try ToolRegistration(name: "outer", description: "Outer test", parameters: ["type": "object", "properties": [:]]) { _, api, context in
            _ = try await api.executeTool("inner", arguments: [:], context: context)
            return .init(output: [.text(.init(text: "outer original"))])
        }
        let after = TaskDefinition<ScenarioInput, ScenarioCheckpoint, String, NoTaskHooks>(
            name: "scenario.after", version: 1, initial: { _ in .init() },
            phase: { task, runtime, context in
                afterReached.signal()
                await afterRelease.wait()
                try await runtime.commit({ tx, _ in
                    _ = try await tx.appendEntry(runtime.conversationId,
                        value: .init(kind: "scenario.after", data: .string(task.input.label)))
                    return .terminal(outcome: .completed(result: .string(task.input.label)))
                }, context: context)
            }, abort: { _, runtime, context in
                try await runtime.commit({ _, _ in .terminal(outcome: .aborted()) }, context: context)
            })
        try setup.registry.install(Extension(name: "scenario", tools: [inner, outer], hooks: [
            hook(ToolHooks(afterTool: { (call: ToolHookCall, result: ToolExecutionResult, _: HookApi, _: ChordContext) in
                var changed = result
                changed.output = [.text(.init(text: call.call.name + " replaced"))]
                return changed
            })),
            hook(GenerationHooks(afterRun: { _, _, _ in
                AfterRunResult(tasks: [try hookTask(after, input: .init(label: "after complete"))])
            }))
        ], tasks: [AnyTaskDefinition(after)]))
        let host = try await ScenarioHost.open(setup: setup)
        defer { host.remove() }
        var call = chatAssistant("", reason: .toolUse)
        call.content = [.toolCall(.init(id: "outer-call", name: "outer", arguments: [:]))]
        setup.models.setResponses([.message(call), .message(chatAssistant("Tool answer."))])
        await host.result.hostController.submit("Use tools.", whenBusy: .followUp)
        await reached.wait()
        let running = try await host.snapshot()
        #expect(running.live.tools?.contains { $0.name == "outer" && $0.status == .running } == true)
        #expect(running.live.nestedTools?.contains { $0.name == "inner" && $0.status == .running } == true)
        #expect(running.live.run != nil)
        release.signal()
        await afterReached.wait()
        await host.waitForTaskKind("scenario.after")
        let finishing = try await host.snapshot()
        #expect(finishing.live.run?.afterRun?.tasks?.isEmpty == false)
        #expect(finishing.tasks?.tasks.values.contains { $0.kind == "scenario.after" } == true)
        afterRelease.signal()
        try await host.waitForAnswer("Tool answer.")
        try await eventually { host.result.hostView.hostCurrent().outcomes.contains { $0.kind == "scenario.after" && $0.outcome.status == "completed" } }
        let final = try await host.snapshot()
        #expect(final.live.run == nil && final.live.tools == nil && final.live.nestedTools == nil)
        #expect(final.outcomes.contains { $0.kind == "scenario.after" && $0.outcome.status == "completed" })
        try expectScenarioFixture("nested-hook-after", final)
        try await host.close()
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func compactionFailureHostSnapshot(automatic: Bool) async throws {
        let setup = HarnessChatSetup(options: .init(models: [.init(id: "faux-1", contextWindow: 2000, maxTokens: 900)]), settings: .init(retry: .init(enabled: false),
            compaction: .init(enabled: false, reserveTokens: 1000, keepRecentTokens: 50)), clock: TestClock(now: 1000))
        let host = try await ScenarioHost.open(setup: setup)
        defer { host.remove() }
        for index in 1...3 {
            setup.models.setResponses([.message(chatAssistant("Answer \(index) " + String(repeating: "x", count: 400)))])
            await host.result.hostController.submit("Question \(index) " + String(repeating: "x", count: 400), whenBusy: .followUp)
            try await host.waitForAnswer("Answer \(index) " + String(repeating: "x", count: 400))
        }
        if automatic {
            await host.result.hostController.setCompactionPolicy(.init(enabled: true, reserveTokens: 500,
                keepRecentTokens: 50, backgroundTokens: 1000))
            setup.models.setResponses((0..<4).map { _ in .factory { transcript, _, _, _ in
                if case .system(let system)? = transcript.messages.first,
                   getSystemMessageText(system).hasPrefix("You are a context summarization assistant") {
                    return chatAssistant("", reason: .error, error: "scripted summary failure")
                }
                return chatAssistant("Fourth answer.")
            } })
            await host.result.hostController.submit("Fourth question.", whenBusy: .followUp)
            try await host.waitForAnswer("Fourth answer.")
        } else {
            setup.models.setResponses([.message(chatAssistant("", reason: .error, error: "scripted summary failure"))])
            await host.result.hostController.compact(instructions: nil)
        }
        try await eventually {
            let view = host.result.hostView.hostCurrent()
            return view.live.compactionFailure != nil && view.outcomes.contains { $0.kind == "pi.compaction" && $0.outcome.status == "failed" }
        }
        let view = try await host.snapshot()
        #expect(view.live.compactionFailure?.reason == (automatic ? .threshold : .manual))
        #expect(view.live.compactionFailure?.error == "Summarization failed: scripted summary failure")
        #expect(view.outcomes.contains { $0.kind == "pi.compaction" && $0.outcome.status == "failed" })
        #expect(view.ending == nil)
        #expect(scenarioEntries(view).filter { $0.kind == "pi.assistant" }.count == (automatic ? 4 : 3))
        try await host.close()
    }
}

/// Opens the production host with an isolated agent directory and scripted services.
private struct ScenarioHost: Sendable {
    let base: URL
    let setup: HarnessChatSetup
    let result: OpenDurableResult

    static func open(setup: HarnessChatSetup = .init(settings: .init(retry: .init(enabled: false)), clock: TestClock(now: 1000))) async throws -> Self {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("D10-run-scenarios-\(UUID())")
        let agent = base.appendingPathComponent("agent")
        let cwd = base.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: agent, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)
        try Data("{\"retry\":{\"enabled\":false},\"compaction\":{\"enabled\":false,\"reserveTokens\":1000,\"keepRecentTokens\":50}}".utf8)
            .write(to: agent.appendingPathComponent("settings.json"))
        let result = try await openDurable(.init(cwd: cwd.path, transcriptMode: .paged), dependencies: .init(
            agentDirectory: agent.path, makeModels: { _ in
                .init(models: setup.models, available: setup.models.models,
                    initial: { _ in .init(model: .init(provider: "faux", modelId: "faux-1")) })
            }, clock: setup.clock, registry: setup.registry))
        return .init(base: base, setup: setup, result: result)
    }

    func snapshot() async throws -> DurableHostView { result.hostView.hostCurrent() }
    func waitForTaskKind(_ kind: String) async {
        let (updates, continuation) = AsyncStream<Void>.makeStream()
        let subscription = result.hostView.subscribe { continuation.yield(()) }
        defer { subscription.cancel(); continuation.finish() }
        continuation.yield()
        for await _ in updates {
            if result.hostView.hostCurrent().tasks?.tasks.values.contains(where: { $0.kind == kind }) == true {
                return
            }
        }
    }
    func waitForAnswer(_ answer: String) async throws {
        try await eventually {
            let view = result.hostView.hostCurrent()
            guard view.live.run == nil else { return false }
            return try scenarioEntries(view).contains { entry in
                try entry.messages()?.contains { message in
                    guard case .assistant(let value) = message else { return false }
                    return value.content.contains { if case .text(let text) = $0 { return text.text == answer }; return false }
                } == true
            }
        }
    }
    func close() async throws { await result.close() }
    func remove() { try? FileManager.default.removeItem(at: base) }
}

private func scenarioEntries(_ view: DurableHostView) -> [EntryRecord] {
    view.rows.compactMap { if case .entry(let value) = $0.item { return value }; return nil }
}

private func expectScenarioFixture(_ name: String, _ view: DurableHostView) throws {
    let lines = try scenarioEntries(view).map { entry -> String in
        if entry.kind == "pi.system" { return "pi.system" }
        if let data = entry.data?.stringValue { return "\(entry.kind): \(data)" }
        let texts = try entry.messages()?.flatMap { message -> [String] in
            switch message {
            case .user(let value): if case .text(let text) = value.content { return [text] }; return []
            case .assistant(let value): return value.content.map { block in
                switch block { case .text(let text): return text.text; case .toolCall(let call): return "call \(call.name)"; default: return "other" }
            }
            case .toolResult(let value): return value.content.compactMap { if case .text(let text) = $0 { return text.text }; return nil }
            default: return []
            }
        } ?? []
        return "\(entry.kind): \(texts.joined(separator: " | "))"
    }
    let actual = (lines + ["run=idle inbox=\(view.inbox.items.count) ending=\(view.ending?.reason.rawValue ?? "none")"]).joined(separator: "\n") + "\n"
    let path = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/D10-run-scenarios-\(name).txt")
    let expected = try String(contentsOf: path, encoding: .utf8)
    #expect(actual == expected, "Snapshot: \(actual)")
}
