import Foundation
import Synchronization
import Testing
import PiSwiftAI
import PiSwiftChord
@testable import PiSwiftDurable
import PiSwiftDurableTesting

@Suite struct HarnessLiveDeltaTests {
    @Test func generationHandoverAndToolStartUseFieldWrites() async throws {
        let setup = HarnessChatSetup(); try installHarnessTool(harnessTestTool("noop"), setup: setup)
        setup.models.setResponses([.message(try toolCalls([("noop", [:], "c1")])), .message(chatAssistant("done"))])
        let opened = try await openChat(setup: setup), log = HarnessLiveDeltaLog()
        let subscription = try opened.harness.subscribeCommits { publication, _ in log.append(publication) }
        let input = try await generationSubmit(opened); _ = try await input.wait(context: .background)
        let tasks = try await opened.root.commit({ tx in try await tx.scanTasks(.init(conversationId: opened.root.id), limit: 20).items }, context: .background)
        let generations = tasks.filter { $0.kind == "pi.generation" }.map(\.id).sorted { $0.rawValue < $1.rawValue }, tool = try #require(tasks.first { $0.kind == "pi.tool" })
        let result = try #require(await allEntries(opened.root).first { $0.kind == "pi.tool-result" })
        let commits = log.commits
        #expect(commits.count == 8)
        #expect(commits[0] == [.set(["run"], ["taskId": .number(Double(generations[0].rawValue)), "inputs": [.number(Double(input.id.rawValue))]])])
        #expect(commits[1] == [.set(["generation"], ["attempt": 1])])
        #expect(commits[2].count == 2 && commits[2].contains(.delete(["generation"])) && commits[2].contains(.set(["tools"], [["callId": "c1", "name": "noop", "taskId": .number(Double(tool.id.rawValue)), "status": "pending"]])))
        #expect(commits[3] == [.set(["tools", 0, "status"], "running")])
        #expect(commits[4].contains(.set(["tools", 0, "status"], "done")) && commits[4].contains(.set(["tools", 0, "entry"], .number(Double(result.id.rawValue)))) && commits[4].count == 2)
        #expect(commits[5].contains(.delete(["tools"])) && commits[5].contains(.set(["run", "taskId"], .number(Double(generations[1].rawValue)))) && commits[5].count == 2)
        #expect(commits[6] == [.set(["generation"], ["attempt": 1])])
        #expect(commits[7].contains(.delete(["run"])) && commits[7].contains(.delete(["generation"])) && commits[7].count == 2)
        subscription.cancel(); try await opened.harness.close(context: .background)
    }

    @Test func headOutputAppendsThenOnlyDroppedCountsChange() async throws {
        let run = try await HarnessLiveDeltaDriver.open(limits: .init(maxLines: 2))
        #expect(try await run.output("one\n") == [.set(liveDeltaOutputPath, "one\n")])
        #expect(try await run.output("two\n") == [.append(liveDeltaOutputPath, "two\n")])
        #expect(try await run.output("three\n") == [.set(["tools", 0, "droppedBytes"], 6), .set(["tools", 0, "droppedLines"], 1)])
        #expect(try await run.output("four\n") == [.set(["tools", 0, "droppedBytes"], 11), .set(["tools", 0, "droppedLines"], 2)])
        _ = try await run.finish(); try await run.close()
    }

    @Test func tailWindowUsesExactFrontTrimAndAppend() async throws {
        let run = try await HarnessLiveDeltaDriver.open(limits: .init(maxLines: 3, retain: .tail))
        #expect(try await run.output("line 1\nline 2\nline 3\n") == [.set(liveDeltaOutputPath, "line 1\nline 2\nline 3\n")])
        #expect(try await run.output("line 4\n") == [.trim(liveDeltaOutputPath, 7), .append(liveDeltaOutputPath, "line 4\n"), .set(["tools", 0, "droppedBytes"], 7), .set(["tools", 0, "droppedLines"], 1)])
        #expect(try await run.output("line 5\nline 6\n") == [.trim(liveDeltaOutputPath, 14), .append(liveDeltaOutputPath, "line 5\nline 6\n"), .set(["tools", 0, "droppedBytes"], 21), .set(["tools", 0, "droppedLines"], 3)])
        #expect(try await generationLive(run.opened)?.tools?.first?.output == "line 4\nline 5\nline 6\n")
        _ = try await run.finish(); try await run.close()
    }

