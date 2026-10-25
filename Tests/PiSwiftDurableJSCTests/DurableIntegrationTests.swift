import Foundation
import Synchronization
import Testing
import PiSwiftAI
import PiSwiftChord
import PiSwiftDurable
import PiSwiftDurableJSC
import PiSwiftDurableTesting

// These tests use the real JavaScript engine. The wrapper observes delivery and
// changes one input for the tests that must detect a different replay path.
private actor DIObservedRun: CodemodeRun {
    let base: any CodemodeRun
    let observe: @Sendable (Int, Int) async throws -> Void
    init(_ base: any CodemodeRun, observe: @escaping @Sendable (Int, Int) async throws -> Void) {
        self.base = base; self.observe = observe
    }
    var result: CodemodeResult { get async { await base.result } }
    var finished: Bool { get async { await base.finished } }
    func deliver(seq: Int, now: Double, id: Int, outcome: CodemodeOutcome) async throws {
        try await observe(seq, id)
        try await base.deliver(seq: seq, now: now, id: id, outcome: outcome)
    }
    func abort(message: String) async { await base.abort(message: message) }
}

private actor DIObservedSandbox: CodemodeSandbox {
    enum Change: Sendable, Equatable { case none, source, seed, fingerprint }
    struct Start: Sendable {
        let source: String
        let name: String
        let options: CodemodeRunOptions
    }
    let base: JSCCodemodeSandbox
    #if os(macOS)
    let alternate: JSCCodemodeSandbox
    #endif
    let change: Change
    let fixed: (Double, UInt32)?
    let observe: @Sendable (Int, Int) async throws -> Void
    private(set) var starts: [Start] = []
    init(forceWatchdog: Bool, change: Change = .none, fixed: (Double, UInt32)? = nil,
         observe: @escaping @Sendable (Int, Int) async throws -> Void = { _, _ in }) {
        base = JSCCodemodeSandbox(forceWatchdog: forceWatchdog)
        #if os(macOS)
        alternate = JSCCodemodeSandbox(forceWatchdog: !forceWatchdog)
        #endif
        self.change = change; self.fixed = fixed; self.observe = observe
    }
    func start(source: String, name: String, options: CodemodeRunOptions) async throws -> any CodemodeRun {
        starts.append(Start(source: source, name: name, options: options))
        let second = starts.count > 1
        let holder = Mutex<DIObservedRun?>(nil)
        var altered = options
        if let fixed { altered.startedAt = fixed.0; altered.seed = fixed.1 }
        if second, change == .seed { altered.seed = options.seed &+ 1 }
        let observe = self.observe
        let change = self.change
        altered.onStarted = { fingerprint, run in
            let wrapped = DIObservedRun(run, observe: observe)
            holder.withLock { $0 = wrapped }
            #if os(macOS)
            await options.onStarted(fingerprint, wrapped)
            #else
            // iOS always uses the watchdog. Change the reported fingerprint there.
            await options.onStarted(second && change == .fingerprint ? fingerprint + "-changed" : fingerprint, wrapped)
            #endif
        }
        altered.onCall = { call, _ in
            if let run = holder.withLock({ $0 }) { await options.onCall(call, run) }
        }
        altered.onIdle = { seq, issued, _ in
            if let run = holder.withLock({ $0 }) { await options.onIdle(seq, issued, run) }
        }
        let changedSource = second && change == .source
            ? source.replacingOccurrences(of: "text: \"a\"", with: "text: \"changed\"") : source
        #if os(macOS)
        // Resume with the other real backend to test its runtime fingerprint.
        let engine = second && change == .fingerprint ? alternate : base
        #else
        let engine = base
        #endif
        _ = try await engine.start(source: changedSource, name: name, options: altered)
        return try #require(holder.withLock { $0 })
    }
    func close() async {
        await base.close()
        #if os(macOS)
        await alternate.close()
        #endif
    }
}

private final class DIChatState: Sendable {
    let runs = Mutex<[String]>([])
    let blocked = Mutex(true)
}

