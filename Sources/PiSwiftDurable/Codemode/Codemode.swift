import Foundation
import PiSwiftAI
import PiSwiftChord

/// The version of the durable script data and result mapping.
public let CODEMODE_MODULE_VERSION = 2
/// The tool name used for raw JavaScript calls.
public let CODEMODE_TOOL_NAME = "codemode"

/// A host function. Its result is saved before the script receives it.
public struct CodemodeGlobal: Sendable {
    public var name: String
    public var spread: Bool
    public var execute: @Sendable (JSONValue?, ToolExecutionApi, ChordContext) async throws -> JSONValue?
    public init(name: String, spread: Bool = false,
                execute: @escaping @Sendable (JSONValue?, ToolExecutionApi, ChordContext) async throws -> JSONValue?) {
        self.name = name; self.spread = spread; self.execute = execute
    }
}
/// The sandbox and host services for code mode.
public struct CodemodeToolOptions: Sendable {
    public var sandbox: any CodemodeSandbox
    public var namespaces: [CodemodeNamespace]
    public var inlineBudget: Int
    public var models: Bool
    public var globals: [CodemodeGlobal]
    public init(sandbox: any CodemodeSandbox, namespaces: [CodemodeNamespace] = [], inlineBudget: Int = 3000,
                models: Bool = true, globals: [CodemodeGlobal] = []) {
        self.sandbox = sandbox; self.namespaces = namespaces; self.inlineBudget = inlineBudget
        self.models = models; self.globals = globals
    }
}
/// Raw JavaScript supplied to the code mode tool.
public struct CodemodeToolInput: Sendable, Codable {
    public var code: String
    public init(code: String) { self.code = code }
}
/// Creates a replay-safe tool that calls the conversation's tools.
public func createCodemodeTool(options: CodemodeToolOptions) throws -> ToolRegistration {
    var tool = try defineTool(name: CODEMODE_TOOL_NAME, description: codemodeDescription(models: options.models),
        parameters: ["type": "object", "properties": ["code": ["type": "string", "description": "Raw JavaScript source."]], "required": ["code"]],
        args: CodemodeToolInput.self, replay: .safe, callers: [.model],
        outputLimits: .init(maxBytes: 4 * 1024 * 1024, maxLines: 100_000)) { args, api, context in
            try await DurableCodemodeCall(options: options, api: api, context: context).execute(args.code)
        }
    tool.declaration.constrainedSampling = codemodeConstrainedSampling
    tool.orderedDeclaration["constrainedSampling"] = ["type": "grammar", "variants": ["openai_lark": .string(codemodeSourceGrammar)]]
    return tool
}
/// Creates the code mode tool, model tools, and prompt section.
public func createCodemodeExtension(options: CodemodeToolOptions) throws -> Extension {
    try Extension(name: "codemode", tools: [createCodemodeTool(options: options)] + (options.models ? codemodeModelTools() : []),
        sections: [section("codemode") { input, _ in
            try codemodeSection(tools: input.agent.callable.filter { !codemodeHasPrefix($0.name, "pi.codemode.") && $0.deferred != true },
                namespaces: options.namespaces, inlineBudget: options.inlineBudget)
        }])
}

private let discoveryNames = ["searchTools", "describeTool", "describeNamespace"]
private let catalogNames = ["models.getModelsOfType", "models.getAvailableOfType", "models.getModelOfType"]
private let modelNames = ["models.classify", "models.generateImages"]
private func codemodeHasPrefix(_ name: String, _ prefix: String) -> Bool { name.utf16.starts(with: prefix.utf16) }
private func cut(_ value: String, _ max: Int) -> String { value.utf16.count > max ? String(decoding: value.utf16.prefix(max - 3), as: UTF16.self) + "..." : value }
private func failureResult(_ message: String) -> ToolExecutionResult { .init(output: [.text(.init(text: message))], isError: true) }

