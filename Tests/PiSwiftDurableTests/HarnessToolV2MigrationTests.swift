import Foundation
import Synchronization
import Testing
import PiSwiftAI
import PiSwiftChord
import PiSwiftDurableTesting
@testable import PiSwiftDurable

private func toolV2Open(_ path: String, setup: HarnessChatSetup) async throws -> OpenChatResult {
    let harness = try await Harness.open(storage: SqliteStorage.open(path: path), options: HarnessOptions(
        models: setup.models, registry: setup.registry, settings: setup.settingsProvider,
        onReport: { setup.reports.append($0) }), context: .background)
    let root = try await harness.root(options: .init(agent: AgentChange(
        model: .set(ModelRef(provider: "faux", modelId: "faux-1")))), context: .background)
    return OpenChatResult(harness: harness, root: root)
}

/// Store the old wire input through a separate connection, as the upstream SQLite tests do.
private func storeToolV1(_ path: String, setup: HarnessChatSetup, checkpoint: ToolTaskCheckpoint,
                         outcome: TaskOutcome? = nil, terminal: Bool = false) async throws -> TaskID {
    let opened = try await toolV2Open(path, setup: setup)
    let id = try await opened.root.commit({ tx in
        let assistant = try await tx.appendEntry(opened.root.id, value: EntryDraft(kind: assistantEntry.kind,
            model: EntryRecord.encodeMessages([.assistant(try toolCalls([("echo", ["text": "old"], "c1")]))])))
        return try await tx.createTask(toolTask, input: ToolTaskInput(assistant: assistant.id, callId: "c1"),
                                       options: .init(ownership: .conversation()))
    }, context: .background)
    try await opened.harness.close(context: .background)
    let storage = try await SqliteStorage.open(path: path)
    let record = try #require(try await storage.task(id, context: .background))
    var input = try #require(record.input.objectValue)
    input.removeValue(forKey: "kind")
    let state: TaskState
    if let outcome { state = terminal ? .terminal(outcome: outcome) : .completing(outcome: outcome) }
    else { state = .pending(checkpoint: try JSONValue(encoding: checkpoint)) }
    let old = TaskRecord(id: id, conversationId: record.conversationId, kind: record.kind, version: 1,
                         input: .object(input), state: state)
    _ = try await storage.commit([.task(value: old)], context: .background)
    try await storage.close(context: .background)
    return id
}

@Suite struct HarnessToolV2MigrationTests {
    @Test(arguments: [JSONValue.object(["assistant": 3, "callId": "c1"]),
                      ["kind": .null, "assistant": 3, "callId": "c1"],
                      ["kind": "unknown", "assistant": 3, "callId": "c1"]])
    func versionTwoInputRequiresKnownNonNullTag(value: JSONValue) {
        #expect(throws: (any Error).self) { try value.decode(ToolTaskInput.self) }
    }

    @Test(arguments: [JSONValue.object(["kind": .null, "entryId": 3]),
                      ["kind": "unknown", "entryId": 3], ["kind": "model"]])
    func resultRejectsInvalidTagAndMissingEntry(value: JSONValue) {
        #expect(throws: (any Error).self) { try value.decode(ToolTaskResult.self) }
    }

    @Test func resultAcceptsLegacyAbsentTag() throws {
        let legacy: JSONValue = ["entryId": 3, "control": ["terminate": true]]
        let result = try legacy.decode(ToolTaskResult.self)
        #expect(result == .model(entryId: try EntryID(3), control: .init(terminate: true)))
    }

    // Exercise the generation producer and its consumer of a held v1 receipt together.
    @Test func generationUsesTerminateControlFromHeldLegacyToolResult() async throws {
        let directory = try sqliteTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("held-control.sqlite").path
        let setup = HarnessChatSetup(), reached = HarnessChatSignal(), runs = Mutex(0)
        try installHarnessTool(harnessTestTool(execute: { _, _, context in
            runs.withLock { $0 += 1 }
            reached.signal()
            try await harnessToolAwaitAbort(context)
            return ToolExecutionResult()
        }), setup: setup)
        setup.models.setResponses([.message(try toolCalls([("echo", ["text": "old"], "c1")])),
                                   .message(chatAssistant("unexpected continuation"))])
        let first = try await toolV2Open(path, setup: setup)
        let submission = try await generationSubmit(first, "go")
        await reached.wait()
        let slot = try #require(try await generationLive(first)?.tools?.first)
        let toolID = try #require(slot.taskId)
        let produced = try #require(try await first.harness.getTask(id: toolID, context: .background))
        #expect(produced.version == 2)
        #expect(produced.input["kind"] == "model")
        let entryID = try await first.root.commit({ tx in
            let message = ToolResultMessage(toolCallId: "c1", toolName: "echo", content: [],
                                            isError: false, timestamp: 0)
            let entry = try await tx.appendEntry(first.root.id, value: EntryDraft(kind: toolResultEntry.kind,
                model: EntryRecord.encodeMessages([.toolResult(message)])))
            let live = try await tx.doc(LiveDoc, conversationId: first.root.id)
            try live.set("tools", JSONValue(encoding: [ToolSlot(callId: "c1", name: "echo", taskId: toolID,
                                                               status: .done, entry: entry.id)]))
            return entry.id
        }, context: .background)
        try await first.harness.close(context: .background)
        let storage = try await SqliteStorage.open(path: path)
        let record = try #require(try await storage.task(toolID, context: .background))
        var input = try #require(record.input.objectValue)
        input.removeValue(forKey: "kind")
        let legacy: JSONValue = ["entryId": try JSONValue(encoding: entryID), "control": ["terminate": true]]
        let held = TaskRecord(id: record.id, conversationId: record.conversationId, kind: record.kind, version: 1,
            input: .object(input), state: .completing(outcome: .completed(result: legacy)), owner: record.owner,
            background: record.background, startedAt: record.startedAt)
        _ = try await storage.commit([.task(value: held)], context: .background)
        try await storage.close(context: .background)
        let second = try await toolV2Open(path, setup: setup)
        try second.harness.resume()
        let reacquired = try #require(try await second.harness.submission(id: submission.id, context: .background))
        #expect(try await reacquired.wait(context: .background).status == "done")
        #expect(setup.models.calls().streamSimple == 1)
        #expect(runs.withLock { $0 } == 1)
        #expect(try harnessToolResults(await allEntries(second.root)).count == 1)
        #expect(try await generationLive(second) == LiveState())
        let receipt = try await second.harness.waitForTask(id: toolID, context: .background)
        #expect(receipt.outcome == .completed(result: legacy))
        try await second.harness.close(context: .background)
    }