private final class DIChat: Sendable {
    let setup = HarnessChatSetup()
    let sandbox: DIObservedSandbox
    let state = DIChatState()
    let held = HarnessChatSignal()
    init(forceWatchdog: Bool, change: DIObservedSandbox.Change = .none,
         fixed: (Double, UInt32)? = nil,
         observe: @escaping @Sendable (Int, Int) async throws -> Void = { _, _ in }) throws {
        sandbox = DIObservedSandbox(forceWatchdog: forceWatchdog, change: change, fixed: fixed, observe: observe)
        try setup.registry.install(createCodemodeExtension(options: .init(sandbox: sandbox,
            namespaces: [.init(name: "github", prefix: "mcp__github__", description: "GitHub tools")], models: false)))
        try add(ToolRegistration(name: "echo", description: "echo", parameters: ["type": "object"], replay: .safe) { [state] args, _, _ in
            let text = args["text"]?.stringValue ?? ""
            state.runs.withLock { $0.append(text) }
            return .init(output: [.text(.init(text: "echo " + text))])
        })
        try add(ToolRegistration(name: "hold", description: "hold", parameters: ["type": "object"], replay: .safe) { [state, held] _, _, context in
            state.runs.withLock { $0.append("hold") }
            held.signal()
            if state.blocked.withLock({ $0 }) { try await diAwaitAbort(context) }
            return .init(output: [.text(.init(text: "held"))])
        })
    }
    func add(_ tool: ToolRegistration) throws {
        try setup.registry.install(Extension(name: "di-tool-" + tool.name, tools: [tool]))
    }
    func responses(_ source: String) {
        var call = chatAssistant("", reason: .toolUse)
        call.content = [.toolCall(ToolCall(id: "di-code", name: "codemode", arguments: ["code": AnyCodable(source)]))]
        setup.models.setResponses([.message(call), .message(chatAssistant("done"))])
    }
}

private func diAwaitAbort(_ context: ChordContext) async throws {
    let signal = try #require(context.abortSignal), gate = HarnessChatSignal()
    let registration = signal.addAbortListener { _ in gate.signal() }
    defer { signal.removeAbortListener(registration) }
    if signal.aborted { gate.signal() }
    await gate.wait()
    try signal.throwIfAborted()
}
private func diTask(_ opened: OpenChatResult) async throws -> TaskID {
    let tasks = try await opened.harness.commit({ tx in
        try await tx.scanTasks(.init(kind: "pi.tool"), limit: 100).items
    }, context: .background)
    return try #require(tasks.first { $0.input["kind"] == "model" }).id
}
private func diNested(_ opened: OpenChatResult) async throws -> [TaskRecord] {
    try await opened.harness.commit({ tx in
        try await tx.scanTasks(.init(kind: "pi.tool"), limit: 100).items.filter { $0.input["kind"] == "nested" }
    }, context: .background)
}
private func diMessage(_ opened: OpenChatResult) async throws -> JSONValue {
    try #require(await allEntries(opened.root).last { $0.kind == "pi.tool-result" }?.model?.first)
}
private func diText(_ message: JSONValue) -> String {
    message["content"]?.arrayValue?.compactMap { $0["text"]?.stringValue }.joined() ?? ""
}
private func diOutput(_ message: JSONValue) -> String {
    let text = diText(message)
    guard let marker = text.range(of: "\nOutput:\n") else { return text }
    return String(text[marker.upperBound...])
}
private func diWait(_ opened: OpenChatResult, _ id: SubmissionID) async throws {
    let submission = try #require(try await opened.harness.submission(id: id, context: .background))
    let observer = settled { try await submission.wait(context: .background) }
    try await eventually(timeout: .seconds(15)) { observer.isSettled }
    #expect(try #require(observer.result).get().status == "done")
    try await opened.harness.waitForIdle(context: .background)
}
private func diRun(_ chat: DIChat, source: String) async throws -> JSONValue {
    chat.responses(source)
    let opened = try await openChat(setup: chat.setup)
    do {
        let id = try await opened.root.submit(.input(content: .text("go")), context: .background).id
        try await diWait(opened, id)
        let message = try await diMessage(opened)
        try await opened.harness.close(context: .background)
        await chat.sandbox.close()
        return message
    } catch {
        try? await opened.harness.close(context: .background)
        await chat.sandbox.close()
        throw error
    }
}
private struct DIRestartResult: Sendable {
    let message: JSONValue
    let nested: [TaskRecord]
    let starts: [DIObservedSandbox.Start]
}
private func diRestart(_ chat: DIChat, source: String,
    beforeClose: @Sendable (OpenChatResult, TaskID) async throws -> Void = { _, _ in },
    mutate: @Sendable (OpenChatResult, TaskID) async throws -> Void = { _, _ in },
    replacement: DIObservedSandbox? = nil
) async throws -> DIRestartResult {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pi-jsc-di-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let path = directory.appendingPathComponent("session.sqlite").path
    chat.responses(source)
    let first = try await openChat(storage: SqliteStorage.open(path: path), setup: chat.setup)
    let id = try await first.root.submit(.input(content: .text("go")), context: .background).id
    do {
        try await eventually(timeout: .seconds(15)) { chat.held.isSignalled }
        let task = try await diTask(first)
        try await eventually {
            let journal = try await first.harness.snapshot(CodemodeJournalDoc, taskId: task, context: .background)
            return journal?["entries"]?.arrayValue?.last?["issuedAfter"] != nil || journal?["firstIssued"] != nil && journal?["entries"]?.arrayValue?.isEmpty == true
        }
        try await beforeClose(first, task)
        try await first.harness.close(context: .background)
        if let replacement {
            try chat.setup.registry.install(createCodemodeExtension(options: .init(sandbox: replacement, models: false)))
        }
        let second = try await openChat(storage: SqliteStorage.open(path: path), setup: chat.setup)
        do {
            try await mutate(second, task)
            chat.state.blocked.withLock { $0 = false }
            try second.harness.resume()
            try await diWait(second, id)
            let result = try await DIRestartResult(message: diMessage(second), nested: diNested(second), starts: chat.sandbox.starts)
            try await second.harness.close(context: .background)
            await chat.sandbox.close()
            if let replacement { await replacement.close() }
            return result
        } catch {
            try? await second.harness.close(context: .background)
            throw error
        }
    } catch {
        try? await first.harness.close(context: .background)
        await chat.sandbox.close()
        if let replacement { await replacement.close() }
        throw error
    }
}

