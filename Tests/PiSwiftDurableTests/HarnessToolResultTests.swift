import Foundation
import Testing
import Synchronization
import PiSwiftAI
import PiSwiftChord
@testable import PiSwiftDurable
import PiSwiftDurableTesting

struct HarnessToolResultTests {
    // harness-tools.test.ts:82. The next request receives the result after its call.
    @Test func fullRoundAndRequestHistory() async throws {
        let setup = HarnessChatSetup(), checked = Mutex(false)
        try installHarnessTool(harnessTestTool(execute: { args, _, _ in
            .init(content: [.text(TextContent(text: "echo \(args["text"]?.stringValue ?? "")"))])
        }), setup: setup)
        setup.models.setResponses([.message(try toolCalls([("echo", ["text": "hi"], "c1")])), .factory { request, _, _, _ in
            guard case .toolResult(let result) = request.messages.last,
                  case .assistant(let call) = request.messages.dropLast().last else {
                Issue.record("Tool result does not follow its call"); return chatAssistant("done")
            }
            #expect(result.toolCallId == "c1" && result.toolName == "echo" && !result.isError)
            #expect(harnessToolText(result) == "echo hi" && call.stopReason == .toolUse)
            checked.withLock { $0 = true }; return chatAssistant("done")
        }])
        let opened = try await openChat(setup: setup)
        #expect(try await opened.root.submit(.input(content: .text("go")), context: .background).wait(context: .background).status == "done")
        let entries = try await allEntries(opened.root)
        #expect(entries.map(\.kind) == ["pi.user", "pi.system", "pi.assistant", "pi.tool-result", "pi.assistant"])
        #expect(entries[3].byTaskId != nil && entries[3].data == ["diagnostics": []])
        #expect(checked.withLock { $0 } && setup.models.state().callCount == 2)
        #expect(try await opened.harness.snapshot(LiveDoc, conversationId: opened.root.id, context: .background) == LiveState())
        try await opened.harness.close(context: .background)
    }
    // :188. Unregister before preparation removes the offer and creates no tool task.
    @Test func registryRemovalAndReaddition() async throws {
        let setup = HarnessChatSetup(), tool = try harnessTestTool()
        try installHarnessTool(tool, setup: setup)
        setup.models.setResponses([.message(chatAssistant("first"))])
        let opened = try await openChat(setup: setup)
        _ = try await opened.root.submit(.input(content: .text("first")), context: .background).wait(context: .background)
        setup.registry.uninstall(name: "tool:echo")
        setup.models.setResponses([.message(try toolCalls([("echo", [:], "c1")])), .message(chatAssistant("done"))])
        #expect(try await opened.root.submit(.input(content: .text("again")), context: .background).wait(context: .background).status == "done")
        var entries = try await allEntries(opened.root)
        #expect(entries.last { $0.kind == systemEntry.kind }?.model?.first?["toolsRemoved"] == [["name": "echo"]])
        #expect(try harnessToolResults(entries).first?.isError == true)
        #expect(try await opened.root.agent(context: .background).tools.isEmpty)
        let tasks = try await opened.harness.commit({ tx in try await tx.scanTasks(.init(conversationId: opened.root.id), limit: 20) }, context: .background)
        #expect(tasks.items.allSatisfy { $0.kind != "pi.tool" })
        try installHarnessTool(tool, setup: setup)
        setup.models.setResponses([.message(chatAssistant("back"))])
        _ = try await opened.root.submit(.input(content: .text("back")), context: .background).wait(context: .background)
        entries = try await allEntries(opened.root)
        #expect(entries.last { $0.kind == systemEntry.kind }?.model?.first?["toolsAdded"]?[0]?["name"] == "echo")
        try await opened.harness.close(context: .background)
    }
    // :983. Swift nil omits the source undefined control key.
    @Test func absentControlAndRemovedToolFilter() async throws {
        let setup = HarnessChatSetup(), extra = try harnessTestTool("extra")
        try installHarnessTool(extra, setup: setup)
        try installHarnessTool(harnessTestTool("grow", execute: { _, _, _ in
            .init(content: [], control: .init(addTools: ["extra"], terminate: nil))
        }), setup: setup)
        let opened = try await openChat(setup: setup)
        try await opened.root.configure(change: .init(tools: .set(.remove([extra]))), context: .background)
        setup.models.setResponses([.message(try toolCalls([("grow", [:], "grow")])), .message(chatAssistant("done"))])
        #expect(try await opened.root.submit(.input(content: .text("go")), context: .background).wait(context: .background).status == "done")
        #expect(try await opened.harness.snapshot(AgentDoc, conversationId: opened.root.id, context: .background)?.tools == .remove([]))
        try await opened.harness.close(context: .background)
    }
    // Content replacement is compared by provenance, including equal fresh arrays.
    @Test(arguments: ["none", "copy", "replace"]) func afterToolContentProvenance(mode: String) async throws {
        let setup = HarnessChatSetup()
        try installHarnessTool(harnessTestTool(limits: .init(maxLines: 1), execute: { _, api, _ in
            try api.output(.text("a\nb\n"), nil); return .init()
        }), setup: setup)
        try setup.registry.install(Extension(name: "after", hooks: [hook(ToolHooks(afterTool: { _, result, _, _ in
            if mode == "none" { return nil }
            var copy = result
            if mode == "replace" { copy.content = [.text(TextContent(text: "a\n"))] }
            else { copy.details = ["copied": true] }
            return copy
        }))]))
        let (opened, entries) = try await runHarnessTools(setup)
        let entry = try #require(entries.first { $0.kind == toolResultEntry.kind })
        let diagnostics = entry.data?["diagnostics"]?.arrayValue ?? []
        #expect(diagnostics.contains { $0["code"] == "truncated" } == (mode != "replace"))
        #expect(harnessToolText(try #require(harnessToolResults(entries).first)).hasPrefix("a\n"))
        try await opened.harness.close(context: .background)
    }
    @Test func userToolRequiresAnEnvironment() async throws {
        let setup = HarnessChatSetup()
        try installHarnessTool(harnessTestTool(execute: { _, api, _ in
            guard api.env != nil else { throw NoExecutionEnvironmentError() }
            return .init(content: [])
        }), setup: setup)
        let (opened, entries) = try await runHarnessTools(setup)
        let result = try #require(harnessToolResults(entries).first)
        #expect(result.isError && result.durationMs != nil)
        #expect(harnessToolText(result) == "<harness>\n[error] No execution environment is configured\n</harness>")
        #expect(entries.first { $0.kind == toolResultEntry.kind }?.data?["diagnostics"]?[0]?["code"] == "tool_error")
        try await opened.harness.close(context: .background)
    }
    @Test func cancelledDetailsCallerDoesNotAbortTool() async throws {
        let setup = HarnessChatSetup(settings: .init(progress: .init(outputIntervalMs: 60_000)), clock: TestClock())
        try installHarnessTool(harnessTestTool(execute: { _, api, context in
            try await api.details(["first": true], context)
            let caller = context.withCancel()
            let waiting = Task { try await api.details(["second": true], caller.context) }
            try await eventually { api.pendingDetailsCount() == 1 }
            caller.cancel(TaskDefinitionError("details caller cancelled"))
            await #expect(throws: (any Error).self) { try await waiting.value }
            #expect(context.abortSignal?.aborted == false)
            return .init(content: [])
        }), setup: setup)
        let (opened, entries) = try await runHarnessTools(setup)
        let result = try #require(harnessToolResults(entries).first)
        #expect(!result.isError && harnessToolDetails(result) == ["second": true])
        try await opened.harness.close(context: .background)
    }

}
