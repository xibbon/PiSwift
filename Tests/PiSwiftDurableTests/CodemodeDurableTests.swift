import Foundation
import Synchronization
import Testing
import PiSwiftAI
import PiSwiftChord
import PiSwiftDurableTesting
@testable import PiSwiftDurable

// These plans replace only JavaScript execution. The Harness, nested tasks, documents,
// storage, restart, and journal commits use the public durable implementation.
private final class CDFlag: Sendable {
    private let state = Mutex(true)
    var value: Bool { get { state.withLock { $0 } } set { state.withLock { $0 = newValue } } }
}
private final class CDChat: Sendable {
    let setup = HarnessChatSetup()
    let sandbox: DeterministicCodemodeSandbox
    let runs = SessionTestLog<String>()
    let held = HarnessChatSignal()
    let block = CDFlag()
    init(globals: [CodemodeGlobal] = [], plan: @escaping DeterministicCodemodeSandbox.Plan) throws {
        sandbox = DeterministicCodemodeSandbox(plan: plan)
        try setup.registry.install(createCodemodeExtension(options: .init(sandbox: sandbox, models: false, globals: globals)))
        try installHarnessTool(ToolRegistration(name: "echo", description: "echo", parameters: ["type": "object"], replay: .safe) { [runs] args, _, _ in
            let text = args["text"]?.stringValue ?? ""
            runs.append(text)
            return .init(output: [.text(.init(text: "echo " + text))])
        }, setup: setup)
        try installHarnessTool(ToolRegistration(name: "hold", description: "hold", parameters: ["type": "object"], replay: .safe) { [runs, block, held] _, _, context in
            runs.append("hold"); held.signal()
            if block.value { try await harnessToolAwaitAbort(context) }
            return .init(output: [.text(.init(text: "held"))])
        }, setup: setup)
    }
    func responses(_ code: String = "script") throws {
        setup.models.setResponses([.message(try toolCalls([("codemode", ["code": .string(code)], "cm")])), .message(chatAssistant("done"))])
    }
}
private func cdEcho(_ text: String) -> DeterministicCodemodeCall { .init(name: "echo", args: ["text": .string(text)]) }
private let cdHold = DeterministicCodemodeCall(name: "hold", args: [:])
private func cdValue(_ outcome: CodemodeOutcome) -> JSONValue { if case .success(let value) = outcome { return value ?? .null }; return .null }
private func cdText(_ result: ToolResultMessage) -> String { result.content.compactMap { if case .text(let text) = $0 { text.text } else { nil } }.joined(separator: "\n") }
private func cdResult(_ opened: OpenChatResult) async throws -> ToolResultMessage {
    try #require(try harnessToolResults(await allEntries(opened.root)).last)
}
private func cdTask(_ opened: OpenChatResult) async throws -> TaskID {
    let tasks = try await opened.harness.commit({ tx in try await tx.scanTasks(.init(kind: "pi.tool"), limit: 100).items }, context: .background)
    return try #require(tasks.first { $0.input["kind"] == "model" }).id
}
private func cdNested(_ opened: OpenChatResult) async throws -> [TaskRecord] {
    try await opened.harness.commit({ tx in try await tx.scanTasks(.init(kind: "pi.tool"), limit: 100).items.filter { $0.input["kind"] == "nested" } }, context: .background)
}
private func cdWait(_ opened: OpenChatResult, _ id: SubmissionID) async throws {
    let submission = try #require(try await opened.harness.submission(id: id, context: .background))
    #expect(try await submission.wait(context: .background).status == "done")
    try await opened.harness.waitForIdle(context: .background)
}
private struct CDRestartResult: Sendable {
    var message: ToolResultMessage
    var tasks: [TaskRecord]
    var starts: [DeterministicCodemodeSandbox.Start]
    var store: JSONObject?
}
private func cdRestart(_ chat: CDChat, code: String = "script",
    beforeClose: @Sendable (OpenChatResult, TaskID) async throws -> Void = { _, _ in },
    mutate: @Sendable (OpenChatResult, TaskID) async throws -> Void = { _, _ in }
) async throws -> CDRestartResult {
    let directory = try sqliteTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let path = directory.appendingPathComponent("codemode.sqlite").path
    try chat.responses(code)
    let first = try await openChat(storage: SqliteStorage.open(path: path), setup: chat.setup)
    let id = try await generationSubmit(first).id
    await chat.held.wait()
    let task = try await cdTask(first)
    // Reach the idle-count commit before the simulated process close.
    try await eventually {
        let journal = try await first.harness.snapshot(CodemodeJournalDoc, taskId: task, context: .background)
        let entries = journal?["entries"]?.arrayValue ?? []
        return entries.last?["issuedAfter"] != nil || entries.isEmpty && journal?["firstIssued"] != nil
    }
    try await beforeClose(first, task)
    try await first.harness.close(context: .background)
    let second = try await openChat(storage: SqliteStorage.open(path: path), setup: chat.setup)
    try await mutate(second, task)
    chat.block.value = false
    try second.harness.resume()
    try await cdWait(second, id)
    let result = try await CDRestartResult(message: cdResult(second), tasks: cdNested(second), starts: chat.sandbox.starts,
        store: second.harness.snapshot(CodemodeStoreDoc, conversationId: second.root.id, context: .background))
    try await second.harness.close(context: .background)
    return result
}
private func cdMutateStart(_ opened: OpenChatResult, _ task: TaskID, key: String, value: JSONValue) async throws {
    try await opened.harness.commit({ tx in
        try await tx.doc(CodemodeRunDoc, taskId: task).child("start")!.set(key, value)
    }, context: .background)
}
private func cdSequential(_ state: DeterministicCodemodeState) -> DeterministicCodemodeStep {
    switch state.seq {
    case 0: .init(calls: [cdEcho("a")])
    case 1: .init(calls: [cdHold])
    case 2: .init(calls: [cdEcho("b")])
    default: .init(result: .init(value: .array(state.deliveries.map { cdValue($0.outcome) })))
    }
}