@Suite("PiSwiftDurableJSC Codemode durable integration", .timeLimit(.minutes(1)))
struct CodemodeDurableIntegrationTests {
    // Upstream v1.3.0 codemode.test.ts:193. Check the journal at the delivery boundary.
    @Test(arguments: [false, true]) func journalCommitsBeforeRealJavaScriptReceivesResults(_ watchdog: Bool) async throws {
        let current = Mutex<OpenChatResult?>(nil)
        let delivered = Mutex<[Int]>([])
        let chat = try DIChat(forceWatchdog: watchdog, observe: { seq, id in
            let opened = try #require(current.withLock { $0 })
            let task = try await diTask(opened)
            let journal = try #require(try await opened.harness.snapshot(CodemodeJournalDoc, taskId: task, context: .background))
            #expect(journal["entries"]?[seq - 1]?["id"] == .number(Double(id)))
            delivered.withLock { $0.append(id) }
        })
        chat.responses("const a = await tools.echo({text: 'a'}); const b = await tools.echo({text: 'b'}); return [a, b];")
        let opened = try await openChat(setup: chat.setup)
        current.withLock { $0 = opened }
        let id = try await opened.root.submit(.input(content: .text("go")), context: .background).id
        try await diWait(opened, id)
        let message = try await diMessage(opened)
        #expect(message["isError"] == false)
        #expect(diOutput(message) == "[\"echo a\",\"echo b\"]")
        #expect(delivered.withLock { $0 } == [1, 2])
        #expect(try await diNested(opened).count == 2)
        try await opened.harness.close(context: .background)
        await chat.sandbox.close()
    }

    // :207 and254. Use the same clock and seed for an uninterrupted comparison.
    @Test(arguments: [false, true]) func restartReplaysDeliveredResultsWithTheSameClockAndSeed(_ watchdog: Bool) async throws {
        let source = """
        const before = [Date.now(), Math.random()];
        const a = await tools.echo({text: "a"});
        const held = await tools.hold({});
        const b = await tools.echo({text: "b"});
        return [before, a, held, b, Math.random()];
        """
        let chat = try DIChat(forceWatchdog: watchdog)
        let result = try await diRestart(chat, source: source)
        #expect(result.message["isError"] == false)
        #expect(result.starts.count == 2)
        let first = try #require(result.starts.first)
        let second = try #require(result.starts.last)
        #expect(first.options.startedAt == second.options.startedAt)
        #expect(first.options.seed == second.options.seed)
        #expect(first.source == second.source)
        #expect(first.name == second.name)
        #expect(result.nested.count == 3)
        #expect(Set(result.nested.compactMap { $0.input["key"]?.stringValue }) == ["c1", "c2", "c3"])
        #expect(chat.state.runs.withLock { $0 } == ["a", "hold", "hold", "b"])
        let uninterrupted = try DIChat(forceWatchdog: watchdog, fixed: (first.options.startedAt, first.options.seed))
        uninterrupted.state.blocked.withLock { $0 = false }
        let expected = try await diRun(uninterrupted, source: source)
        #expect(diOutput(result.message) == diOutput(expected))
    }