    @Test func overlapLimitWritesWholeWindowAndRepetitionStillFindsOverlap() async throws {
        let wide = try await HarnessLiveDeltaDriver.open(limits: .init(maxBytes: 100 * 1024, maxLines: 1_000_000, retain: .tail))
        let line: @Sendable (Int) -> String = { String(format: "%010d", $0) + " " + String(repeating: "x", count: 989) + "\n" }
        _ = try await wide.output((0..<100).map(line).joined())
        let slid = try await wide.output((100..<104).map(line).joined())
        #expect(liveDeltaOutputOps(slid).map { $0.json[0] } == ["s"])
        _ = try await wide.finish(); try await wide.close()
        let repetitive = try await HarnessLiveDeltaDriver.open(limits: .init(maxLines: 50, retain: .tail))
        _ = try await repetitive.output(String(repeating: "y\n", count: 50))
        let beforeOutput = try await generationLive(repetitive.opened)?.tools?.first?.output ?? ""
        let repetitiveOps = liveDeltaOutputOps(try await repetitive.output("z\n"))
        let afterOutput = try await generationLive(repetitive.opened)?.tools?.first?.output ?? ""
        #expect(beforeOutput.utf16.count == 100)
        #expect(afterOutput.utf16.count == 100)
        #expect(Delta.overlap(beforeOutput, afterOutput, scan: 65_536) == 98)
        #expect(repetitiveOps == [.trim(liveDeltaOutputPath, 2), .append(liveDeltaOutputPath, "z\n")])
        _ = try await repetitive.finish(); try await repetitive.close()
    }

    @Test func detailsDiffLeavesDiagnosticsAppendAndSettlementDeletesProgress() async throws {
        let run = try await HarnessLiveDeltaDriver.open(), details: Delta.Path = ["tools", 0, "details"], diagnostics: Delta.Path = ["tools", 0, "diagnostics"]
        #expect(try await run.step { api, context in try await api.details(["step": 1, "log": "a"], context) } == [.set(details, ["step": 1, "log": "a"])])
        let changed = try await run.step { api, context in try await api.details(["step": 2, "log": "ab"], context) }
        #expect(changed.count == 2 && changed.contains(.set(details + ["step"], 2)) && changed.contains(.append(details + ["log"], "b")))
        #expect(try await run.step { api, context in try await api.details(["step": 2], context) } == [.delete(details + ["log"])])
        let first = ToolDiagnostic(severity: .info, message: "first"), second = ToolDiagnostic(severity: .warn, message: "second")
        #expect(try await run.step { api, _ in try api.diagnostic(first) } == [.set(diagnostics, .array([try JSONValue(encoding: first)]))])
        #expect(try await run.step { api, _ in try api.diagnostic(second) } == [.splice(diagnostics, index: 1, remove: 0, items: [try JSONValue(encoding: second)])])
        let settled = try #require(await run.finish().first)
        #expect(settled.contains(.set(["tools", 0, "status"], "done")) && settled.contains(.delete(details)) && settled.contains(.delete(diagnostics)))
        try await run.close()
    }