@Suite("PiSwiftDurableTests.CodemodeDurable")
struct CodemodeDurableTests {
    // Upstream codemode.test.ts:193 and207. All calls use c<VM id> keys.
    @Test func nestedCallsAreJournaledAndFinishedCallsDoNotRunAgain() async throws {
        let chat = try CDChat(plan: cdSequential)
        let result = try await cdRestart(chat)
        #expect(!result.message.isError)
        #expect(cdText(result.message).contains("[\"echo a\",\"held\",\"echo b\"]"))
        #expect(chat.runs.values.filter { $0 == "a" }.count == 1)
        #expect(chat.runs.values.filter { $0 == "b" }.count == 1)
        #expect(chat.runs.values.filter { $0 == "hold" }.count == 2)
        #expect(result.tasks.count == 3)
        #expect(Set(result.tasks.compactMap { $0.input["key"]?.stringValue }) == ["c1", "c2", "c3"])
        #expect(result.starts.count == 2)
    }

    // :254. The fake verifies the stored clock and seed, not JavaScript Date or Math.random.
    @Test func startClockSeedStoreAndDeclarationsRemainFixed() async throws {
        let chat = try CDChat(plan: cdSequential)
        let result = try await cdRestart(chat)
        #expect(result.starts[0].options.startedAt == result.starts[1].options.startedAt)
        #expect(result.starts[0].options.seed == result.starts[1].options.seed)
        #expect(result.starts[0].options.tools == result.starts[1].options.tools)
        #expect(result.starts[0].options.globals == result.starts[1].options.globals)
        #expect(result.starts[0].options.store == result.starts[1].options.store)
        #expect(result.starts[0].name == result.starts[1].name)
    }

    // :224. Results are replayed in completion order, even for parallel calls.
    @Test func parallelResultsReplayInArrivalOrder() async throws {
        let gate = HarnessChatSignal(), seen = SessionTestLog<Int>()
        let chat = try CDChat { state in
            switch state.seq {
            case 0: return .init(calls: [.init(name: "slow", args: ["id": 1]), .init(name: "slow", args: ["id": 2])])
            case 1: gate.signal(); return .init()
            case 2: return .init(calls: [cdHold])
            case 3: return .init(result: .init(value: .array(state.deliveries.prefix(2).map { .number(Double($0.id)) })))
            default: return .init()
            }
        }
        try installHarnessTool(ToolRegistration(name: "slow", description: "slow", parameters: ["type": "object"], replay: .safe) { args, _, _ in
            let id = Int(args["id"]?.numberValue ?? 0)
            if id == 1 { await gate.wait() }
            seen.append(id)
            return .init(output: [])
        }, setup: chat.setup)
        let result = try await cdRestart(chat)
        #expect(Array(seen.values.prefix(2)) == [2, 1])
        #expect(cdText(result.message).contains("[2,1]"))
        #expect(seen.values.count == 2)
    }