    // :269-390. Change VM input, while the saved nested calls stay unchanged.
    @Test(arguments: [false, true]) func changedSourceAndSeedRefuseReplay(_ watchdog: Bool) async throws {
        for change in [DIObservedSandbox.Change.source, .seed] {
            let chat = try DIChat(forceWatchdog: watchdog, change: change)
            let result = try await diRestart(chat, source: """
            const a = await tools.echo({text: "a"});
            await tools.echo({text: String(Math.random())});
            await tools.hold({});
            await tools.echo({text: "late"});
            return a;
            """)
            #expect(result.message["isError"] == true)
            #expect(diText(result.message).contains("different path"))
            #expect(!chat.state.runs.withLock { $0.contains("changed") || $0.contains("late") })
            #expect(result.nested.count == 3)
        }
    }

    // :791 and812. Neither failure can admit the call after hold.
    @Test(arguments: [false, true]) func changedFingerprintAndExpiredDeadlineRefuseResume(_ watchdog: Bool) async throws {
        for expired in [false, true] {
            let chat = try DIChat(forceWatchdog: watchdog, change: expired ? .none : .fingerprint)
            let result = try await diRestart(chat, source: "await tools.hold({}); await tools.echo({text: 'late'});", mutate: { opened, task in
                if expired {
                    try await opened.harness.commit({ tx in
                        try await tx.doc(CodemodeRunDoc, taskId: task).child("start")!.set("deadline", 1)
                    }, context: .background)
                }
            })
            #expect(result.message["isError"] == true)
            #expect(diText(result.message).contains(expired
                ? "Script timed out: its deadline passed while it was interrupted."
                : "The script cannot resume: the sandbox changed since it started ("))
            #expect(result.starts.count == (expired ? 1 : 2))
            #expect(result.nested.count == 1)
            #expect(!chat.state.runs.withLock { $0.contains("late") })
        }
    }

    // :467. Close the VM before the Harness. A new VM must replay the call.
    @Test(arguments: [false, true]) func sandboxCloseLeavesNoStoredOutcomeAndCanResume(_ watchdog: Bool) async throws {
        let chat = try DIChat(forceWatchdog: watchdog)
        let replacement = DIObservedSandbox(forceWatchdog: watchdog)
        let result = try await diRestart(chat, source: """
        const a = await tools.echo({text: "a"});
        await tools.hold({});
        return a;
        """, beforeClose: { opened, task in
            await chat.sandbox.close()
            let snapshot = try await opened.harness.snapshot(CodemodeRunDoc, taskId: task, context: .background)
            #expect(snapshot?["result"] == nil)
        }, replacement: replacement)
        #expect(result.message["isError"] == false)
        #expect(diOutput(result.message) == "echo a")
        #expect(chat.state.runs.withLock { $0.filter { $0 == "a" }.count } == 1)
        #expect(await replacement.starts.count == 1)
    }

    // :857 and the output/search cases. All bindings run in JavaScript.
    @Test(arguments: [false, true]) func storeOutputAndDiscoveryUseRealJavaScriptBindings(_ watchdog: Bool) async throws {
        let chat = try DIChat(forceWatchdog: watchdog)
        try chat.add(ToolRegistration(name: "mcp__github__list_issues", description: "List issues", parameters: ["type": "object"], deferred: true) { _, _, _ in
            .init(output: [.text(.init(text: "issues"))])
        })
        chat.responses("store('answer', 42); text('one'); console.log('log', 1); return load('answer');")
        let opened = try await openChat(setup: chat.setup)
        try await diWait(opened, opened.root.submit(.input(content: .text("save")), context: .background).id)
        let first = try await diMessage(opened)
        #expect(first["isError"] == false)
        #expect(diText(first).contains("==> text 1/2 <==\none"))
        #expect(diText(first).contains("<console_output>\nlog 1\n</console_output>"))
        #expect(diText(first).contains("==> text 2/2 <==\n42"))
        #expect(try await opened.harness.snapshot(CodemodeStoreDoc, conversationId: opened.root.id, context: .background)?["values"]?["answer"] == 42)
        chat.responses("""
        const found = await searchTools("issues");
        const described = await describeTool("echo");
        const namespace = await describeNamespace("github");
        return [load("answer"), found.map(x => x.name), described.includes("echo(args:"),
            namespace.tools, ALL_TOOLS.some(x => x.name === "mcp__github__list_issues"),
            await tools.mcp__github__list_issues({})];
        """)
        try await diWait(opened, opened.root.submit(.input(content: .text("read")), context: .background).id)
        let second = try await diMessage(opened)
        #expect(second["isError"] == false)
        #expect(diOutput(second) == "[42,[\"mcp__github__list_issues\"],true,[\"mcp__github__list_issues\"],true,\"issues\"]")
        try await opened.harness.close(context: .background)
        await chat.sandbox.close()
    }
}
