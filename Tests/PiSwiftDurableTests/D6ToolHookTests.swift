import Foundation
import Synchronization
import Testing
import PiSwiftAI
import PiSwiftChord
@testable import PiSwiftDurable
import PiSwiftDurableTesting

@Suite("PiSwiftDurableTests.D6ToolHooks", .timeLimit(.minutes(1)))
struct D6ToolHookTests {
    // v1.5.2 tool.ts:153–206,232–268 and harness-restart-failure.test.ts:367.
    // Each row crosses a durable checkpoint with one forced restart.
    @Test(.timeLimit(.minutes(1)), arguments: ["call", "execute-safe", "execute-unsafe", "execute-limit", "execute-past-limit"])
    func toolPhaseRestartMatrix(mode: String) async throws {
        let directory = try sqliteTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("tool-phase.sqlite").path
        let setup = HarnessChatSetup(settings: .init(restartLimit: mode.contains("limit") ? 1 : 2))
        let reached = HarnessChatSignal(), before = Mutex(0), runs = Mutex(0), after = Mutex<[String?]>([])
        let replay: ToolReplay = mode == "execute-unsafe" ? .unsafe : .safe
        let tool = try ToolRegistration(name: "work", description: "work", parameters: ["type": "object", "properties": [:]],
            replay: replay, execute: { _, _, context in
                let count = runs.withLock { $0 += 1; return $0 }
                if mode != "call" && count == 1 { reached.signal(); try await harnessToolAwaitAbort(context) }
                return .init(output: [.text(.init(text: "ran \(count)"))])
            })
        try setup.registry.install(Extension(name: "D6 restart tool", tools: [tool]))
        try setup.registry.install(Extension(name: "D6 restart hook", hooks: [hook(ToolHooks(
            beforeTool: { _, _, context in
                let count = before.withLock { $0 += 1; return $0 }
                if mode == "call" && count == 1 { reached.signal(); try await harnessToolAwaitAbort(context) }
                return nil
            }, afterTool: { _, result, _, _ in
                after.withLock { $0.append(result.diagnostics?.last?.code) }
                return nil
            }))]))
        setup.models.setResponses([.message(try toolCalls([("work", [:], "c1")])), .message(chatAssistant("done"))])
        let first = try await openChat(storage: SqliteStorage.open(path: path), setup: setup)
        let submission = try await first.root.submit(.input(content: .text("go")), context: .background)
        await reached.wait()
        let toolID = try #require(try await first.harness.snapshot(LiveDoc, conversationId: first.root.id, context: .background)?.tools?.first?.taskId)
        let beforeClose = try #require(await first.harness.getTask(id: toolID, context: .background))
        #expect(beforeClose.state.checkpoint?["phase"] == (mode == "call" ? "call" : "execute"))
        try await first.harness.close(context: .background)
        // A clean close can leave a pending phase uncharged. Seed one charged host death
        // to cover the checkpoint×restart decision itself (tool.ts:153–206).
        let seed = try await SqliteStorage.open(path: path)
        let saved = try #require(await seed.task(toolID, context: .background))
        _ = try await seed.commit([.task(value: saved.replacing(restarts: .some(mode == "execute-past-limit" ? 2 : 1)))], context: .background)
        try await seed.close(context: .background)
        let second = try await openChat(storage: SqliteStorage.open(path: path), setup: setup)
        try second.harness.resume()
        let settled = try #require(await second.harness.submission(id: submission.id, context: .background))
        #expect(try await settled.wait(context: .background).status == "done")
        let outcome = try #require(await second.harness.getTask(id: toolID, context: .background))
        let result = try #require(harnessToolResults(await allEntries(second.root)).first)
        switch mode {
        case "call":
            #expect(before.withLock { $0 } == 2 && runs.withLock { $0 } == 1)
            #expect(outcome.state.status == "terminal" && !result.isError)
        case "execute-safe":
            #expect(runs.withLock { $0 } == 2 && !result.isError)
        case "execute-unsafe":
            #expect(runs.withLock { $0 } == 1 && result.isError)
            #expect(harnessToolText(result).contains("was interrupted and may have partially run"))
        default:
            #expect(runs.withLock { $0 } == 1 && result.isError)
            #expect(harnessToolText(result).contains(mode == "execute-past-limit"
                ? "was interrupted 2 times in a row; it is not run again"
                : "was interrupted once; it is not run again"))
            #expect(after.withLock { $0.count } == (mode == "execute-past-limit" ? 0 : 1))
            if case .terminal(.failed(let error, _, _), _) = outcome.state { #expect(error.detail?["reason"] == "restart_limit") }
            else { Issue.record("Restart limit did not end with an error result") }
        }
        try await second.harness.close(context: .background)
    }

    // v1.5.2 harness-tool-hooks.test.ts:260,313.
    @Test func nestedInvalidAndBlockedResultsPassThroughAfterTool() async throws {
        let setup = HarnessChatSetup()
        let seen = Mutex<[String: String?]>([:]), captured = Mutex<[NestedToolExecutionResult]>([])
        try installHarnessTool(harnessTestTool(execute: { _, _, _ in Issue.record("Rejected nested tool ran"); return .init() }), setup: setup)
        try setup.registry.install(Extension(name: "D6 nested hook", hooks: [hook(ToolHooks(
            beforeTool: { call, _, _ in call.parent != nil && call.id.hasSuffix("/block") ? .init(block: "closed") : nil },
            afterTool: { call, result, _, _ in
                guard call.parent != nil else { return nil }
                seen.withLock { $0[call.id] = result.diagnostics?.first?.code }
                var changed = result
                changed.output = [.text(.init(text: "nested \(call.id)"))]
                changed.details = ["hook": true]
                return changed
            }))]))
        try installHarnessTool(harnessTestTool("parent", execute: { _, api, context in
            let invalid = try await api.executeTool("echo", arguments: ["text": ["bad": true]], context: context, options: .init(key: "invalid"))
            let blocked = try await api.executeTool("echo", arguments: [:], context: context, options: .init(key: "block"))
            captured.withLock { $0 = [invalid, blocked] }
            return .init(output: [])
        }), setup: setup)
        let (opened, _) = try await runHarnessTools(setup, calls: [("parent", [:], "p")])
        let values = captured.withLock { $0 }
        #expect(values.count == 2)
        #expect(values.map { $0.diagnostics.first?.code } == ["invalid_arguments", "blocked"])
        #expect(values.allSatisfy { $0.isError && $0.structuredOutput == nil && $0.details == ["hook": true] })
        #expect(seen.withLock { $0["p/invalid"] } == "invalid_arguments")
        #expect(seen.withLock { $0["p/block"] } == "blocked")
        try await opened.harness.close(context: .background)
    }

    // v1.5.2 harness-tool-hooks.test.ts:313.
    @Test func nestedBlockedResultChangedToSuccessGetsOutputValueUnlessSchemaExists() async throws {
        let setup = HarnessChatSetup(), captured = Mutex<[NestedToolExecutionResult]>([])
        let parameters: JSONObject = ["type": "object"]
        try setup.registry.install(Extension(name: "D6 plain", tools: [
            try ToolRegistration(name: "plain", description: "plain", parameters: parameters) { _, _, _ in .init(output: []) },
            try ToolRegistration(name: "typed", description: "typed", parameters: parameters,
                structuredOutputSchema: ["type": "object", "properties": ["ok": ["type": "boolean"]]]) { _, _, _ in .init(output: []) }
        ]))
        try installHarnessTool(harnessTestTool("parent", execute: { _, api, context in
            let plain = try await api.executeTool("plain", arguments: [:], context: context)
            let typed = try await api.executeTool("typed", arguments: [:], context: context)
            captured.withLock { $0 = [plain, typed] }
            return .init(output: [])
        }), setup: setup)
        try setup.registry.install(Extension(name: "D6 success hook", hooks: [hook(ToolHooks(
            beforeTool: { call, _, _ in call.parent == nil ? nil : .init(block: "no") },
            afterTool: { call, _, _, _ in
                guard call.parent != nil else { return nil }
                return .init(output: [.text(.init(text: "fine \(call.name)"))], structuredOutput: ["ok": false])
            }))]))
        let (opened, _) = try await runHarnessTools(setup, calls: [("parent", [:], "p")])
        let values = captured.withLock { $0 }
        #expect(values.count == 2)
        #expect(!values[0].isError && values[0].structuredOutput == "fine plain")
        #expect(!values[1].isError && values[1].structuredOutput == nil)
        try await opened.harness.close(context: .background)
    }

    // v1.5.2 harness-tool-hooks.test.ts:137,633,704.
    @Test func afterToolReplacesUnavailableInvalidAndBlockedResults() async throws {
        let setup = HarnessChatSetup()
        let observed = Mutex<[String: (String?, JSONObject)]>([:])
        try installHarnessTool(harnessTestTool(execute: { _, _, _ in
            Issue.record("Rejected tool must not execute")
            return .init(output: [])
        }), setup: setup)
        try setup.registry.install(Extension(name: "D6 result hooks", hooks: [hook(ToolHooks(
            beforeTool: { call, _, _ in
                if call.id == "blocked" { return .init(block: "not today") }
                return nil
            },
            afterTool: { call, result, _, _ in
                let args = try #require(durableJSON(fromFoundation: call.arguments.mapValues(\.value)).objectValue)
                observed.withLock { $0[call.id] = (result.diagnostics?.first?.code, args) }
                var changed = result
                changed.output = [.text(TextContent(text: "hooked \(call.id)"))]
                changed.details = ["by": "hook"]
                return changed
            }))]))
        let (opened, entries) = try await runHarnessTools(setup, calls: [
            ("ghost", [:], "unoffered"),
            ("echo", ["text": ["wrong": true]], "invalid"),
            ("echo", ["text": "ok"], "blocked")
        ])
        let byID = Dictionary(uniqueKeysWithValues: try harnessToolResults(entries).map { ($0.toolCallId, $0) })
        for (id, code) in [("unoffered", "tool_unavailable"), ("invalid", "invalid_arguments"), ("blocked", "blocked")] {
            let result = try #require(byID[id])
            #expect(result.isError)
            #expect(harnessToolText(result).hasPrefix("hooked \(id)|<harness>"))
            #expect(harnessToolDetails(result) == ["by": "hook"])
            #expect(observed.withLock { $0[id]?.0 } == code)
        }
        #expect(observed.withLock { $0["invalid"]?.1["text"] } == ["wrong": true])
        let tasks = try await opened.harness.commit({ tx in try await tx.scanTasks(.init(conversationId: opened.root.id), limit: 20) }, context: .background)
        let tools = tasks.items.filter { $0.kind == "pi.tool" }
        #expect(tools.count == 3)
        #expect(tools.first { $0.input["callId"] == "unoffered" }?.input["unoffered"] == true)
        try await opened.harness.close(context: .background)
    }

    // v1.5.2 harness-tool-hooks.test.ts:657,675.
    @Test func sequentialUnofferedCallRunsHookAndLastHandoffWins() async throws {
        let setup = HarnessChatSetup(settings: .init(toolExecution: .sequential))
        let order = Mutex<[String]>([])
        for name in ["a", "b"] {
            try installHarnessTool(harnessTestTool(name, execute: { _, _, _ in
                order.withLock { $0.append(name) }
                return .init(output: [])
            }), setup: setup)
        }
        try setup.registry.install(Extension(name: "D6 handoff hook", hooks: [hook(ToolHooks(afterTool: { call, result, _, _ in
            order.withLock { $0.append("hook \(call.id)") }
            var changed = result
            if call.id != "c1" { changed.control = .init(handoff: "from \(call.id)") }
            return changed
        }))]))
        let (opened, entries) = try await runHarnessTools(setup, calls: [("a", [:], "c1"), ("ghost", [:], "c2"), ("b", [:], "c3")])
        #expect(order.withLock { $0 } == ["a", "hook c1", "hook c2", "b", "hook c3"])
        let resets = try entries.filter { $0.kind == resetEntry.kind }.flatMap { try $0.messages() ?? [] }
        #expect(resets.count == 1)
        if case .user(let message) = resets[0], case .text(let text) = message.content { #expect(text == "from c3") }
        else { Issue.record("Handoff did not create a user reset") }
        try await opened.harness.close(context: .background)
    }

    // v1.5.2 harness-tool-hooks.test.ts:726: generation v1 and v2 keep the pending slot's flag.
    @Test(.timeLimit(.minutes(1)), arguments: [1.0, 2.0])
    func migratedSequentialRoundKeepsPendingUnofferedFlag(version: Double) async throws {
        let directory = try sqliteTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("pending-migration.sqlite").path
        let setup = HarnessChatSetup(settings: .init(toolExecution: .sequential)), started = HarnessChatSignal()
        let observed = Mutex<[String]>([])
        try installHarnessTool(harnessTestTool("first", execute: { _, api, context in
            try api.output(.text("first partial"), nil)
            try await api.details(["step": 1], context)
            started.signal(); try await harnessToolAwaitAbort(context)
            return .init()
        }), setup: setup)
        try setup.registry.install(Extension(name: "D6 pending migration hook", hooks: [hook(ToolHooks(afterTool: { call, _, _, _ in
            observed.withLock { $0.append(call.id) }
            return nil
        }))]))
        setup.models.setResponses([.message(try toolCalls([("first", [:], "c1"), ("ghost", [:], "c2")])), .message(chatAssistant("done"))])
        let first = try await openChat(storage: SqliteStorage.open(path: path), setup: setup)
        let submission = try await first.root.submit(.input(content: .text("go")), context: .background)
        await started.wait()
        let live = try #require(try await first.harness.snapshot(LiveDoc, conversationId: first.root.id, context: .background))
        let generationID = try #require(live.run?.taskId)
        #expect(live.tools?[1].unoffered == true && live.tools?[1].taskId == nil)
        try await first.harness.close(context: .background)
        let seed = try await SqliteStorage.open(path: path)
        let generation = try #require(await seed.task(generationID, context: .background))
        #expect(generation.state.checkpoint?["pending"] == ["c2"])
        _ = try await seed.commit([.task(value: generation.replacing(version: version))], context: .background)
        try await seed.close(context: .background)
        let second = try await openChat(storage: SqliteStorage.open(path: path), setup: setup)
        try second.harness.resume()
        let restored = try #require(await second.harness.submission(id: submission.id, context: .background))
        #expect(try await restored.wait(context: .background).status == "done")
        let tasks = try await d4bToolTasks(second.harness)
        #expect(tasks.count == 2)
        #expect(tasks.first { $0.input["callId"] == "c2" }?.input["unoffered"] == true)
        #expect(observed.withLock { $0.contains("c2") })
        try await second.harness.close(context: .background)
    }

    // v1.5.2 harness-tool-hooks.test.ts:200.
    @Test func replacementOutputUsesResolvedLimits() async throws {
        let setup = HarnessChatSetup()
        try installHarnessTool(harnessTestTool(limits: .init(maxBytes: 5)), setup: setup)
        try setup.registry.install(Extension(name: "D6 bounds hook", hooks: [hook(ToolHooks(afterTool: { _, result, _, _ in
            var changed = result
            changed.output = [.text(TextContent(text: "abcdefghij"))]
            return changed
        }))]))
        let (opened, entries) = try await runHarnessTools(setup, calls: [("echo", ["text": ["bad": true]], "invalid")])
        let result = try #require(harnessToolResults(entries).first)
        #expect(harnessToolText(result).hasPrefix("abcde|<harness>"))
        let resultEntry = try #require(entries.first { $0.kind == toolResultEntry.kind })
        #expect(resultEntry.data?["diagnostics"]?.arrayValue?.compactMap { $0["code"]?.stringValue } == ["invalid_arguments", "truncated"])
        try await opened.harness.close(context: .background)
    }

    // v1.5.2 harness-tool-hooks.test.ts:413,508.
    @Test(arguments: ["replace", "throw"]) func abortResultPassesThroughAfterToolWithHeldOutput(mode: String) async throws {
        // v1.5.2 D7 harness-tool-hooks.test.ts:508-537: output stays in memory until the result stores it.
        let setup = HarnessChatSetup(settings: .init(progress: .init(outputIntervalMs: 0, persistWithinMs: 60_000)))
        let started = HarnessChatSignal(), storage = ControlledStorage()
        let observed = Mutex<String?>(nil)
        try installHarnessTool(harnessTestTool(execute: { _, api, context in
            try api.output(.text("partial"), nil)
            try await api.details(["step": 1], context)
            started.signal()
            try await harnessToolAwaitAbort(context)
            return .init()
        }), setup: setup)
        try setup.registry.install(Extension(name: "D6 abort hook", hooks: [hook(ToolHooks(afterTool: { _, result, _, _ in
            observed.withLock { $0 = result.diagnostics?.last?.code }
            if mode == "throw" { throw TaskDefinitionError("abort hook threw") }
            var changed = result
            changed.output = [.text(.init(text: "hooked abort"))]
            return changed
        }))]))
        setup.models.setResponses([.message(try toolCalls([("echo", [:], "c1")])), .message(chatAssistant("done"))])
        let opened = try await openChat(storage: storage, setup: setup)
        let submission = try await opened.root.submit(.input(content: .text("go")), context: .background)
        await started.wait()
        let memory = try #require(try await opened.harness.snapshot(LiveDoc, conversationId: opened.root.id, context: .background))
        #expect(memory.tools?.first?.output == "partial")
        let record = try #require(try await storage.findDocument(
            .init(kind: LiveDoc.definition.kind, scope: .conversation(conversationId: opened.root.id)), at: .current, context: .background))
        let stored = try #require(try await storage.document(record.id, at: .current, context: .background))
        #expect(stored.value["tools"]?.arrayValue?.first?["output"] != .string("partial"))
        let id = try #require(memory.tools?.first?.taskId)
        #expect(try await opened.harness.abortTask(id: id, context: .background) == .marked)
        _ = try await opened.harness.waitForTask(id: id, context: .background)
        #expect(try await submission.wait(context: .background).status == "done")
        #expect(observed.withLock { $0 } == "aborted")
        let result = try #require(harnessToolResults(await allEntries(opened.root)).first)
        #expect(harnessToolText(result).hasPrefix(mode == "throw" ? "partial|<harness>" : "hooked abort|<harness>"))
        if mode == "throw" {
            #expect(setup.reports.infos.contains { $0.kind == "extension_error" })
        }
        try await opened.harness.close(context: .background)
    }

    // v1.5.2 harness-tool-hooks.test.ts:413.
    @Test(arguments: ["second", "ghost"]) func abortRunsHookForStartedCallButNotSequentialPendingCall(pendingName: String) async throws {
        let setup = HarnessChatSetup(settings: .init(toolExecution: .sequential))
        let started = HarnessChatSignal(), seen = Mutex<[String: String?]>([:])
        try installHarnessTool(harnessTestTool("first", execute: { _, api, context in
            try api.output(.text("first partial"), nil)
            try await api.details(["step": 1], context)
            started.signal()
            try await harnessToolAwaitAbort(context)
            return .init()
        }), setup: setup)
        try installHarnessTool(harnessTestTool("second", execute: { _, _, _ in
            Issue.record("Pending tool started after abort")
            return .init()
        }), setup: setup)
        try setup.registry.install(Extension(name: "D6 abort pending hook", hooks: [hook(ToolHooks(afterTool: { call, result, _, _ in
            seen.withLock { $0[call.id] = result.diagnostics?.last?.code }
            var changed = result
            changed.details = ["hooked": true]
            return changed
        }))]))
        setup.models.setResponses([.message(try toolCalls([("first", [:], "c1"), (pendingName, [:], "c2")])), .message(chatAssistant("done"))])
        let opened = try await openChat(setup: setup)
        let submission = try await opened.root.submit(.input(content: .text("go")), context: .background)
        await started.wait()
        _ = try await opened.root.abort(context: .background)
        #expect(try await submission.wait(context: .background).status == "unanswered")
        let byID = Dictionary(uniqueKeysWithValues: try harnessToolResults(await allEntries(opened.root)).map { ($0.toolCallId, $0) })
        #expect(seen.withLock { $0.keys.sorted() } == ["c1"])
        #expect(harnessToolDetails(try #require(byID["c1"])) == ["hooked": true])
        #expect(harnessToolDetails(try #require(byID["c2"])) != ["hooked": true])
        let secondEntry = try #require(await allEntries(opened.root).first { $0.kind == toolResultEntry.kind && $0.model?.first?["toolCallId"] == "c2" })
        #expect(secondEntry.data?["diagnostics"]?[0]?["code"] == (pendingName == "ghost" ? "tool_unavailable" : "aborted"))
        try await opened.harness.close(context: .background)
    }

    // v1.5.2 harness-tool-hooks.test.ts:372.
    @Test(.timeLimit(.minutes(1))) func interruptedResultHookCanReplaceOutputAndDropSlotTruncation() async throws {
        let directory = try sqliteTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("interrupted-hook.sqlite").path
        let setup = HarnessChatSetup(), workStarted = HarnessChatSignal(), keepStarted = HarnessChatSignal()
        let seen = Mutex<[String: [String]]>([:])
        for (name, signal) in [("work", workStarted), ("keep", keepStarted)] {
            try installHarnessTool(harnessTestTool(name, limits: .init(maxBytes: 10, retain: .tail), execute: { _, api, context in
                try api.output(.text("0123456789abcdefghij"), nil)
                try await api.details(.object(["seen": .string(name)]), context)
                signal.signal()
                try await harnessToolAwaitAbort(context)
                return .init()
            }), setup: setup)
        }
        try setup.registry.install(Extension(name: "D6 interruption hook", hooks: [hook(ToolHooks(afterTool: { call, result, _, _ in
            seen.withLock { $0[call.id] = (result.diagnostics ?? []).compactMap(\.code) }
            guard call.name == "work" else { return nil }
            var changed = result
            changed.output = [.text(.init(text: "redacted"))]
            return changed
        }))]))
        setup.models.setResponses([.message(try toolCalls([("work", [:], "c1"), ("keep", [:], "c2")])), .message(chatAssistant("done"))])
        let first = try await openChat(storage: SqliteStorage.open(path: path), setup: setup)
        let submission = try await first.root.submit(.input(content: .text("go")), context: .background)
        await workStarted.wait(); await keepStarted.wait()
        try await first.harness.close(context: .background)
        let second = try await openChat(storage: SqliteStorage.open(path: path), setup: setup)
        try second.harness.resume()
        let restored = try #require(await second.harness.submission(id: submission.id, context: .background))
        #expect(try await restored.wait(context: .background).status == "done")
        let entries = try await allEntries(second.root)
        let byID = Dictionary(uniqueKeysWithValues: try harnessToolResults(entries).map { ($0.toolCallId, $0) })
        #expect(seen.withLock { $0 } == ["c1": ["interrupted"], "c2": ["interrupted"]])
        #expect(harnessToolText(try #require(byID["c1"])).hasPrefix("redacted|<harness>"))
        let codes = Dictionary(uniqueKeysWithValues: try entries.filter { $0.kind == toolResultEntry.kind }.map { entry in
            let result = try #require(entry.messages()?.first)
            guard case .toolResult(let value) = result else { throw TaskDefinitionError("Missing tool result") }
            return (value.toolCallId, try #require(entry.data?["diagnostics"]?.arrayValue).compactMap { $0["code"]?.stringValue })
        })
        #expect(codes["c1"] == ["interrupted"])
        #expect(codes["c2"] == ["interrupted", "truncated"])
        try await second.harness.close(context: .background)
    }

    // v1.5.2 harness-tool-hooks.test.ts:466.
    @Test(.timeLimit(.minutes(1))) func lastAbortHandlerAttemptSettlesWithoutHooks() async throws {
        let directory = try sqliteTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("abort-last-hook.sqlite").path
        let setup = HarnessChatSetup(settings: .init(restartLimit: 2)), started = HarnessChatSignal(), hooked = Mutex(0)
        try installHarnessTool(harnessTestTool(execute: { _, api, context in
            try api.output(.text("partial"), nil)
            try await api.details(["step": 1], context)
            started.signal(); try await harnessToolAwaitAbort(context)
            return .init()
        }), setup: setup)
        try setup.registry.install(Extension(name: "D6 last abort hook", hooks: [hook(ToolHooks(afterTool: { _, _, _, _ in
            hooked.withLock { $0 += 1 }; return nil
        }))]))
        setup.models.setResponses([.message(try toolCalls([("echo", [:], "c1")])), .message(chatAssistant("done"))])
        let first = try await openChat(storage: SqliteStorage.open(path: path), setup: setup)
        let submission = try await first.root.submit(.input(content: .text("go")), context: .background)
        await started.wait()
        let id = try #require(try await first.harness.snapshot(LiveDoc, conversationId: first.root.id, context: .background)?.tools?.first?.taskId)
        try await first.harness.close(context: .background)
        let seed = try await SqliteStorage.open(path: path)
        let saved = try #require(await seed.task(id, context: .background))
        _ = try await seed.commit([.task(value: saved.replacing(abortRequested: true, restarts: .some(1)))], context: .background)
        try await seed.close(context: .background)
        let second = try await openChat(storage: SqliteStorage.open(path: path), setup: setup)
        try second.harness.resume()
        let restored = try #require(await second.harness.submission(id: submission.id, context: .background))
        #expect(try await restored.wait(context: .background).status == "done")
        #expect(hooked.withLock { $0 } == 0)
        let result = try #require(harnessToolResults(await allEntries(second.root)).first)
        #expect(result.isError && harnessToolText(result).contains("Tool echo was aborted"))
        try await second.harness.close(context: .background)
    }

    // v1.5.2 harness-tool-hooks.test.ts:541.
    @Test(.timeLimit(.minutes(1))) func abandonedNestedCallRunsAfterToolOnItsErrorResult() async throws {
        let directory = try sqliteTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("nested-abandoned-hook.sqlite").path
        let setup = HarnessChatSetup(), reached = HarnessChatSignal(), gated = Mutex(true)
        let seen = Mutex<[(String, String?)]>([])
        try installHarnessTool(harnessTestTool("gated", execute: { _, _, _ in
            Issue.record("Gated nested tool ran")
            return .init()
        }), setup: setup)
        try installHarnessTool(harnessTestTool("parent", execute: { _, api, context in
            _ = try await api.executeTool("gated", arguments: [:], context: context)
            return .init(output: [])
        }), setup: setup)
        try setup.registry.install(Extension(name: "D6 abandoned nested hook", hooks: [hook(ToolHooks(
            beforeTool: { call, _, context in
                if call.parent != nil && call.name == "gated" && gated.withLock({ $0 }) {
                    reached.signal(); try await harnessToolAwaitAbort(context)
                }
                return nil
            }, afterTool: { call, result, _, _ in
                guard call.parent != nil else { return nil }
                seen.withLock { $0.append((call.id, result.diagnostics?.last?.code)) }
                var changed = result
                changed.details = ["hooked": true]
                return changed
            }))]))
        setup.models.setResponses([.message(try toolCalls([("parent", [:], "p")])), .message(chatAssistant("done"))])
        let first = try await openChat(storage: SqliteStorage.open(path: path), setup: setup)
        let submission = try await first.root.submit(.input(content: .text("go")), context: .background)
        await reached.wait()
        try await first.harness.close(context: .background)
        gated.withLock { $0 = false }
        let second = try await openChat(storage: SqliteStorage.open(path: path), setup: setup)
        try second.harness.resume()
        let restored = try #require(await second.harness.submission(id: submission.id, context: .background))
        #expect(try await restored.wait(context: .background).status == "done")
        #expect(seen.withLock { $0.map(\.0) } == ["p/1"])
        #expect(seen.withLock { $0.map(\.1) } == ["abandoned"])
        try await second.harness.close(context: .background)
    }

    // v1.5.2 harness-tool-hooks.test.ts:704.
    @Test func parallelUnofferedCallsEachGetTaskAndHook() async throws {
        let setup = HarnessChatSetup(), seen = Mutex<Set<String>>([])
        try setup.registry.install(Extension(name: "D6 unoffered hook", hooks: [hook(ToolHooks(afterTool: { call, _, _, _ in
            seen.withLock { _ = $0.insert(call.id) }
            return nil
        }))]))
        let (opened, entries) = try await runHarnessTools(setup, calls: [("ghost", [:], "c1"), ("spirit", [:], "c2"), ("ghost", [:], "c3")])
        #expect(seen.withLock { $0 } == Set(["c1", "c2", "c3"]))
        #expect(try harnessToolResults(entries).count == 3)
        let tasks = try await d4bToolTasks(opened.harness)
        #expect(tasks.count == 3 && tasks.allSatisfy { $0.input["unoffered"] == true })
        try await opened.harness.close(context: .background)
    }

    // v1.5.2 harness-tool-hooks.test.ts:240,657.
    @Test func hookTerminationOnBlockedAndUnofferedCallsEndsRound() async throws {
        let setup = HarnessChatSetup()
        try installHarnessTool(harnessTestTool(), setup: setup)
        try setup.registry.install(Extension(name: "D6 terminate hook", hooks: [hook(ToolHooks(
            beforeTool: { call, _, _ in call.name == "echo" ? .init(block: "no") : nil },
            afterTool: { _, result, _, _ in
                var changed = result
                changed.control = .init(terminate: true)
                return changed
            }))]))
        setup.models.setResponses([.message(try toolCalls([("echo", [:], "c1"), ("ghost", [:], "c2")])), .message(chatAssistant("should not request"))])
        let opened = try await openChat(setup: setup)
        let settled = try await opened.root.submit(.input(content: .text("go")), context: .background).wait(context: .background)
        #expect(settled.status == "done" && setup.models.state().callCount == 1)
        let entries = try await allEntries(opened.root)
        #expect(try harnessToolResults(entries).count == 2)
        try await opened.harness.close(context: .background)
    }
}
