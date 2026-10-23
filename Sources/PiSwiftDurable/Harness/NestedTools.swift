import Foundation
import PiSwiftAI
import PiSwiftChord
import Synchronization

/// The value returned to the calling tool. Model output and run control are not included.
public struct NestedToolExecutionResult: Sendable, Codable, Equatable {
    public var taskId: TaskID
    public var structuredOutput: JSONValue?
    public var isError: Bool
    public var details: JSONValue?
    public var diagnostics: [ToolDiagnostic]
    public var usage: Usage?
    public var durationMs: Int?
    public init(taskId: TaskID, structuredOutput: JSONValue? = nil, isError: Bool = false,
                details: JSONValue? = nil, diagnostics: [ToolDiagnostic] = [], usage: Usage? = nil, durationMs: Int? = nil) {
        self.taskId = taskId; self.structuredOutput = structuredOutput; self.isError = isError
        self.details = details; self.diagnostics = diagnostics; self.usage = usage; self.durationMs = durationMs
    }
    public init(from decoder: any Decoder) throws {
        let o = try recordObject(decoder)
        taskId = try recordRequired(o, "taskId"); structuredOutput = o["structuredOutput"]
        isError = try recordRequired(o, "isError"); details = o["details"]
        diagnostics = try recordRequired(o, "diagnostics"); durationMs = try recordOptional(o, "durationMs")
        usage = try o["usage"].map(durableUsage)
    }
    public func encode(to encoder: any Encoder) throws {
        var o: JSONObject = ["taskId": try JSONValue(encoding: taskId), "isError": .bool(isError),
                             "diagnostics": try JSONValue(encoding: diagnostics)]
        o["structuredOutput"] = structuredOutput; o["details"] = details; o["usage"] = usage.map(usageValue)
        try recordSetOptional(&o, "durationMs", durationMs)
        try o.encode(to: encoder)
    }
    public static func == (a: Self, b: Self) -> Bool {
        a.taskId == b.taskId && a.structuredOutput == b.structuredOutput && a.isError == b.isError &&
        a.details == b.details && a.diagnostics == b.diagnostics && a.usage.map(usageValue) == b.usage.map(usageValue) && a.durationMs == b.durationMs
    }
}

/// One call key, stored with the caller and retired when the caller settles.
public struct NestedCallState: Sendable, Codable, Equatable {
    public var taskId: TaskID?
    public var result: NestedToolExecutionResult?
    public init(taskId: TaskID? = nil, result: NestedToolExecutionResult? = nil) { self.taskId = taskId; self.result = result }
}
public let NestedCallDoc = try! TaskDocFamilyToken<NestedCallState, JSONValue?>(
    kind: "pi.tool.nested-call", version: 1, initial: { _ in NestedCallState() })

/// Options for a nested call. A key identifies the same call on a safe replay.
public struct NestedToolOptions: Sendable {
    public var key: String?
    public var progress: Bool?
    public init(key: String? = nil, progress: Bool? = nil) { self.key = key; self.progress = progress }
}

/// The parent identity supplied to tool hooks.
public struct ToolHookParent: Sendable, Equatable {
    public var taskId: TaskID
    public var callId: String
    public init(taskId: TaskID, callId: String) { self.taskId = taskId; self.callId = callId }
}
/// A tool call with its parent when another tool made the call.
public struct ToolHookCall: Sendable {
    public var call: ToolCall
    public var parent: ToolHookParent?
    public var type: String { call.type }
    public var id: String { get { call.id } set { call.id = newValue } }
    public var name: String { get { call.name } set { call.name = newValue } }
    public var thoughtSignature: String? { get { call.thoughtSignature } set { call.thoughtSignature = newValue } }
    public var namespace: String? { get { call.namespace } set { call.namespace = newValue } }
    public var argumentsError: String? { get { call.argumentsError } set { call.argumentsError = newValue } }
    public var arguments: [String: AnyCodable] { get { call.arguments } set { call.arguments = newValue } }
    public var argumentsJSON: OrderedJSON? { get { call.argumentsJSON } set { call.argumentsJSON = newValue } }
    public init(_ call: ToolCall, parent: ToolHookParent? = nil) { self.call = call; self.parent = parent }
}

internal func nestedCallValue(_ call: ToolCall) throws -> JSONValue {
    var o: JSONObject = ["type": "toolCall", "id": .string(call.id), "name": .string(call.name),
                         "arguments": try durableJSON(fromFoundation: call.arguments.mapValues(\.value))]
    try recordSetOptional(&o, "thoughtSignature", call.thoughtSignature)
    try recordSetOptional(&o, "namespace", call.namespace)
    try recordSetOptional(&o, "argumentsError", call.argumentsError)
    return .object(o)
}
internal func nestedCallFromValue(_ value: JSONValue) throws -> ToolCall {
    guard let o = value.objectValue else { throw TaskDefinitionError("Nested tool call must be an object") }
    let args: JSONObject = try recordRequired(o, "arguments")
    guard let dictionary = try foundationJSON(from: .object(args)) as? [String: Any] else {
        throw TaskDefinitionError("Nested tool arguments must be an object")
    }
    return ToolCall(id: try recordRequired(o, "id"), name: try recordRequired(o, "name"),
        arguments: dictionary.mapValues(AnyCodable.init), thoughtSignature: try recordOptional(o, "thoughtSignature"),
        namespace: try recordOptional(o, "namespace"), argumentsJSON: try orderedJSON(from: .object(args)),
        argumentsError: try recordOptional(o, "argumentsError"))
}