    // :240 and656. Nil remains absent in the global journal and on replay.
    @Test(arguments: [false, true]) func globalsReplayRecordedValuesIncludingUndefined(_ undefined: Bool) async throws {
        let counter = Mutex(0)
        let chat = try CDChat(globals: [.init(name: "next", execute: { _, _, _ in
            counter.withLock { $0 += 1 }
            if undefined { return Optional<JSONValue>.none }
            return .number(Double(counter.withLock { $0 }))
        })]) { state in
            switch state.seq {
            case 0, 2: .init(calls: [.init(target: .global, name: "next")])
            case 1: .init(calls: [cdHold])
            default: .init(result: .init(value: .array([cdValue(state.deliveries[0].outcome), cdValue(state.deliveries[2].outcome)])))
            }
        }
        let result = try await cdRestart(chat, beforeClose: { opened, task in
            let journal = try await opened.harness.snapshot(CodemodeJournalDoc, taskId: task, context: .background)
            if undefined { #expect(journal?["entries"]?[0]?["global"]?["outcome"]?["value"] == nil) }
            else { #expect(journal?["entries"]?[0]?["global"]?["outcome"]?["value"] == 1) }
        })
        #expect(counter.withLock { $0 } == 2)
        #expect(cdText(result.message).contains(undefined ? "[null,null]" : "[1,2]"))
    }

    // :269,286,305. Corrupt replay evidence stops execution before a new call.
    @Test(arguments: ["count", "missing", "globalArgs"])
    func detectsJournalDivergence(_ kind: String) async throws {
        let global = kind == "globalArgs"
        let chat = try CDChat(globals: [.init(name: "next", execute: { _, _, _ in 1 })]) { state in
            switch state.seq {
            case 0: .init(calls: [global ? .init(target: .global, name: "next") : cdEcho("a")])
            case 1: .init(calls: [cdHold])
            default: .init(result: .init(value: "done"))
            }
        }
        let result = try await cdRestart(chat, mutate: { opened, task in
            try await opened.harness.commit({ tx in
                let entry = try await tx.doc(CodemodeJournalDoc, taskId: task).child("entries")!.child(0)!
                if kind == "count" { try entry.set("issuedAfter", 7) }
                else if kind == "missing" { try entry.set("id", 99) }
                else { try entry.child("global")!.set("args", "other") }
            }, context: .background)
        })
        #expect(result.message.isError)
        #expect(cdText(result.message).contains(kind == "count" ? "after result 1 it had made 2 calls, where it had made 7" : kind == "missing" ? "it waits without making call 99" : "call 1 is next"))
        #expect(chat.runs.values.filter { $0 == "a" }.count <= 1)
    }

    // :318,347,370. A replay must not add calls or end at an earlier drain.
    @Test(arguments: ["extra", "early", "earlyNoAck"])
    func rejectsAddedCallsAndEarlyCompletion(_ kind: String) async throws {
        let chat = try CDChat { state in
            if state.seq == 0 { return .init(calls: [cdEcho("a")]) }
            if state.seq == 1 {
                if state.options.store["k"] != nil {
                    if kind == "extra" { return .init(calls: [cdEcho("extra1"), cdEcho("extra2"), cdEcho("extra3"), cdHold]) }
                    return .init(result: .init(value: "early", storeWrites: .init(set: ["wrong": 1])))
                }
                return .init(calls: kind == "earlyNoAck" ? [cdEcho("b")] : [cdHold])
            }
            if kind == "earlyNoAck" && state.seq == 2 { return .init(calls: [cdHold]) }
            return .init(result: .init(value: "done"))
        }
        let result = try await cdRestart(chat, mutate: { opened, task in
            try await cdMutateStart(opened, task, key: "store", value: ["k": true])
            if kind == "earlyNoAck" {
                try await opened.harness.commit({ tx in try await tx.doc(CodemodeJournalDoc, taskId: task).child("entries")!.child(0)!.remove("issuedAfter") }, context: .background)
            }
        })
        #expect(result.message.isError)
        #expect(cdText(result.message).contains(kind == "extra" ? "after result 1 it had made 5 calls, where it had made 2" : "it ended after result 1, where it went on before"))
        #expect(!chat.runs.values.contains("extra1"))
        #expect(result.store?["values"]?["wrong"] == nil)
    }

    // :390 and533. A rerun with no journal still checks all previously admitted keys.
    @Test(arguments: [false, true]) func noJournalRerunChecksArgumentsAndFirstCount(_ extra: Bool) async throws {
        let chat = try CDChat { state in
            if state.seq == 0 {
                let changed = state.options.store["k"] != nil
                return .init(calls: [cdEcho(changed ? "other" : "a")] + (changed && extra ? [cdEcho("new")] : []) + [cdHold])
            }
            return .init()
        }
        let result = try await cdRestart(chat, beforeClose: { opened, task in
            try await eventually {
                let journal = try await opened.harness.snapshot(CodemodeJournalDoc, taskId: task, context: .background)
                return journal?["entries"]?.arrayValue?.contains { $0["id"] == 1 } == true
            }
        }, mutate: { opened, task in
            try await cdMutateStart(opened, task, key: "store", value: ["k": true])
            try await opened.harness.commit({ tx in try await tx.doc(CodemodeJournalDoc, taskId: task).set("entries", []) }, context: .background)
        })
        #expect(result.message.isError)
        #expect(cdText(result.message).contains(extra ? "its first run made 3 calls, where it had made 2" : "call 1 is tools.echo"))
        #expect(chat.runs.values.filter { $0 == "a" }.count == 1)
        #expect(!chat.runs.values.contains("new"))
        #expect(result.tasks.count == 2)
    }

    // :559,577,605,625. Release validates all held calls before admitting any.
    @Test(arguments: ["target", "fewer", "early", "all"])
    func heldRerunCallsAreCheckedBeforeRelease(_ kind: String) async throws {
        let chat = try CDChat(globals: [.init(name: "pick", execute: { _, _, _ in 1 }), .init(name: "forever", execute: { _, _, context in
            try await harnessToolAwaitAbort(context); return nil
        })]) { state in
            let changed = state.options.store["k"] != nil
            if state.seq != 0 { return .init(result: .init(value: "done")) }
            switch kind {
            case "target": return .init(calls: changed ? [.init(target: .global, name: "pick")] : [cdHold])
            case "fewer": return .init(calls: changed ? [cdHold] : [cdHold, cdHold])
            case "early": return changed ? .init(result: .init(value: "early", storeWrites: .init(set: ["wrong": 1]))) : .init(calls: [cdHold])
            default: return .init(calls: [changed ? cdEcho("new") : .init(target: .global, name: "forever"), .init(name: "hold", args: ["id": changed ? 2 : 1])])
            }
        }
        let result = try await cdRestart(chat, mutate: { opened, task in try await cdMutateStart(opened, task, key: "store", value: ["k": true]) })
        #expect(result.message.isError)
        let expected = kind == "target" ? "call 1 is pick(), but was tools.hold({})" : kind == "fewer" ? "its first run made 1 calls, where it had made 2" : kind == "early" ? "it ended after result 0, where it went on before" : "call 2 is tools.hold"
        #expect(cdText(result.message).contains(expected))
        #expect(!chat.runs.values.contains("new"))
        #expect(result.store?["values"]?["wrong"] == nil)
    }

    // :412. A missing acknowledgement is committed at replay catch-up, before a long call returns.
    @Test func missingReplayCountIsRecordedAtOnce() async throws {
        let directory = try sqliteTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("missing-count.sqlite").path
        let chat = try CDChat(plan: cdSequential)
        try chat.responses()
        let first = try await openChat(storage: SqliteStorage.open(path: path), setup: chat.setup)
        let id = try await generationSubmit(first).id
        await chat.held.wait()
        let task = try await cdTask(first)
        try await first.harness.close(context: .background)
        let second = try await openChat(storage: SqliteStorage.open(path: path), setup: chat.setup)
        try await second.harness.commit({ tx in try await tx.doc(CodemodeJournalDoc, taskId: task).child("entries")!.child(0)!.remove("issuedAfter") }, context: .background)
        try second.harness.resume()
        try await eventually {
            let journal = try await second.harness.snapshot(CodemodeJournalDoc, taskId: task, context: .background)
            return journal?["entries"]?[0]?["issuedAfter"] == 2
        }
        #expect(chat.runs.values.filter { $0 == "a" }.count == 1)
        #expect(try await second.harness.snapshot(CodemodeRunDoc, taskId: task, context: .background)?["result"] == nil)
        try await second.harness.close(context: .background)
        chat.block.value = false
        let third = try await openChat(storage: SqliteStorage.open(path: path), setup: chat.setup)
        try third.harness.resume(); try await cdWait(third, id)
        #expect(!(try await cdResult(third)).isError)
        try await third.harness.close(context: .background)
    }

    // :441 and497. Running rows become cancelled and their owned child tasks are aborted.
    @Test func detailsIncludeFailedAndCancelledCalls() async throws {
        let chat = try CDChat { state in
            switch state.seq {
            case 0: .init(calls: [cdHold, cdEcho("a")])
            case 1: .init(calls: [.init(name: "fails", args: [:])])
            default: .init(result: .init(value: 1))
            }
        }
        try installHarnessTool(ToolRegistration(name: "fails", description: "fails", parameters: ["type": "object"]) { _, _, _ in .init(output: [.text(.init(text: "permission denied"))], isError: true) }, setup: chat.setup)
        try chat.responses()
        let opened = try await openChat(setup: chat.setup)
        let id = try await generationSubmit(opened).id
        try await cdWait(opened, id)
        let message = try await cdResult(opened)
        let calls = try #require(harnessToolDetails(message)?["calls"]?.arrayValue)
        #expect(calls.map { $0["id"] } == [1, 2, 3])
        #expect(calls.map { $0["name"] } == ["hold", "echo", "fails"])
        #expect(calls.map { $0["args"] } == ["{}", "{\"text\":\"a\"}", "{}"])
        #expect(calls.map { $0["status"] } == ["cancelled", "ok", "error"])
        #expect(calls[2]["error"] == "permission denied")
        #expect(calls[1]["durationMs"]?.numberValue ?? -1 >= 0)
        #expect(chat.runs.values.filter { $0 == "hold" }.count == 1)
        let hold = try #require(try await cdNested(opened).first { $0.input["call"]?["name"] == "hold" })
        #expect(hold.state.status == "terminal")
        if case .terminal(let outcome, _) = hold.state { #expect(outcome.status == "aborted") }
        try await opened.harness.close(context: .background)
    }

    // :515. A call made in a terminal drain is never admitted.
    @Test func terminalDrainAdmitsNoFireAndForgetCall() async throws {
        let chat = try CDChat { _ in .init(calls: [cdEcho("late")], result: .init(value: 1)) }
        try chat.responses()
        let opened = try await openChat(setup: chat.setup)
        try await cdWait(opened, generationSubmit(opened).id)
        #expect(chat.runs.values.isEmpty)
        #expect(try await cdNested(opened).isEmpty)
        try await opened.harness.close(context: .background)
    }

    // :791 and812. Compatibility gates run before the VM or new child admission.
    @Test(arguments: ["fingerprint", "version", "deadline"])
    func incompatibleOrExpiredStartsAdmitNoNewCalls(_ field: String) async throws {
        let chat = try CDChat { state in state.seq == 0 ? .init(calls: [cdHold]) : .init(result: .init(value: "done")) }
        let result = try await cdRestart(chat, mutate: { opened, task in
            try await cdMutateStart(opened, task, key: field, value: field == "fingerprint" ? "another sandbox" : field == "version" ? 0 : 1)
        })
        #expect(result.message.isError)
        #expect(cdText(result.message).contains(field == "deadline" ? "deadline passed" : "cannot resume"))
        #expect(result.starts.count == (field == "fingerprint" ? 2 : 1))
        #expect(result.tasks.count == 1)
    }

    // :666,686,732. Script results are mapped from nested program values, not model output.
    @Test(arguments: ["plainError", "structuredError", "missingStructured", "images", "imagesOnly"])
    func nestedResultMapping(_ kind: String) async throws {
        let chat = try CDChat { state in
            if state.seq == 0 { return .init(calls: [.init(name: "probe", args: [:])]) }
            let outcome = state.deliveries[0].outcome
            switch outcome {
            case .success(let value): return .init(result: .init(value: ["value": value ?? .null]))
            case .failure(let message, let properties): return .init(result: .init(value: ["error": .string(message), "properties": .object(properties)]))
            }
        }
        let schema: JSONObject? = kind == "structuredError" || kind == "missingStructured" ? ["type": "object", "properties": ["output": ["type": "string"], "exitCode": ["type": "number"]]] : nil
        try installHarnessTool(ToolRegistration(name: "probe", description: "probe", parameters: ["type": "object"], structuredOutputSchema: schema) { _, _, _ in
            let image = kind.hasPrefix("images")
            return .init(output: (kind == "imagesOnly" ? [] : [.text(.init(text: image ? "a cat" : "permission denied"))]) + (image ? [.image(.init(data: "AA==", mimeType: "image/png"))] : []),
                structuredOutput: kind == "structuredError" ? ["output": "no matches", "exitCode": 1] : nil, isError: !image)
        }, setup: chat.setup)
        try chat.responses()
        let opened = try await openChat(setup: chat.setup)
        try await cdWait(opened, generationSubmit(opened).id)
        let text = try await cdText(cdResult(opened))
        #expect(text.contains(kind == "structuredError" ? "\"exitCode\":1" : kind == "images" ? "\"value\":\"a cat\"" : kind == "imagesOnly" ? "\"value\":\"\"" : "\"error\":\"permission denied\""))
        if kind == "plainError" { #expect(text.contains("\"structuredOutput\":\"permission denied\"")) }
        if kind == "missingStructured" { #expect(text.contains("\"properties\":{}")) }
        try await opened.harness.close(context: .background)
    }
}

extension CodemodeDurableTests {
    // :467. A sandbox close stops this invocation without deciding a stored result.
    @Test func hostSandboxCloseLeavesNoOutcomeAndCanReplay() async throws {
        let directory = try sqliteTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("closed.sqlite").path
        let chat = try CDChat(plan: cdSequential)
        try chat.responses()
        let first = try await openChat(storage: SqliteStorage.open(path: path), setup: chat.setup)
        let id = try await generationSubmit(first).id
        await chat.held.wait()
        let task = try await cdTask(first)
        await chat.sandbox.close()
        #expect(try await first.harness.snapshot(CodemodeRunDoc, taskId: task, context: .background)?["result"] == nil)
        try await first.harness.close(context: .background)
        chat.block.value = false
        let replacement = DeterministicCodemodeSandbox(plan: cdSequential)
        try chat.setup.registry.install(createCodemodeExtension(options: .init(sandbox: replacement, models: false)))
        let second = try await openChat(storage: SqliteStorage.open(path: path), setup: chat.setup)
        try second.harness.resume(); try await cdWait(second, id)
        #expect(!(try await cdResult(second)).isError)
        #expect(chat.runs.values.filter { $0 == "a" }.count == 1)
        try await second.harness.close(context: .background)
    }

    // :760. A failed journal write cannot deliver a result or launch its successor.
    @Test func failedJournalCommitPreventsDelivery() async throws {
        let storage = ControlledStorage(), seen = SessionTestLog<String>()
        let chat = try CDChat(globals: [
            .init(name: "first", execute: { _, _, _ in
                seen.append("first"); await storage.failNextCommit(TaskDefinitionError("lost")); return 1
            }),
            .init(name: "second", execute: { _, _, _ in seen.append("second"); return 2 })
        ]) { state in
            if state.seq == 0 { return .init(calls: [.init(target: .global, name: "first")]) }
            if state.seq == 1 { return .init(calls: [.init(target: .global, name: "second")]) }
            return .init(result: .init())
        }
        try chat.responses()
        let opened = try await openChat(storage: storage, setup: chat.setup)
        _ = try await generationSubmit(opened)
        _ = await opened.harness.closed
        #expect(seen.values == ["first"])
        try? await opened.harness.close(context: .background)
    }

    // :827. The committed code mode outcome is returned without another sandbox start.
    @Test func decidedOutcomeIsReturnedAfterRestartWithoutStartingSandbox() async throws {
        let directory = try sqliteTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("decided.sqlite").path
        let block = Mutex(true), reached = HarnessChatSignal()
        let chat = try CDChat { _ in .init(result: .init(value: "first", storeWrites: .init(set: ["k": 1]))) }
        try chat.setup.registry.install(Extension(name: "after-codemode", hooks: [hook(ToolHooks(afterTool: { call, _, _, context in
            if call.name == "codemode", block.withLock({ $0 }) { reached.signal(); try await harnessToolAwaitAbort(context) }
            return nil
        }))]))
        try chat.responses()
        let first = try await openChat(storage: SqliteStorage.open(path: path), setup: chat.setup)
        let id = try await generationSubmit(first).id
        await reached.wait()
        let task = try await cdTask(first)
        #expect(try await first.harness.snapshot(CodemodeRunDoc, taskId: task, context: .background)?["result"] != nil)
        #expect(try await first.harness.snapshot(CodemodeStoreDoc, conversationId: first.root.id, context: .background)?["values"]?["k"] == 1)
        try await first.harness.close(context: .background)
        block.withLock { $0 = false }
        let second = try await openChat(storage: SqliteStorage.open(path: path), setup: chat.setup)
        try second.harness.resume(); try await cdWait(second, id)
        #expect(cdText(try await cdResult(second)).contains("first"))
        #expect(await chat.sandbox.starts.count == 1)
        try await second.harness.close(context: .background)
    }

    // :857. Store writes share the final result commit and forks see the entry boundary.
    @Test func storeWritesAreAtomicAndForksUseEntryValues() async throws {
        let chat = try CDChat { state in
            state.source == "save" ? .init(result: .init(value: 1, storeWrites: .init(set: ["k": 1]))) : .init(result: .init(value: [state.options.store["k"] ?? .null]))
        }
        try chat.responses("save")
        let opened = try await openChat(setup: chat.setup)
        let publications = SessionTestLog<CommitPublication>()
        let subscription = try opened.harness.subscribeCommits { value, _ in publications.append(value) }
        try await cdWait(opened, generationSubmit(opened).id)
        let user = try #require(try await allEntries(opened.root).first { $0.kind == "pi.user" })
        let atom = publications.values.first { value in
            let kinds = value.changes.compactMap { if case .document(let change) = $0 { return change.record.kind }; return nil }
            let final = value.changes.contains { item in
                guard case .document(let change) = item, change.record.kind == "pi.codemode.run" else { return false }
                return change.value?["result"] != nil || change.ops.contains { op in
                    if case .set(let path, _) = op { return path == [.key("result")] }
                    if case .replace(let value) = op { return value["result"] != nil }
                    return false
                }
            }
            return final && kinds.contains("pi.codemode.store")
        }
        #expect(atom != nil)
        try chat.responses("read")
        try await cdWait(opened, generationSubmit(opened).id)
        #expect(cdText(try await cdResult(opened)).contains("[1]"))
        let fork = try await opened.root.fork(at: user.id, options: .init(ownership: .ownerless()), context: .background)
        try chat.responses("read")
        let forked = OpenChatResult(harness: opened.harness, root: fork)
        try await cdWait(forked, generationSubmit(forked).id)
        #expect(cdText(try await cdResult(forked)).contains("[null]"))
        subscription.cancel()
        try await opened.harness.close(context: .background)
    }

    // :882. A shared completion burst is journaled in batches.
    @Test func concurrentGlobalResultsUseBatchedJournalCommits() async throws {
        let gate = HarnessChatSignal(), count = Mutex(0)
        let chat = try CDChat(globals: [.init(name: "wait", execute: { _, _, _ in
            if count.withLock({ $0 += 1; return $0 }) == 50 { gate.signal() }
            await gate.wait(); return .null
        })]) { state in
            if state.seq == 0 { return .init(calls: Array(repeating: .init(target: .global, name: "wait"), count: 50)) }
            return state.seq == 50 ? .init(result: .init(value: 50)) : .init()
        }
        try chat.responses()
        let opened = try await openChat(setup: chat.setup)
        let commits = Mutex(0)
        let subscription = try opened.harness.subscribeCommits { value, _ in
            if value.changes.contains(where: { if case .document(let change) = $0 { return change.record.kind == "pi.codemode.journal" }; return false }) { commits.withLock { $0 += 1 } }
        }
        try await cdWait(opened, generationSubmit(opened).id)
        #expect(cdText(try await cdResult(opened)).contains("50"))
        #expect(commits.withLock { $0 } < 10)
        subscription.cancel()
        try await opened.harness.close(context: .background)
    }
}

extension CodemodeDurableTests {
    @Test func nestedCallPreviewsUseUTF16Bounds() async throws {
        let long = String(repeating: "😀", count: 300)
        let chat = try CDChat { state in
            switch state.seq {
            case 0: .init(calls: [cdEcho(long)])
            case 1: .init(calls: [.init(name: "fails", args: [:])])
            default: .init(result: .init(value: 1))
            }
        }
        try installHarnessTool(ToolRegistration(name: "fails", description: "fails", parameters: ["type": "object"]) { _, _, _ in
            .init(output: [.text(.init(text: long))], isError: true)
        }, setup: chat.setup)
        try chat.responses()
        let opened = try await openChat(setup: chat.setup)
        try await cdWait(opened, generationSubmit(opened).id)
        let message = try await cdResult(opened)
        let rows = try #require(harnessToolDetails(message)?["calls"]?.arrayValue)
        #expect(rows[0]["args"]?.stringValue?.utf16.count == 200)
        #expect(rows[1]["error"]?.stringValue?.utf16.count == 500)
        try await opened.harness.close(context: .background)
    }
}

extension CodemodeDurableTests {
    @Test func replayPreflightUsesExactToolNameCodeUnits() async throws {
        let old = "caf\u{E9}", changed = "cafe\u{301}"
        let seen = SessionTestLog<String>()
        let chat = try CDChat { state in
            if state.seq == 0 {
                let altered = state.options.store["k"] != nil
                return .init(calls: [.init(name: altered ? changed : old, args: [:]), altered ? cdEcho("late") : cdHold])
            }
            return .init()
        }
        for name in [old, changed] {
            try installHarnessTool(ToolRegistration(name: name, description: name, parameters: ["type": "object"], replay: .safe) { _, _, _ in
                seen.append(name); return .init(output: [])
            }, setup: chat.setup)
        }
        let result = try await cdRestart(chat, beforeClose: { opened, task in
            try await eventually {
                let journal = try await opened.harness.snapshot(CodemodeJournalDoc, taskId: task, context: .background)
                return journal?["entries"]?.arrayValue?.contains { $0["id"] == 1 } == true
            }
        }, mutate: { opened, task in
            try await cdMutateStart(opened, task, key: "store", value: ["k": true])
            try await opened.harness.commit({ tx in try await tx.doc(CodemodeJournalDoc, taskId: task).set("entries", []) }, context: .background)
        })
        #expect(result.message.isError)
        #expect(seen.values.count == 1)
        #expect(!chat.runs.values.contains("late"))
    }
}

extension CodemodeDurableTests {
    @Test func storePreservesDistinctUnicodeKeysAcrossCalls() async throws {
        let first = "caf\u{E9}", second = "cafe\u{301}"
        let chat = try CDChat { state in
            if state.source == "save" {
                return .init(result: .init(value: 1, storeWrites: .init(set: JSONObject([(first, 1), (second, 2)]))))
            }
            return .init(result: .init(value: [state.options.store[first] ?? .null, state.options.store[second] ?? .null]))
        }
        try chat.responses("save")
        let opened = try await openChat(setup: chat.setup)
        try await cdWait(opened, generationSubmit(opened).id)
        let store = try await opened.harness.snapshot(CodemodeStoreDoc, conversationId: opened.root.id, context: .background)
        #expect(store?["values"]?.objectValue?.count == 2)
        try chat.responses("read")
        try await cdWait(opened, generationSubmit(opened).id)
        #expect(cdText(try await cdResult(opened)).contains("[1,2]"))
        try await opened.harness.close(context: .background)
    }
}
