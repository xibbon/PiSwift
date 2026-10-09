import Foundation
import Testing
import Synchronization
import PiSwiftAI
import PiSwiftChord
@testable import PiSwiftDurable
import PiSwiftDurableTesting

struct HarnessToolTests {
    // Upstream harness-tools.test.ts:82,115,138.
    @Test func roundResultsAndModels() async throws {
        let setup = HarnessChatSetup(), seen = Mutex(0)
        try installHarnessTool(harnessTestTool(execute: { args, api, _ in
            #expect((api.models as? FakeDurableModels) === setup.models); seen.withLock { $0 += 1 }
            return ToolExecutionResult(content: [.text(TextContent(text: "echo hi"))])
        }), setup: setup)
        try setup.registry.install(Extension(name: "audit", hooks: [hook(ToolHooks(beforeTool: { _, api, _ in
            #expect((api.models as? FakeDurableModels) === setup.models); seen.withLock { $0 += 1 }; return nil
        }))]))
        let (opened, entries) = try await runHarnessTools(setup, calls: [("ghost", [:], "ghost"), ("echo", ["text": "hi"], "echo")])
        let results = try harnessToolResults(entries)
        #expect(results.count == 2 && seen.withLock { $0 } == 2)
        #expect(results.first { $0.toolCallId == "ghost" }?.isError == true)
        #expect(harnessToolText(try #require(results.first { $0.toolCallId == "echo" })) == "echo hi")
        #expect(entries.map(\.kind) == ["pi.user", "pi.system", "pi.assistant", "pi.tool-result", "pi.tool-result", "pi.assistant"])
        let system = try #require(entries.first { $0.kind == systemEntry.kind })
        let offered = try await opened.root.agent(context: .background).tools[0].currentOrderedDeclaration()
        #expect(system.model?.first?["toolsAdded"] == .array([.object(offered)]))
        let ghostEntry = try #require(entries.first { $0.kind == toolResultEntry.kind && $0.model?.first?["toolCallId"] == "ghost" })
        #expect(ghostEntry.byTaskId == entries.first { $0.kind == assistantEntry.kind }?.byTaskId)
        #expect(ghostEntry.data == ["diagnostics": [["severity": "error", "code": "tool_unavailable", "message": "Tool ghost is not available"]]])
        #expect(harnessToolText(try #require(results.first { $0.toolCallId == "ghost" })) == "<harness>\n[error] Tool ghost is not available\n</harness>")
        let echoEntry = try #require(entries.first { $0.kind == toolResultEntry.kind && $0.model?.first?["toolCallId"] == "echo" })
        #expect(echoEntry.data == ["diagnostics": []] && echoEntry.byTaskId != nil)
        let tasks = try await opened.harness.commit({ tx in try await tx.scanTasks(.init(conversationId: opened.root.id), limit: 20) }, context: .background)
        #expect(tasks.items.filter { $0.kind == "pi.tool" }.count == 1)
        #expect(setup.models.state().callCount == 2)
        #expect(entries.filter { $0.kind == toolResultEntry.kind }.allSatisfy { $0.byTaskId != nil || $0.data?["diagnostics"]?[0]?["code"] == "tool_unavailable" })
        #expect(try await opened.harness.snapshot(LiveDoc, conversationId: opened.root.id, context: .background) == LiveState())
        try await opened.harness.close(context: .background)
    }
    // :162,188,213.
    @Test(arguments: ["deactivate", "unregister", "late"]) func unavailableAtExecution(change: String) async throws {
        let setup = HarnessChatSetup(), ran = Mutex(0)
        try installHarnessTool(harnessTestTool(execute: { _, _, _ in ran.withLock { $0 += 1 }; return .init(content: []) }), setup: setup)
        if change == "late" {
            try installHarnessTool(harnessTestTool("first", mode: .sequential, execute: { _, _, _ in
                setup.registry.uninstall(name: "tool:echo"); return .init(content: [])
            }), setup: setup)
            let (opened, entries) = try await runHarnessTools(setup, calls: [("first", [:], "first"), ("echo", [:], "echo")])
            #expect(ran.withLock { $0 } == 0)
            #expect(harnessToolText(try #require(harnessToolResults(entries).last)) == "<harness>\n[error] Tool echo is not available\n</harness>")
            try await opened.harness.close(context: .background)
            return
        }
        let opened = try await openChat(setup: setup)
        setup.models.setResponses([.factory { _, _, _, _ in
            if change == "deactivate" { try await opened.root.configure(change: .init(tools: .set(.exact([]))), context: .background) }
            else { setup.registry.uninstall(name: "tool:echo") }
            return try toolCalls([("echo", [:], "echo")])
        }, .message(chatAssistant("done"))])
        _ = try await opened.root.submit(.input(content: .text("go")), context: .background).wait(context: .background)
        #expect(ran.withLock { $0 } == 0)
        let unavailableEntries = try await allEntries(opened.root)
        #expect(harnessToolText(try #require(harnessToolResults(unavailableEntries).first)) == "<harness>\n[error] Tool echo is not available\n</harness>")
        #expect(unavailableEntries.last { $0.kind == systemEntry.kind }?.model?.first?["toolsRemoved"] == [["name": "echo"]])
        if change == "unregister" {
            try installHarnessTool(harnessTestTool(), setup: setup)
            setup.models.setResponses([.message(chatAssistant("back"))])
            _ = try await opened.root.submit(.input(content: .text("back")), context: .background).wait(context: .background)
            #expect(try await opened.root.agent(context: .background).tools.map(\.name) == ["echo"])
            let back = try await allEntries(opened.root)
            #expect(back.last { $0.kind == systemEntry.kind }?.model?.first?["toolsAdded"]?[0]?["name"] == "echo")
        }
        try await opened.harness.close(context: .background)
    }
    // :238,263. Gates prove overlap without a wall-clock threshold.
    @Test(arguments: ["parallel", "setting", "tool"]) func executionOrder(mode: String) async throws {
        let setup = HarnessChatSetup(), events = Mutex<[String]>([]), firstStarted = HarnessChatSignal(), release = HarnessChatSignal()
        // The setting changes while the model request runs, before the round starts.
        for name in ["a", "b"] {
            try installHarnessTool(harnessTestTool(name, mode: mode == "tool" && name == "a" ? .sequential : nil, execute: { _, _, _ in
                events.withLock { $0.append("start \(name)") }
                if name == "a" { firstStarted.signal(); await release.wait() }
                events.withLock { $0.append("end \(name)") }; return .init(content: [])
            }), setup: setup)
        }
        setup.models.setResponses([.factory { _, _, _, _ in
            if mode == "setting" { setup.updateSettings { $0.toolExecution = .sequential } }
            return try toolCalls([("a", [:], "a"), ("b", [:], "b")])
        }, .message(chatAssistant("done"))])
        let opened = try await openChat(setup: setup), submission = try await opened.root.submit(.input(content: .text("go")), context: .background)
        await firstStarted.wait()
        setup.updateSettings { $0.toolExecution = .parallel }
        if mode == "parallel" { try await eventually { events.withLock { $0.contains("start b") } } }
        else { #expect(events.withLock { $0 } == ["start a"]) }
        release.signal()
        #expect(try await submission.wait(context: .background).status == "done")
        if mode != "parallel" { #expect(events.withLock { $0 } == ["start a", "end a", "start b", "end b"]) }
        let tasks = try await opened.harness.commit({ tx in try await tx.scanTasks(.init(conversationId: opened.root.id), limit: 20) }, context: .background)
        let tools = tasks.items.filter { $0.kind == "pi.tool" }
        let generation = try #require(tasks.items.first { $0.kind == "pi.generation" && tools.first?.owner == $0.id })
        #expect(tools.count == 2 && tools.allSatisfy { $0.owner == generation.id })
        try await opened.harness.close(context: .background)
    }
    // :320,352,414,939,959,1000,1014.
    @Test(arguments: ["retained", "tail", "throw", "default", "sanitize", "null", "coalesce", "coalesceInvocation"]) func outputAndDetails(mode: String) async throws {
        let setup = HarnessChatSetup(settings: .init(progress: .init(outputIntervalMs: 250)), clock: mode.hasPrefix("coalesce") ? TestClock() : SystemDurableClock())
        let limits: OutputLimitOverrides? = mode == "retained" ? .init(maxLines: 2) : mode == "tail" ? .init(maxLines: 1, retain: .tail) : nil
        let settled = Mutex<[Int]>([]), pending = Mutex<[Task<Void, any Error>]>([])
        try installHarnessTool(harnessTestTool(limits: limits, execute: { _, api, context in
            switch mode {
            case "retained":
                try api.output(.text("line 1\n"), nil); try api.output(.bytes(Data("line 2\nline 3\n".utf8)), nil)
                try api.diagnostic(.init(severity: .info, message: "from api"))
                try await api.details(["step": 1], context); try await api.details(["step": 2], context)
                return .init(diagnostics: [.init(severity: .warn, message: "from result")])
            case "tail":
                #expect(api.outputWindow == ShellOutputWindow(maxBytes: 50 * 1024, maxLines: 1, minIntervalMs: 250, bytesPerSecond: 100 * 1024))
                try api.output(.text("dropped\n"), nil); try api.output(.text("x\ny\n"), .init(bytes: 8, newlines: 1, endsWithNewline: true)); return .init()
            case "throw": try api.output(.text("partial\n"), nil); throw TaskDefinitionError("boom")
            case "default": for index in 1...2500 { try api.output(.text("\(index)\n"), nil) }; return .init()
            case "sanitize":
                try api.output(.text("a\u{7}b\r\n"), nil); try await api.details(["ready": true], context)
                #expect(try await api.snapshot(LiveDoc, conversationId: api.conversationId, context: context)?.tools?.first?.output == "ab\n")
                return .init()
            case "null": try await api.details(["old": 1], context); return .init(content: [], details: .null)
            default:
                let detailsContext: ChordContext = mode == "coalesceInvocation" ? context : .background
                let first = Task { try await api.details(["n": 1], detailsContext); settled.withLock { $0.append(1) } }
                try await first.value
                let second = Task { try await api.details(["n": 2], detailsContext); settled.withLock { $0.append(2) } }
                try await eventually { api.pendingDetailsCount() == 1 }
                let third = Task { try await api.details(["n": 3], detailsContext); settled.withLock { $0.append(3) } }
                try await eventually { api.pendingDetailsCount() == 2 }
                pending.withLock { $0 = [second, third] }
                return .init(content: [])
            }
        }), setup: setup)
        if mode == "tail" {
            try installHarnessTool(harnessTestTool("headed", limits: .init(maxLines: 1), execute: { _, api, _ in
                #expect(api.outputWindow == nil); return .init()
            }), setup: setup)
        }
        let (opened, entries) = try await runHarnessTools(setup, calls: mode == "tail" ? [("echo", [:], "c1"), ("headed", [:], "c2")] : [("echo", [:], "c1")])
        let result = try #require(harnessToolResults(entries).first { $0.toolCallId == "c1" }), text = harnessToolText(result)
        for task in pending.withLock({ $0 }) { try await task.value }
        switch mode {
        case "retained":
            let codes = entries.first { $0.kind == toolResultEntry.kind }?.data?["diagnostics"]?.arrayValue?.map { $0["code"] ?? .null }
            #expect(codes == [.null, .null, "truncated"])
            #expect(harnessToolDetails(result) == ["step": 2]); #expect(text == "line 1\nline 2\n|<harness>\n[info] from api\n[warn] from result\n[warn] Output truncated to its beginning: 1 lines, 7 bytes dropped\n</harness>")
        case "tail": #expect(text == "y\n|<harness>\n[warn] Output truncated to its end: 3 lines, 18 bytes dropped\n</harness>")
        case "throw": #expect(result.isError && text == "partial\n|<harness>\n[error] boom\n</harness>")
        case "default": #expect(text.hasPrefix("1\n2\n") && text.hasSuffix("\n2000\n|<harness>\n[warn] Output truncated to its beginning: 500 lines, 2500 bytes dropped\n</harness>"))
        case "sanitize": #expect(text == "ab\n")
        case "null": #expect(harnessToolDetails(result) == .null)
        default: #expect(harnessToolDetails(result) == ["n": 3] && settled.withLock { $0.sorted() } == [1, 2, 3])
        }
        try await opened.harness.close(context: .background)
    }
    // :394,959 explicit content.
    @Test func explicitContentLimitsAndControls() async throws {
        let setup = HarnessChatSetup()
        try installHarnessTool(harnessTestTool(limits: .init(maxLines: 2, retain: .tail), execute: { _, _, _ in
            .init(content: [.text(TextContent(text: "a\nb\n")), .image(ImageContent(data: "AAAA", mimeType: "image/png")), .text(TextContent(text: "c\u{1b}d\ne\n"))])
        }), setup: setup)
        let (opened, entries) = try await runHarnessTools(setup)
        let text = harnessToolText(try #require(harnessToolResults(entries).first))
        #expect(text == "[image]|c\u{1b}d\ne\n|<harness>\n[warn] Output truncated to its end: 2 lines, 4 bytes dropped\n</harness>")
        try await opened.harness.close(context: .background)
    }
    // :469,514,548.
    @Test func validationRepairsAndFirstBlock() async throws {
        let setup = HarnessChatSetup(), seen = Mutex<[JSONValue]>([]), later = Mutex(0)
        try installHarnessTool(harnessTestTool(prepare: { args in
            if args["text"] == "repair-throw" { throw TaskDefinitionError("cannot repair") }
            if args["text"] == 7 { return ["text": "#7"] }
            return args
        }, execute: { args, _, _ in seen.withLock { $0.append(args) }; return .init(content: []) }), setup: setup)
        try setup.registry.install(Extension(name: "first", hooks: [hook(ToolHooks(beforeTool: { call, _, _ in
            if call.id == "block" { return .init(block: "first says no") }
            if call.id == "throw" { throw TaskDefinitionError("hook failed") }
            if call.id == "bad" { return .init(arguments: ["text": ["not": "string"]]) }
            if call.id == "coerced" || call.id == "ok" {
                return .init(arguments: ["text": .string((call.arguments["text"]?.value as? String ?? "") + "!")])
            }
            return nil
        }))]))
        try setup.registry.install(Extension(name: "later", hooks: [hook(ToolHooks(beforeTool: { _, _, _ in later.withLock { $0 += 1 }; return nil }))]))
        let (opened, entries) = try await runHarnessTools(setup, calls: [
            ("echo", ["text": 7], "fixed"), ("echo", ["text": "repair-throw"], "repair"),
            ("echo", [:], "block"), ("echo", [:], "throw"), ("echo", ["text": "x"], "bad"),
            ("echo", ["text": ["not": "string"]], "invalid"), ("echo", ["text": "x"], "ok"), ("echo", ["text": 1], "coerced")])
        let results = try harnessToolResults(entries)
        #expect(results.filter(\.isError).count == 5)
        #expect(seen.withLock { $0 } .contains(["text": "#7"]))
        #expect(seen.withLock { $0.count } == 3 && later.withLock { $0 } == 4)
        #expect(seen.withLock { $0 }.contains(["text": "1!"]) && seen.withLock { $0 }.contains(["text": "x!"]))
        #expect(harnessToolText(try #require(results.first { $0.toolCallId == "repair" })) == "<harness>\n[error] cannot repair\n</harness>")
        #expect(harnessToolText(try #require(results.first { $0.toolCallId == "throw" })) == "<harness>\n[error] Tool call blocked: hook failed\n</harness>")
        let invalidEntries = entries.filter { $0.kind == toolResultEntry.kind && [JSONValue.string("bad"), .string("invalid")].contains($0.model?.first?["toolCallId"] ?? .null) }
        #expect(invalidEntries.count == 2 && invalidEntries.allSatisfy { $0.data?["diagnostics"]?[0]?["code"] == "invalid_arguments" })
        #expect(results.filter { ["bad", "invalid"].contains($0.toolCallId) }.allSatisfy { harnessToolText($0).contains("Validation failed") })
        #expect(harnessToolText(try #require(results.first { $0.toolCallId == "block" })).contains("first says no"))
        let assistant = try #require(entries.first { $0.kind == assistantEntry.kind })
        #expect(assistant.model?.first?["content"]?[0]?["arguments"]?["text"] == 7)
        try await opened.harness.close(context: .background)
    }
    // :573,778.
    @Test func replacementChainRoundHookAndMemos() async throws {
        let setup = HarnessChatSetup(), observed = Mutex<[EntryID]>([]), assistantId = Mutex<EntryID?>(nil)
        try installHarnessTool(harnessTestTool(execute: { _, _, _ in .init(content: [.text(TextContent(text: "raw"))]) }), setup: setup)
        try setup.registry.install(Extension(name: "first", hooks: [hook(ToolHooks(beforeTool: { _, api, context in
            let first = try await api.memo("decision", "approved", context)
            #expect(first == .string("approved"))
            let second = try await api.memo("decision", "denied", context)
            #expect(second == .string("approved")); return nil
        }, afterTool: { _, result, _, _ in var next = result; next.content = [.text(TextContent(text: "first"))]; return next }))]))
        try setup.registry.install(Extension(name: "second", hooks: [hook(ToolHooks(afterTool: { _, result, _, _ in
            var next = result; next.details = ["replaced": "first"]; #expect(result.content?.count == 1); return next
        })), hook(GenerationHooks(afterTools: { assistant, ids, _, _ in assistantId.withLock { $0 = assistant }; observed.withLock { $0 = ids } }))]))
        let (opened, entries) = try await runHarnessTools(setup), result = try #require(harnessToolResults(entries).first)
        #expect(harnessToolText(result) == "first" && harnessToolDetails(result) == ["replaced": "first"])
        #expect(observed.withLock { $0 } == entries.filter { $0.kind == toolResultEntry.kind }.map(\.id))
        #expect(assistantId.withLock { $0 } == entries.first { $0.kind == assistantEntry.kind }?.id)
        try await opened.harness.close(context: .background)
    }
    // :641,983. Swift optional values omit absent control members.
    @Test(arguments: [false, true]) func controlsAndTermination(allStop: Bool) async throws {
        let setup = HarnessChatSetup()
        try installHarnessTool(harnessTestTool("stop", execute: { _, _, _ in .init(content: [], control: .init(terminate: true)) }), setup: setup)
        try installHarnessTool(harnessTestTool("grow", execute: { _, _, _ in .init(content: [], control: .init(addTools: ["extra", "stop"])) }), setup: setup)
        try installHarnessTool(harnessTestTool("extra"), setup: setup)
        setup.models.setResponses([.message(try toolCalls(allStop ? [("stop", [:], "stop")] : [("stop", [:], "stop"), ("grow", [:], "grow")])), .message(chatAssistant("done"))])
        let opened = try await openChat(setup: setup)
        try await opened.root.configure(change: .init(tools: .set(.exact(try await opened.root.agent(context: .background).tools.filter { $0.name != "extra" }))), context: .background)
        #expect(try await opened.root.submit(.input(content: .text("go")), context: .background).wait(context: .background).status == "done")
        let entries = try await allEntries(opened.root)
        #expect(entries.last?.kind == (allStop ? toolResultEntry.kind : assistantEntry.kind))
        if !allStop { #expect(try await opened.root.agent(context: .background).tools.map(\.name) == ["stop", "grow", "extra"]) }
        let tasks = try await opened.harness.commit({ tx in try await tx.scanTasks(.init(conversationId: opened.root.id), limit: 20) }, context: .background)
        #expect(tasks.items.allSatisfy { $0.state.status == "terminal" })
        try await opened.harness.close(context: .background)
    }
    // :1035,1066.
    @Test func replacementKeepsCallAndRefreshesNextRequest() async throws {
        let setup = HarnessChatSetup(), started = HarnessChatSignal(), release = HarnessChatSignal(), versions = Mutex<[String]>([])
        func prompt(_ version: String) -> Extension {
            Extension(name: "prompt", sections: [section("mode") { _, _ in version }], hooks: [hook(GenerationHooks(beforeRequest: { _, _, _ in versions.withLock { $0.append(version) }; return nil }))])
        }
        try setup.registry.install(prompt("v1"))
        try installHarnessTool(harnessTestTool("work", execute: { _, _, _ in started.signal(); await release.wait(); return .init(content: [.text(TextContent(text: "v1"))]) }), setup: setup)
        setup.models.setResponses([.message(try toolCalls([("work", [:], "work")])), .message(chatAssistant("done"))])
        let opened = try await openChat(setup: setup), submission = try await opened.root.submit(.input(content: .text("go")), context: .background)
        await started.wait()
        try installHarnessTool(harnessTestTool("work", execute: { _, _, _ in .init(content: [.text(TextContent(text: "v2"))]) }), setup: setup)
        try setup.registry.install(prompt("v2")); release.signal()
        _ = try await submission.wait(context: .background)
        #expect(harnessToolText(try #require(harnessToolResults(await allEntries(opened.root)).first)) == "v1")
        #expect(versions.withLock { $0 } == ["v1", "v2"])
        let systems = try await allEntries(opened.root).filter { $0.kind == systemEntry.kind }
        #expect(systems.compactMap { $0.model?.first?["sections"] } == [["mode": "<mode>\nv1\n</mode>"], ["mode": "<mode>\nv2\n</mode>"]])
        try await opened.harness.close(context: .background)
    }
    // :674,704,730,744. Request changes are transient; both continuation handlers compete.
    @Test(arguments: [false, true]) func generationHooksAndYield(deferred: Bool) async throws {
        let setup = HarnessChatSetup(options: deferred ? .init(deferred: .init(pendingFetches: 1, pollAfterMs: 1)) : .init())
        let yields = Mutex(0), secondYields = Mutex(0), observed = Mutex<[String]>([])
        if deferred { setup.updateSettings { $0.stream = .init(deferred: DeferredRequest()) } }
        try installHarnessTool(harnessTestTool(), setup: setup)
        try setup.registry.install(Extension(name: "hooks", hooks: [hook(GenerationHooks(beforeRequest: { request, _, _ in
            var next = request; next.messages.append(.user(UserMessage(content: .text("injected"), timestamp: 0))); return next
        }, afterResponse: { message, _, _ in
            observed.withLock { $0.append("throwing:\(message.stopReason.rawValue)") }; throw TaskDefinitionError("observer failed")
        }, onYield: { _, _, _ in
            let count = yields.withLock { $0 += 1; return $0 }; return count == 1 ? .init(continue: .text("first")) : nil
        })), hook(GenerationHooks(afterResponse: { _, _, _ in observed.withLock { $0.append("next") } }, onYield: { _, _, _ in
            let count = secondYields.withLock { $0 += 1; return $0 }
            return count == 1 ? .init(continue: .text("second")) : nil
        }))]))
        let opened = try await openChat(setup: setup)
        let continuation: FakeDurableResponseStep = .factory { request, _, _, _ in
            #expect(textOf(request.messages.last) == "injected")
            let live = try #require(await opened.harness.snapshot(LiveDoc, conversationId: opened.root.id, context: .background))
            let input = try #require(live.run?.inputs.first)
            let submission = try #require(await opened.harness.submission(id: input, context: .background))
            #expect(try await submission.status(context: .background).status == "placed")
            return chatAssistant("continued")
        }
        setup.models.setResponses([.message(try toolCalls([("echo", [:], "echo")])), .message(chatAssistant("answer")), continuation, continuation])
        let submission = try await opened.root.submit(.input(content: .text("go")), context: .background)
        let settled = try await submission.wait(context: .background), entries = try await allEntries(opened.root)
        #expect(settled.status == "done" && settled.answer == entries.last?.id)
        #expect(observed.withLock { $0.count } == 8 && observed.withLock { $0.filter { $0 == "next" }.count } == 4)
        #expect(secondYields.withLock { $0 } == 2)
        let users = try entries.filter { $0.kind == userEntry.kind }.map { try textOf($0.messages()?.first) }
        #expect(users == ["go", "first", "second"])
        #expect(!entries.contains { $0.model?.first?["content"] == "injected" })
        #expect(setup.reports.values.contains { String(describing: $0).contains("observer failed") })
        if deferred { #expect(setup.models.state().deferredFetchCount > 0) }
        try await opened.harness.close(context: .background)
    }
}