    @Test func committedPartialTextUsesLiteralAppendTuples() async throws {
        let clock = TestClock(), setup = HarnessChatSetup(clock: clock), models = HarnessManualModels(base: FakeDurableModels()), opened = try await openChat(setup: setup, models: models), log = HarnessLiveDeltaLog()
        let subscription = try opened.harness.subscribeCommits { publication, _ in log.append(publication) }
        let input = try await generationSubmit(opened); try await eventually { models.seen.withLock { !$0.isEmpty } }
        for text in ["word", "word word", "word word word", "word word word word"] {
            generationPartial(models, text: text); try await eventually { clock.pendingSleeperCount > 0 }; clock.advance(by: 100)
            try await eventually { try await generationLive(opened)?.generation?.message?["content"]?[0]?["text"] == .string(text) }
        }
        generationFinal(models); _ = try await input.wait(context: .background)
        let partials = log.commits.filter { ops in ops.contains { op in let path = op.json[1]?.arrayValue ?? []; return path.count >= 2 && path[0] == "generation" && path[1] == "message" } }
        #expect(partials.count == 4); #expect(partials[0].count == 1 && partials[0][0].json[1] == ["generation", "message"] && partials[0][0].json[0] == "s")
        for ops in partials.dropFirst() { #expect(ops == [.append(["generation", "message", "content", 0, "text"], " word")]) }
        subscription.cancel(); try await opened.harness.close(context: .background)
    }

    @Test func storageWritesBaseExactlyWhenNoGenerationOrRunningTool() async throws {
        let storage = ControlledStorage(), setup = HarnessChatSetup(settings: .init(toolExecution: .sequential)), log = HarnessLiveDeltaLog()
        for name in ["first", "second"] { try installHarnessTool(harnessTestTool(name, execute: { _, api, context in try api.output(.text("\(name) output\n"), nil); try await api.details(["n": 1], context); return .init(content: []) }), setup: setup) }
        setup.models.setResponses([.message(try toolCalls([("first", [:], "a"), ("second", [:], "b")])), .message(chatAssistant("done"))])
        let opened = try await openChat(storage: storage, setup: setup), listener = try opened.harness.subscribeCommits { publication, _ in log.append(publication) }
        let doc = try #require(await storage.findDocument(.init(kind: "pi.live", scope: .conversation(conversationId: opened.root.id)), at: .current, context: .background))
        let input = try await generationSubmit(opened); _ = try await input.wait(context: .background)
        let contents = await storage.commits.flatMap { writes in writes.compactMap { write -> DocumentContent? in if case .documentChange(let id, let content, _) = write, id == doc.id { content } else { nil } } }
        #expect(contents.count == log.values.count)
        var bases = 0, deltas = 0
        for (content, publication) in zip(contents, log.values) {
            let state = try JSONValue.object(publication.2).decode(LiveState.self), noRunning = state.generation == nil && !(state.tools ?? []).contains { $0.status == .running }
            if case .base = content { bases += 1; #expect(noRunning) } else { deltas += 1; #expect(!noRunning) }
        }
        #expect(bases >= 5 && deltas > 0)
        listener.cancel(); try await opened.harness.close(context: .background)
    }

    @Test func unofferedCallsStartDoneFaultedSlotOnlyWritesStatus() async throws {
        let setup = HarnessChatSetup(); try installHarnessTool(harnessTestTool("bad", execute: { _, _, _ in var usage = Usage(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0); usage.cost.total = .nan; return .init(content: [], usage: usage) }), setup: setup)
        setup.models.setResponses([.message(try toolCalls([("ghost", [:], "g"), ("bad", [:], "b")])), .message(chatAssistant("done"))])
        let opened = try await openChat(setup: setup), log = HarnessLiveDeltaLog(), listener = try opened.harness.subscribeCommits { publication, _ in log.append(publication) }
        let input = try await generationSubmit(opened); _ = try await input.wait(context: .background)
        let handover = try #require(log.commits.first { $0.contains { $0.json[0] == "s" && $0.json[1] == ["tools"] } })
        let slots = try #require(handover.first { $0.json[1] == ["tools"] }?.json[2]?.arrayValue)
        #expect(slots[0]["callId"] == "g" && slots[0]["status"] == "done" && slots[0]["entry"] != nil && slots[0]["taskId"] == nil)
        #expect(slots[1]["status"] == "pending" && slots[1]["taskId"] != nil)
        #expect(log.commits.contains([.set(["tools", 1, "status"], "done")]))
        listener.cancel(); try await opened.harness.close(context: .background)
    }

    @Test func answerToolsGenerationWaitAndLiveRoundShareOneCommit() async throws {
        let setup = HarnessChatSetup(); try installHarnessTool(harnessTestTool("noop"), setup: setup)
        setup.models.setResponses([.message(try toolCalls([("noop", [:], "a"), ("noop", [:], "b")])), .message(chatAssistant("done"))])
        let opened = try await openChat(setup: setup), log = HarnessLiveDeltaLog(), listener = try opened.harness.subscribeCommits { publication, _ in log.append(publication) }
        let input = try await generationSubmit(opened); _ = try await input.wait(context: .background)
        let publication = try #require(log.values.first { $0.2["tools"]?.arrayValue?.count == 2 }?.0)
        let kinds = publication.changes.compactMap { change -> String? in switch change { case .entry(let value): value.kind; case .task(let value): value.kind; default: nil } }
        #expect(kinds.sorted() == ["pi.assistant", "pi.generation", "pi.tool", "pi.tool"])
        listener.cancel(); try await opened.harness.close(context: .background)
    }

    @Test func abortedToolSlotUsesFourLiteralFieldOps() async throws {
        let run = try await HarnessLiveDeltaDriver.open(); _ = try await run.output("partial\n"); _ = try await run.step { api, context in try await api.details(["n": 1], context) }
        let task = try #require(await generationLive(run.opened)?.tools?.first?.taskId), before = run.log.commits.count
        _ = try await run.opened.harness.abortTask(id: task, context: .background)
        try await eventually { run.log.commits.dropFirst(before).contains { $0.contains(.set(["tools", 0, "status"], "done")) } }
        let aborted = try #require(run.log.commits.dropFirst(before).first { $0.contains(.set(["tools", 0, "status"], "done")) })
        #expect(aborted.count == 4 && aborted.contains(.delete(liveDeltaOutputPath)) && aborted.contains(.delete(["tools", 0, "details"])) && aborted.contains { $0.json[0] == "s" && $0.json[1] == ["tools", 0, "entry"] && $0.json[2]?.intValue != nil })
        _ = try await run.input.wait(context: .background); try await run.close()
    }

    @Test func completeBasePredicateDependsOnlyOnGenerationAndRunningTools() throws {
        let definition = LiveDoc.definition, run = LiveRun(taskId: try TaskID(1), inputs: [])
        let cases: [(LiveState, Bool)] = [(.init(), true), (.init(run: run, generation: .init(attempt: 1)), false), (.init(run: run, tools: [.init(callId: "c", name: "n", status: .pending), .init(callId: "d", name: "n", status: .done)]), true), (.init(run: run, tools: [.init(callId: "c", name: "n", status: .done), .init(callId: "d", name: "n", status: .running)]), false), (.init(run: run), true)]
        for (value, expected) in cases { #expect(try definition.checkpointWhen!(JSONValue(encoding: value).objectValue!, [], .init(deltasSinceBase: 1000)) == expected) }
    }
}