/// Orders admission registration and the end barrier across concurrent callers.
internal final class NestedToolCalls: Sendable {
    private struct State: Sendable {
        var ended = false
        var sequence = 0
        var memo: Task<JSONValue?, any Error>?
        var memoSequence = 0
        var admissions: [Task<TaskID, any Error>] = []
    }
    private let state = Mutex(State())
    let runtime: TaskRuntime
    let callId: String
    let resumes: Bool
    init(runtime: TaskRuntime, callId: String, resumes: Bool) { self.runtime = runtime; self.callId = callId; self.resumes = resumes }
    func execute(_ name: String, arguments: JSONObject, context: ChordContext, options: NestedToolOptions) async throws -> NestedToolExecutionResult {
        let (key, admission) = try state.withLock { state -> (String, Task<TaskID, any Error>) in
            guard !state.ended else { throw TaskDefinitionError("Tool call \(callId) has settled") }
            let key: String
            if let explicit = options.key { try checkNestedKey(explicit); key = explicit }
            else { state.sequence += 1; key = String(state.sequence) }
            if state.memo == nil {
                state.memoSequence += 1
                state.memo = Task { try await runtime.memo("pi.tool.madeNestedCalls", value: true, context: context) }
            }
            let memo = state.memo!, ticket = state.memoSequence
            let admission = Task {
                do { _ = try await memo.value }
                catch {
                    self.state.withLock { if $0.memoSequence == ticket { $0.memo = nil } }
                    throw error
                }
                return try await startNestedCall(runtime, parentCallId: callId, name: name, args: arguments,
                    key: key, progress: options.progress, abandonOnRestart: !resumes, context: context)
            }
            state.admissions.append(admission)
            return (key, admission)
        }
        let id = try await admission.value
        let settled = try await runtime.waitForTask(id, context: context)
        if let stored = try await runtime.snapshot(NestedCallDoc, taskId: runtime.taskId, key: key, context: context)?.result { return stored }
        let message: String
        switch settled.outcome {
        case .faulted(let error, _): message = "Tool \(name) failed: \(error.message)"
        case .orphaned(let reason, _): message = "Tool \(name) could not resume: \(reason)"
        default: message = "Tool \(name) ended without a result"
        }
        return NestedToolExecutionResult(taskId: id, isError: true,
            diagnostics: [.init(severity: .error, message: message, code: settled.outcome.status)])
    }
    func close() { state.withLock { $0.ended = true } }
    func end() async {
        let admissions = state.withLock { state in state.ended = true; return state.admissions }
        for admission in admissions { _ = await admission.result }
    }
}

private func checkNestedKey(_ key: String) throws {
    let bytes = Array(key.utf8)
    let positive = bytes.first.map { (49...57).contains($0) } == true && bytes.allSatisfy { (48...57).contains($0) }
    if key.isEmpty || key.contains("/") || key == "__proto__" || positive {
        throw TaskDefinitionError("Nested call key \(try JSONValue.string(key).jsonText()) must be non-empty, without \"/\", not \"__proto__\", and not a positive integer")
    }
}
private func startNestedCall(_ runtime: TaskRuntime, parentCallId: String, name: String, args: JSONObject,
                             key: String, progress: Bool?, abandonOnRestart: Bool, context: ChordContext) async throws -> TaskID {
    let call = try nestedCallFromValue(["id": .string(parentCallId + "/" + key), "name": .string(name), "arguments": .object(args)])
    let chosen = Mutex<TaskID?>(nil)
    try await runtime.commit({ tx, _ in
        let member = try await tx.doc(NestedCallDoc, taskId: runtime.taskId, key: key, seed: nil)
        if let existing = try member.get("taskId")?.decode(TaskID.self) {
            guard let record = try await tx.task(existing),
                  case .nested(_, _, _, let old, _) = try record.input.decode(ToolTaskInput.self),
                  harnessNamesEqual(old.name, name),
                  try nestedJSONEqual(durableJSON(fromFoundation: old.arguments.mapValues(\.value)), .object(args)) else {
                throw TaskDefinitionError("Nested call \(call.id) was already made with another tool or other arguments")
            }
            chosen.withLock { $0 = existing }; return nil
        }
        let id = try await tx.createTask(toolTask, input: .nested(parent: runtime.taskId, parentCallId: parentCallId,
            key: key, call: call, progress: progress == false ? false : nil),
            options: .init(ownership: .task(taskId: runtime.taskId), abandonOnRestart: abandonOnRestart))
        try member.set("taskId", JSONValue(encoding: id))
        let live = try await tx.doc(LiveDoc, conversationId: runtime.conversationId)
        if try live.child("nestedTools") == nil { try live.set("nestedTools", []) }
        try live.child("nestedTools")!.append(JSONValue(encoding: NestedToolSlot(callId: call.id, name: name,
            parentCallId: parentCallId, parentTaskId: runtime.taskId, taskId: id, arguments: args)))
        chosen.withLock { $0 = id }; return nil
    }, context: context)
    guard let id = chosen.withLock({ $0 }) else { throw TaskDefinitionError("Nested call admission has no task") }
    return id
}

/// Compares JSON values without using object member order. Key spelling stays exact.
internal func nestedJSONEqual(_ a: JSONValue, _ b: JSONValue) -> Bool {
    var pending: [(JSONValue, JSONValue)] = [(a, b)]
    while let (left, right) = pending.popLast() {
        switch (left, right) {
        case (.object(let x), .object(let y)):
            guard x.count == y.count else { return false }
            for (key, value) in x {
                guard let other = y[key] else { return false }
                pending.append((value, other))
            }
        case (.array(let x), .array(let y)):
            guard x.count == y.count else { return false }
            pending.append(contentsOf: zip(x, y))
        default: if left != right { return false }
        }
    }
    return true
}