/// One actor serializes journal commits and script deliveries.
internal actor DurableCodemodeCall {
    let options: CodemodeToolOptions
    let api: ToolExecutionApi
    let context: ChordContext
    var run: (any CodemodeRun)?
    var start: CodemodeStart!
    var replayed: [CodemodeJournalEntry] = []
    var journalLength = 0
    var nextReplayed = 0
    var replaying = false
    var rerun = false
    var released = false
    var gateOpen = false
    var firstIssued: Int?
    var durableIssued = 0
    var waiting: [CodemodeHostCall] = []
    var replayIndex: [Int: Int] = [:]
    var issued = 0
    var ready: [Int: CodemodeOutcome] = [:]
    var held: [CodemodeHostCall] = []
    struct Queued: Sendable { var id: Int; var at: Double; var outcome: CodemodeOutcome; var global: CodemodeJournalEntry.Global? }
    var queue: [Queued] = []
    var acks: [Int: Int] = [:]
    var committing = false
    var deliveringReplay = false
    var releasing = false
    var ended: ToolExecutionResult?
    var failure: (any Error)?
    var rows: [Int: CodemodeNestedCall] = [:]
    var generatedImages = 0
    var modelCalls = 0
    var modelWaiters: [CheckedContinuation<Void, Never>] = []
    var finished = false

    init(options: CodemodeToolOptions, api: ToolExecutionApi, context: ChordContext) {
        self.options = options; self.api = api; self.context = context
    }
    var stopped: Bool { ended != nil || failure != nil || finished || context.abortSignal?.aborted == true }

    func execute(_ source: String) async throws -> ToolExecutionResult {
        let parsed = try parseCodemodeSource(source)
        let agent = try await api.agent(context)
        let tools = try agent.callable.map { tool in
            CodemodeStart.Tool(name: tool.name, jsName: toCodemodeIdentifier(tool.name), description: try codemodeSample(of: tool),
                structured: tool.structuredOutputSchema == nil ? nil : true, hidden: codemodeHasPrefix(tool.name, "pi.codemode.") ? true : nil)
        }
        let globals = (discoveryNames + (options.models ? catalogNames + modelNames : [])).map { CodemodeDeclaredGlobal(name: $0, spread: true) }
            + options.globals.map { CodemodeDeclaredGlobal(name: $0.name, spread: $0.spread) }
        var namespaces: [CodemodeStart.Namespace] = []
        for tool in tools where tool.hidden != true {
            guard let own = options.namespaces.filter({ codemodeHasPrefix(tool.name, $0.prefix) }).max(by: { $0.prefix.utf16.count < $1.prefix.utf16.count }) else { continue }
            if let index = namespaces.firstIndex(where: { harnessNamesEqual($0.name, own.name) }) { namespaces[index].tools.append(tool.name) }
            else { namespaces.append(.init(name: own.name, description: own.description, instructions: own.instructions, tools: [tool.name])) }
        }
        let initialTools = tools, initialNamespaces = namespaces
        let time = Double(try api.now()), seed = UInt32.random(in: UInt32.min...UInt32.max)
        enum Found: Sendable { case done(JSONObject); case resume(CodemodeStart, CodemodeJournal, Bool) }
        let found = try await api.commit({ @Sendable tx -> Found in
            let run = try await tx.doc(CodemodeRunDoc, taskId: self.api.taskId)
            if let done = try run.get("result")?.objectValue { return .done(done) }
            let oldStart = try run.get("start")
            if oldStart == nil {
                let store = try await tx.doc(CodemodeStoreDoc, conversationId: self.api.conversationId)
                let values = try store.get("values")?.objectValue ?? [:]
                let start = CodemodeStart(version: CODEMODE_MODULE_VERSION, startedAt: time, seed: seed,
                    deadline: parsed.options.timeoutMs.map { time + Double($0) }, tools: initialTools, namespaces: initialNamespaces,
                    globals: globals, maxOutputTokens: parsed.options.maxOutputTokens ?? 10000, store: values)
                try run.set("start", JSONValue(encoding: start))
            }
            let journal = try await tx.doc(CodemodeJournalDoc, taskId: self.api.taskId)
            return try .resume(run.get("start")!.decode(CodemodeStart.self), journal.snapshot().decode(CodemodeJournal.self), oldStart != nil)
        }, context: context)
        switch found {
        case .done(let result): return try codemodeDecodeToolResult(result)
        case .resume(let start, let journal, let rerun):
            self.start = start; self.replayed = journal.entries; self.firstIssued = journal.firstIssued; self.rerun = rerun
            journalLength = journal.entries.count; replaying = !journal.entries.isEmpty
            for (index, entry) in journal.entries.enumerated() { replayIndex[entry.id] = index }
            durableIssued = journal.entries.reduce(journal.firstIssued ?? 0) { max($0, $1.issuedAfter ?? 0) }
        }
        if start.version != CODEMODE_MODULE_VERSION {
            return try await decide(failureResult("The script cannot resume: it started under code mode version \(start.version), this is \(CODEMODE_MODULE_VERSION)."))
        }
        let remaining = try start.deadline.map { $0 - Double(try api.now()) }
        if let remaining, remaining <= 0 { return try await decide(failureResult("Script timed out: its deadline passed while it was interrupted.")) }
        try context.abortSignal?.throwIfAborted()
        let registration = context.abortSignal?.addAbortListener { [weak self] error in
            Task { await self?.abort(error) }
        }
        defer { if let registration { context.abortSignal?.removeAbortListener(registration) } }
        let started = try await options.sandbox.start(source: parsed.code, name: "codemode", options: .init(
            startedAt: start.startedAt, seed: start.seed,
            tools: start.tools.filter { $0.hidden != true }.map { .init(name: $0.name, jsName: $0.jsName, description: $0.description) },
            globals: start.globals, store: start.store, timeoutMs: remaining,
            onStarted: { [weak self] fingerprint, run in await self?.onStarted(fingerprint, run: run) },
            onCall: { [weak self] call, run in await self?.onCall(call, run: run) },
            onIdle: { [weak self] seq, issued, run in await self?.onIdle(seq, issued: issued, run: run) }))
        if run == nil { run = started }
        if context.abortSignal?.aborted == true { await started.abort(message: "The operation was aborted") }
        let result = await started.result
        finished = true
        if let failure { throw failure }
        if let ended { return ended }
        try context.abortSignal?.throwIfAborted()
        if result.error?.kind == .aborted {
            // A host close does not decide a durable result. Keep the invocation until its host stops it.
            if let signal = context.abortSignal {
                let (events, continuation) = AsyncStream<Void>.makeStream()
                let listener = signal.addAbortListener { _ in continuation.finish() }
                if signal.aborted { continuation.finish() }
                for await _ in events {}
                signal.removeAbortListener(listener)
                try signal.throwIfAborted()
            }
            throw TaskDefinitionError("The code mode sandbox was closed while the script ran")
        }
        if rerun, let during = result.during, during.seq <= replayed.count {
            let continued = (during.seq == 0 ? !replayed.isEmpty || firstIssued != nil : replayed[during.seq - 1].issuedAfter != nil)
                || replayed.dropFirst(during.seq).contains { $0.id > during.issued }
            if continued { return try await decide(failureResult("The script took a different path when resumed after a restart: it ended after result \(during.seq), where it went on before.")) }
        }
        return try await complete(result)
    }

    func active() async -> Bool {
        if stopped { return false }
        let terminal = await run?.finished
        return !stopped && terminal != true
    }
    func abort(_ error: any Error) async { await run?.abort(message: String(describing: error)) }
    func onStarted(_ fingerprint: String, run: any CodemodeRun) async {
        self.run = run
        do {
            if let recorded = start.fingerprint, recorded != fingerprint {
                ended = try await decide(failureResult("The script cannot resume: the sandbox changed since it started (\(recorded) -> \(fingerprint))."))
                await run.abort(message: "Sandbox fingerprint changed"); return
            }
            if start.fingerprint == nil {
                try await api.commit({ @Sendable tx in
                    let doc = try await tx.doc(CodemodeRunDoc, taskId: self.api.taskId)
                    try doc.child("start")?.set("fingerprint", .string(fingerprint))
                }, context: context)
            }
            gateOpen = true
            if replaying { await deliverReplayed() }
            else if !rerun { await release() }
        } catch { await fail(error) }
    }

    func onCall(_ made: CodemodeHostCall, run: any CodemodeRun) async {
        self.run = run
        guard await active() else { return }
        let call = asToolCall(made)
        if call.target == .tool { startedRow(call) }
        issued = max(issued, call.id)
        guard replaying, let index = replayIndex[call.id] else {
            if released { waiting.append(call); await launchCovered() } else { held.append(call) }
            return
        }
        let entry = replayed[index]
        if let global = entry.global {
            guard call.target == .global, harnessNamesEqual(call.name, global.name), sameJSON(call.args, global.args) else {
                await diverge("call \(call.id) is \(describe(call)), but was a call to \(global.name)"); return
            }
            ready[call.id] = global.outcome
            if gateOpen { await deliverReplayed() }
        } else {
            guard call.target == .tool else { await diverge("call \(call.id) is \(describe(call)), but was a tool call"); return }
            Task {
                do {
                    let outcome = try await self.callTool(call)
                    self.ready[call.id] = outcome; await self.deliverReplayed()
                } catch { await self.callFailed(call, error) }
            }
        }
    }
    func deliverReplayed() async {
        guard gateOpen, !deliveringReplay else { return }
        deliveringReplay = true
        defer { deliveringReplay = false }
        while nextReplayed < replayed.count && !stopped {
            let entry = replayed[nextReplayed]
            guard entry.id <= issued, let outcome = ready.removeValue(forKey: entry.id) else { return }
            nextReplayed += 1
            do { try await run?.deliver(seq: nextReplayed, now: entry.at, id: entry.id, outcome: outcome) }
            catch { await fail(error); return }
        }
    }
    func onIdle(_ seq: Int, issued: Int, run: any CodemodeRun) async {
        self.run = run
        guard await active() else { return }
        if rerun && seq <= replayed.count {
            let recorded = seq == 0 ? firstIssued : replayed[seq - 1].issuedAfter
            if let recorded, recorded != issued {
                await diverge(seq == 0 ? "its first run made \(issued) calls, where it had made \(recorded)" : "after result \(seq) it had made \(issued) calls, where it had made \(recorded)"); return
            }
        }
        acks[seq] = issued
        if !replaying {
            if seq == 0 && rerun { await release() }
            if seq == journalLength { await pump() }
            return
        }
        guard seq == nextReplayed else { return }
        if seq < replayed.count {
            if replayed[seq].id > issued { await diverge("it waits without making call \(replayed[seq].id), which it made before") }
            return
        }
        replaying = false
        await pump(); await release()
    }
    func release() async {
        guard gateOpen, await active(), !released, !releasing else { return }
        releasing = true
        defer { releasing = false }
        let calls = held; held = []
        if rerun {
            for call in calls {
                do {
                    if let other = try await earlier(call) { await diverge("call \(call.id) is \(describe(call)), but was \(other)"); return }
                } catch { await fail(error); return }
                if !(await active()) { return }
            }
        }
        released = true; waiting += calls + held; held = []; await launchCovered()
    }
    func launchCovered() async {
        guard released, await active() else { return }
        let covered = waiting.filter { $0.id <= durableIssued }
        waiting.removeAll { $0.id <= durableIssued }
        for call in covered { Task { await self.launch(call) } }
    }
    func earlier(_ call: CodemodeHostCall) async throws -> String? {
        guard let id = try await api.snapshot(NestedCallDoc, taskId: api.taskId, key: "c\(call.id)", context: context)?.taskId,
              let record = try await api.getTask(id: id, context: context),
              case .nested(_, _, _, let made, _) = try record.input.decode(ToolTaskInput.self) else { return nil }
        let arguments = try durableJSON(fromFoundation: made.arguments.mapValues(\.value))
        if call.target == .tool && harnessNamesEqual(made.name, call.name) && sameJSON(arguments, codemodeToolArguments(call)) { return nil }
        return "tools.\(made.name)(\(try arguments.jsonText()))"
    }
    func launch(_ call: CodemodeHostCall) async {
        guard await active() else { return }
        do {
            let outcome: CodemodeOutcome
            var global: CodemodeJournalEntry.Global?
            if call.target == .tool { outcome = try await callTool(call) }
            else {
                outcome = try await callGlobal(call)
                global = .init(name: call.name, args: call.args, outcome: outcome)
            }
            guard await active() else { return }
            queue.append(.init(id: call.id, at: Double(try api.now()), outcome: outcome, global: global)); await pump()
        } catch { await callFailed(call, error) }
    }
    func callFailed(_ call: CodemodeHostCall, _ error: any Error) async {
        guard await active() else { return }
        if context.abortSignal?.aborted == true { await fail(error) }
        else { await diverge("call \(call.id) is \(describe(call)): \(String(describing: error))") }
    }
    func pump() async {
        guard !committing, !stopped, !queue.isEmpty || !acks.isEmpty else { return }
        committing = true
        let batch = queue, counts = acks
        queue = []; acks = [:]
        do {
            try await api.commit({ @Sendable tx in
                let journal = try await tx.doc(CodemodeJournalDoc, taskId: self.api.taskId)
                for (seq, issued) in counts {
                    if seq == 0 { if try journal.get("firstIssued") == nil { try journal.set("firstIssued", .number(Double(issued))) } }
                    else if let entry = try journal.child("entries")?.child(seq - 1), try entry.get("issuedAfter") == nil { try entry.set("issuedAfter", .number(Double(issued))) }
                }
                for item in batch { try journal.child("entries")?.append(JSONValue(encoding: CodemodeJournalEntry(id: item.id, at: item.at, global: item.global))) }
            }, context: context)
            for issued in counts.values { durableIssued = max(durableIssued, issued) }
            for item in batch {
                journalLength += 1
                if await active() { try await run?.deliver(seq: journalLength, now: item.at, id: item.id, outcome: item.outcome) }
            }
            await launchCovered(); committing = false
            await pump()
        } catch { committing = false; await fail(error) }
    }
    func fail(_ error: any Error) async {
        guard failure == nil else { return }
        failure = error
        for waiter in modelWaiters { waiter.resume() }; modelWaiters = []
        await run?.abort(message: String(describing: error))
    }
    func diverge(_ message: String) async {
        guard ended == nil, failure == nil else { return }
        ended = failureResult("The script took a different path when resumed after a restart: \(message)")
        do { ended = try await decide(ended!) }
        catch { await fail(error) }
        await run?.abort(message: message)
    }
    func details() -> [CodemodeNestedCall] {
        rows.values.sorted { $0.id < $1.id }.map { row in
            var row = row; if row.status == .running { row.status = .cancelled }; return row
        }
    }
    func decide(_ result: ToolExecutionResult) async throws -> ToolExecutionResult {
        var result = result
        result.details = ["calls": try JSONValue(encoding: details())]
        let value = try codemodeEncodeToolResult(result)
        let decided = result
        return try await api.commit({ @Sendable tx in
            let doc = try await tx.doc(CodemodeRunDoc, taskId: self.api.taskId)
            if let recorded = try doc.get("result")?.objectValue { return try codemodeDecodeToolResult(recorded) }
            try doc.set("result", .object(value)); return decided
        }, context: context)
    }
    func complete(_ result: CodemodeResult) async throws -> ToolExecutionResult {
        let calls = details()
        let formatted = await codemodeFormatResult(result, generatedImages: generatedImages, wallMs: Double(try api.now()) - start.startedAt,
            maxOutputTokens: start.maxOutputTokens, calls: calls, limits: .init(maxBytes: 4 * 1024 * 1024, maxLines: 100_000, retain: .tail), write: { name, data in await self.writeOutput(name, data: data) })
        var detail: JSONObject = ["calls": try JSONValue(encoding: calls)]
        if let path = formatted.fullOutputPath { detail["fullOutputPath"] = .string(path) }
        let tool = ToolExecutionResult(output: formatted.content, isError: !result.ok, details: .object(detail))
        let encoded = try codemodeEncodeToolResult(tool)
        return try await api.commit({ @Sendable tx in
            let doc = try await tx.doc(CodemodeRunDoc, taskId: self.api.taskId)
            if let recorded = try doc.get("result")?.objectValue { return try codemodeDecodeToolResult(recorded) }
            try doc.set("result", .object(encoded))
            if result.ok, let writes = result.storeWrites, !writes.set.isEmpty || !writes.delete.isEmpty {
                let store = try await tx.doc(CodemodeStoreDoc, conversationId: self.api.conversationId)
                let values = try store.child("values")!
                for key in writes.delete { try values.remove(key) }
                for (key, value) in writes.set { try values.set(key, value) }
            }
            return tool
        }, context: context)
    }
    func writeOutput(_ name: String, data: Data) async -> CodemodeOutputFileResult {
        guard let env = api.env else { return .error("no execution environment") }
        do {
            let recorded = try await api.commit({ @Sendable tx in try await tx.doc(CodemodeRunDoc, taskId: self.api.taskId).get("outputDir")?.stringValue }, context: context)
            let directory: String
            if let recorded { directory = recorded }
            else {
                let created = await env.createTempDir(prefix: "pi-codemode-", context: context)
                switch created {
                case .failure(let error): return .error(error.message)
                case .success(let value):
                    directory = try await api.commit({ @Sendable tx in
                        let doc = try await tx.doc(CodemodeRunDoc, taskId: self.api.taskId)
                        if let found = try doc.get("outputDir")?.stringValue { return found }
                        try doc.set("outputDir", .string(value)); return value
                    }, context: context)
                }
            }
            let path = directory + "/" + name
            switch await env.writeFile(path, content: .bytes(Array(data)), context: context) {
            case .success: return .path(path)
            case .failure(let error): return .error(error.message)
            }
        } catch { return .error(String(describing: error)) }
    }
    func startedRow(_ call: CodemodeHostCall) {
        guard rows[call.id] == nil else { return }
        let name = codemodeHasPrefix(call.name, "pi.codemode.") ? String(call.name.dropFirst("pi.codemode.".count)) : call.name
        rows[call.id] = .init(id: call.id, name: name, args: cut((try? call.args?.jsonText()) ?? "", 200), status: .running)
    }
    func callTool(_ call: CodemodeHostCall) async throws -> CodemodeOutcome {
        guard gateOpen else { throw TaskDefinitionError("The sandbox fingerprint is not recorded") }
        let model = codemodeHasPrefix(call.name, "pi.codemode.")
        if model {
            if modelCalls >= 4 { await withCheckedContinuation { modelWaiters.append($0) } }
            else { modelCalls += 1 }
        }
        defer {
            if model {
                if !modelWaiters.isEmpty { modelWaiters.removeFirst().resume() }
                else { modelCalls -= 1 }
            }
        }
        guard await active() else { throw TaskDefinitionError("The script has ended") }
        guard let args = codemodeToolArguments(call).objectValue else {
            let message = "Arguments of tool \(call.name) must be an object"
            if var row = rows[call.id] { row.status = .error; row.error = message; rows[call.id] = row }
            return .failure(message: message, properties: [:])
        }
        let result = try await api.executeTool(call.name, arguments: args, context: context, options: .init(key: "c\(call.id)"))
        if call.name == "pi.codemode.models.generateImages" { generatedImages += result.structuredOutput?["output"]?.arrayValue?.filter { $0["type"] == "image" }.count ?? 0 }
        let structured = start.tools.first { harnessNamesEqual($0.name, call.name) }?.structured == true
        let value: JSONValue? = structured ? result.structuredOutput : .string(textOf(result.structuredOutput))
        let outcome: CodemodeOutcome
        let diagnostic = result.diagnostics.filter { $0.severity == .error }.map(\.message).joined(separator: "\n")
        if !result.isError || structured && value != nil { outcome = .success(value) }
        else {
            let message = structured ? "" : value?.stringValue ?? ""
            outcome = .failure(message: !message.isEmpty ? message : !diagnostic.isEmpty ? diagnostic : "Tool \(call.name) failed",
                properties: value.map { JSONObject([("structuredOutput", $0)]) } ?? [:])
        }
        if var row = rows[call.id] {
            row.status = result.isError ? .error : .ok; row.durationMs = result.durationMs
            let message: String
            if case .failure(let error, _) = outcome { message = error } else { message = diagnostic }
            if result.isError && !message.isEmpty { row.error = cut(message, 500) }; rows[call.id] = row
        }
        return outcome
    }
    func callGlobal(_ call: CodemodeHostCall) async throws -> CodemodeOutcome {
        do {
            let value: JSONValue?
            if discoveryNames.contains(call.name) { value = try discover(call) }
            else if catalogNames.contains(call.name) { value = try await codemodeCatalogCall(name: call.name, args: call.args, models: api.models, context: context) }
            else if let global = options.globals.first(where: { harnessNamesEqual($0.name, call.name) }) { value = try await global.execute(call.args, api, context) }
            else { return .failure(message: "Unknown global \(call.name)", properties: [:]) }
            return .success(value)
        } catch {
            if context.abortSignal?.aborted == true { throw error }
            return .failure(message: String(describing: error), properties: [:])
        }
    }
    func discover(_ call: CodemodeHostCall) throws -> JSONValue? {
        let args = call.args?.arrayValue ?? []
        let tools = start.tools.filter { $0.hidden != true }
        func argument(_ index: Int) -> JSONValue? { args.indices.contains(index) ? args[index] : nil }
        func matches(_ namespace: CodemodeStart.Namespace, _ name: String) -> Bool {
            harnessNamesEqual(namespace.name, name) || harnessNamesEqual(toCodemodeIdentifier(namespace.name), toCodemodeIdentifier(name))
        }
        if call.name == "describeTool" {
            guard let name = argument(0)?.stringValue else { throw TaskDefinitionError("describeTool() expects a tool name") }
            return tools.first { harnessNamesEqual($0.name, name) || harnessNamesEqual($0.jsName, name) }.map { .string($0.description) }
        }
        if call.name == "describeNamespace" {
            guard let name = argument(0)?.stringValue else { throw TaskDefinitionError("describeNamespace() expects a namespace name") }
            guard let own = start.namespaces.first(where: { matches($0, name) }) else { return nil }
            var value: JSONObject = ["name": .string(own.name), "tools": .array(own.tools.map { .string(toCodemodeIdentifier($0)) })]
            value["description"] = own.description.map(JSONValue.string); value["instructions"] = own.instructions.map(JSONValue.string)
            return .object(value)
        }
        guard let query = argument(0)?.stringValue else { throw TaskDefinitionError("searchTools() expects a query string") }
        let options = argument(1)?.objectValue
        let limitValue = options?["limit"] ?? 8
        guard let limit = limitValue.numberValue, limit > 0, limit.isFinite, limit.rounded(.towardZero) == limit else { throw TaskDefinitionError("searchTools() limit must be a positive integer") }
        let namespace = options?["namespace"]
        if let namespace, namespace != .null, namespace.stringValue == nil { throw TaskDefinitionError("searchTools() namespace must be a string") }
        let documents = tools.compactMap { tool -> SearchDocument? in
            let own = start.namespaces.first { $0.tools.contains { harnessNamesEqual($0, tool.name) } }
            if let name = namespace?.stringValue, own.map({ matches($0, name) }) != true { return nil }
            return .init(name: tool.name, text: [tool.name, tool.name.replacingOccurrences(of: "_", with: " "), tool.description, own?.name ?? "", own?.description ?? ""].joined(separator: " "))
        }
        return .array(rankDocuments(query, documents: documents, limit: Int(min(limit, Double(documents.count)))).compactMap { name in
            tools.first { harnessNamesEqual($0.name, name) }.map { ["name": .string($0.jsName), "description": .string($0.description)] }
        })
    }
}
private func codemodeToolArguments(_ call: CodemodeHostCall) -> JSONValue {
    // Upstream uses call.args ?? {}, so both undefined and JSON null use an empty object.
    guard let args = call.args, args != .null else { return [:] }
    return args
}
private func asToolCall(_ call: CodemodeHostCall) -> CodemodeHostCall {
    guard call.target == .global, modelNames.contains(call.name) else { return call }
    let args = call.args?.arrayValue ?? []
    return .init(id: call.id, target: .tool, name: "pi.codemode." + call.name,
        args: ["model": args.first ?? .null, "context": args.count > 1 ? args[1] : .null])
}
private func sameJSON(_ a: JSONValue?, _ b: JSONValue?) -> Bool {
    if let a, let b { return nestedJSONEqual(a, b) }; return a == nil && b == nil
}
private func describe(_ call: CodemodeHostCall) -> String { (call.target == .tool ? "tools." : "") + call.name + "(" + ((try? call.args?.jsonText()) ?? "") + ")" }
private func textOf(_ value: JSONValue?) -> String {
    if let value = value?.stringValue { return value }
    return value?.arrayValue?.compactMap { $0["type"] == "text" ? $0["text"]?.stringValue : nil }.joined(separator: "\n") ?? ""
}
internal func codemodeEncodeToolResult(_ result: ToolExecutionResult) throws -> JSONObject {
    let message = ToolResultMessage(toolCallId: "", toolName: "", content: result.output ?? [], isError: result.isError == true, timestamp: 0)
    let encoded = try EntryRecord.encodeMessages([.toolResult(message)])[0]
    var value: JSONObject = ["output": encoded["content"] ?? [], "isError": .bool(result.isError == true)]
    value["details"] = result.details
    return value
}
internal func codemodeDecodeToolResult(_ value: JSONObject) throws -> ToolExecutionResult {
    let message: JSONObject = ["role": "toolResult", "toolCallId": "", "toolName": "", "content": value["output"] ?? [], "isError": value["isError"] ?? false, "timestamp": 0]
    guard let foundation = try foundationJSON(from: .object(message)) as? [String: Any],
          case .toolResult(let result) = messageFromJSONObject(foundation) else { throw TaskDefinitionError("Invalid saved code mode result") }
    return .init(output: result.content, isError: result.isError, details: value["details"])
}