    // harness-nested-tools.test.ts:1267.
    @Test func migrationAddsModelTagAndKeepsCheckpoint() throws {
        let migrate = try #require(toolTask.migrate)
        let converted = try migrate(["assistant": 3, "callId": "c1"], ["phase": "call"], 1)
        #expect(try JSONValue(encoding: converted.input) == ["kind": "model", "assistant": 3, "callId": "c1"])
        #expect(try JSONValue(encoding: converted.checkpoint) == ["phase": "call"])
    }

    // harness-nested-tools.test.ts:1308,1326.
    @Test(arguments: [false, true])
    func pendingVersionOneTaskMigratesBeforeExecution(interrupted: Bool) async throws {
        let directory = try sqliteTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("tool-v1.sqlite").path
        let setup = HarnessChatSetup(), runs = Mutex(0)
        try installHarnessTool(harnessTestTool(execute: { _, _, _ in
            runs.withLock { $0 += 1 }
            return ToolExecutionResult(output: [.text(TextContent(text: "echo old"))])
        }), setup: setup)
        let checkpoint = interrupted ? ToolTaskCheckpoint(phase: .execute, arguments: ["text": "old"], replay: .unsafe)
                                    : ToolTaskCheckpoint(phase: .call)
        let id = try await storeToolV1(path, setup: setup, checkpoint: checkpoint)
        let opened = try await toolV2Open(path, setup: setup)
        #expect(try await opened.harness.getTask(id: id, context: .background)?.version == 1)
        try opened.harness.resume()
        let settled = try await opened.harness.waitForTask(id: id, context: .background)
        #expect(settled.record.version == 2)
        #expect(settled.record.input.objectValue?["kind"] == "model")
        #expect(settled.outcome.status == (interrupted ? "failed" : "completed"))
        #expect(runs.withLock { $0 } == (interrupted ? 0 : 1))
        let messages = try harnessToolResults(await allEntries(opened.root))
        let result = try #require(messages.first)
        #expect(messages.count == 1)
        #expect(result.toolCallId == "c1")
        #expect(result.isError == interrupted)
        if interrupted { #expect(harnessToolText(result).contains("Tool echo was interrupted")) }
        else { #expect(harnessToolText(result) == "echo old") }
        try await opened.harness.close(context: .background)
    }

    // tool.ts:75–81: held and terminal v1 outcomes retain their untagged receipt.
    @Test(arguments: [false, true])
    func heldAndTerminalVersionOneResultsKeepLegacyReceipt(terminal: Bool) async throws {
        let directory = try sqliteTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("tool-v1-result.sqlite").path
        let setup = HarnessChatSetup(), runs = Mutex(0)
        try installHarnessTool(harnessTestTool(execute: { _, _, _ in
            runs.withLock { $0 += 1 }; return ToolExecutionResult()
        }), setup: setup)
        let legacy: JSONValue = ["entryId": 3, "control": ["terminate": true]]
        let id = try await storeToolV1(path, setup: setup, checkpoint: .init(phase: .call),
                                      outcome: .completed(result: legacy), terminal: terminal)
        let opened = try await toolV2Open(path, setup: setup)
        try opened.harness.resume()
        let receipt = try await opened.harness.waitForTask(id: id, context: .background)
        guard case .completed(let raw, _) = receipt.outcome else {
            Issue.record("Expected the saved completed outcome"); return
        }
        #expect(raw == legacy)
        let result = try raw.decode(ToolTaskResult.self)
        #expect(result == .model(entryId: try EntryID(3), control: .init(terminate: true)))
        #expect(runs.withLock { $0 } == 0)
        #expect(try harnessToolResults(await allEntries(opened.root)).isEmpty)
        try await opened.harness.close(context: .background)
    }
}
