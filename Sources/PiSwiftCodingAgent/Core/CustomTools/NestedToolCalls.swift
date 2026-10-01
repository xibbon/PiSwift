import Foundation
import PiSwiftAI
import PiSwiftAgent

public enum NestedCallLimits {
    public static let maxCalls = 256
    public static let maxArgumentBytesPerCall = 8 * 1024
    public static let maxArgumentBytesTotal = 32 * 1024
    public static let maxErrorChars = 500
}

public struct NestedCallSummary: Sendable {
    public var calls: NestedToolCalls?
    public var usage: Usage?

    public init(calls: NestedToolCalls?, usage: Usage?) {
        self.calls = calls
        self.usage = usage
    }
}

/// Bounded record of calls made below one model-issued tool call.
public struct NestedCallRecorder: Sendable {
    private var calls: [NestedToolCallRecord] = []
    private var startedAt: [String: Date] = [:]
    private var complete = true
    private var argumentBytes = 0
    private var usage: Usage?

    public init() {}

    /// Return the index of a recorded call, or nil when the count limit drops it.
    public mutating func start(_ toolCall: AgentToolCall) -> Int? {
        guard calls.count < NestedCallLimits.maxCalls else {
            complete = false
            return nil
        }
        var record = NestedToolCallRecord(id: toolCall.id, name: toolCall.name, status: .unfinished)
        let encoded = try? JSONEncoder().encode(toolCall.arguments)
        let bytes = encoded?.count ?? 0
        if encoded == nil || bytes > NestedCallLimits.maxArgumentBytesPerCall ||
            argumentBytes + bytes > NestedCallLimits.maxArgumentBytesTotal {
            record.argumentsBytes = bytes
            complete = false
        } else {
            record.arguments = toolCall.arguments
            record.argumentsJSON = toolCall.argumentsJSON.map {
                toolArgumentsToOrderedJSON(toolCall.arguments, argumentsJSON: $0)
            }
            argumentBytes += bytes
        }
        calls.append(record)
        startedAt[toolCall.id] = Date()
        return calls.count - 1
    }

    public mutating func finish(_ index: Int?, isError: Bool, errorText: String) {
        guard let index, calls.indices.contains(index) else { return }
        calls[index].status = isError ? .error : .ok
        let start = startedAt.removeValue(forKey: calls[index].id) ?? Date()
        calls[index].durationMs = max(0, (Date().timeIntervalSince(start) * 1000).rounded())
        if isError && !errorText.isEmpty {
            calls[index].error = String(errorText.prefix(NestedCallLimits.maxErrorChars))
        }
    }

    public mutating func addUsage(_ value: Usage) {
        usage = usage.map { combineUsage($0, value) } ?? value
    }

    public var totalUsage: Usage? { usage }

    public func snapshot() -> NestedToolCalls? {
        if calls.isEmpty && complete { return nil }
        return NestedToolCalls(calls: calls, complete: complete && !calls.contains { $0.status == .unfinished })
    }
}

public enum NestedToolExecutionEvent: Sendable {
    case start(toolCallId: String, toolName: String, args: [String: AnyCodable], parentToolCallId: String)
    case update(toolCallId: String, toolName: String, args: [String: AnyCodable],
                partialResult: AgentToolResult, parentToolCallId: String)
    case end(toolCallId: String, toolName: String, result: AgentToolResult,
             isError: Bool, parentToolCallId: String)
}

public struct NestedToolCallHost: Sendable {
    public var getTools: @Sendable () -> [AgentTool]
    public var isSequential: @Sendable () -> Bool
    public var runToolCall: @Sendable (
        _ toolCall: AgentToolCall, _ parentToolCallId: String, _ signal: CancellationToken?,
        _ onUpdate: @escaping ToolUpdateSink
    ) async -> AgentToolCallOutcome
    public var emit: @Sendable (NestedToolExecutionEvent) async -> Void

    public init(
        getTools: @escaping @Sendable () -> [AgentTool],
        isSequential: @escaping @Sendable () -> Bool,
        runToolCall: @escaping @Sendable (
            AgentToolCall, String, CancellationToken?, @escaping ToolUpdateSink
        ) async -> AgentToolCallOutcome,
        emit: @escaping @Sendable (NestedToolExecutionEvent) async -> Void
    ) {
        self.getTools = getTools
        self.isSequential = isSequential
        self.runToolCall = runToolCall
        self.emit = emit
    }
}

private actor NestedCallFIFO {
    private var held = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        if !held {
            held = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        if waiters.isEmpty {
            held = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}

/// Executes child calls through the session pipeline and records their bounded metadata.
public actor NestedToolCallRunner {
    private struct Scope: Sendable {
        var rootId: String
        var nextId: Int
        var holdsQueue: Bool
    }

    private let host: NestedToolCallHost
    private let queue = NestedCallFIFO()
    private var scopes: [String: Scope] = [:]
    private var recorders: [String: NestedCallRecorder] = [:]

    public init(host: NestedToolCallHost) {
        self.host = host
    }

    public func execute(
        callerId: String, name: String, args: [String: AnyCodable],
        options: ExecuteToolOptions = ExecuteToolOptions()
    ) async -> AgentToolCallOutcome {
        var scope = scopes[callerId] ?? Scope(rootId: callerId, nextId: 1, holdsQueue: false)
        let toolCall = AgentToolCall(id: "\(callerId)/\(scope.nextId)", name: name, arguments: args,
                                     argumentsJSON: options.argumentsJSON)
        scope.nextId += 1
        scopes[callerId] = scope

        var recorder = recorders[scope.rootId] ?? NestedCallRecorder()
        let recordIndex = recorder.start(toolCall)
        recorders[scope.rootId] = recorder

        await host.emit(.start(toolCallId: toolCall.id, toolName: name, args: toolCall.arguments, parentToolCallId: callerId))

        let exclusive = !scope.holdsQueue && (host.isSequential() ||
            host.getTools().first { $0.name == name }?.executionMode == .sequential)
        if exclusive { await queue.acquire() }
        scopes[toolCall.id] = Scope(rootId: scope.rootId, nextId: 1,
                                    holdsQueue: scope.holdsQueue || exclusive)

        let outcome = await host.runToolCall(toolCall, callerId, options.signal) { [host] partial in
            options.onUpdate?(partial)
            await host.emit(.update(toolCallId: toolCall.id, toolName: name, args: toolCall.arguments,
                                    partialResult: partial, parentToolCallId: callerId))
        }

        scopes.removeValue(forKey: toolCall.id)
        if exclusive { await queue.release() }

        var completed = recorders[scope.rootId] ?? NestedCallRecorder()
        let errorText = outcome.result.content.compactMap { block -> String? in
            if case .text(let text) = block { return text.text }
            return nil
        }.joined(separator: "\n")
        completed.finish(recordIndex, isError: outcome.isError, errorText: errorText)
        if let usage = outcome.result.usage { completed.addUsage(usage) }
        recorders[scope.rootId] = completed

        await host.emit(.end(toolCallId: toolCall.id, toolName: name, result: outcome.result,
                             isError: outcome.isError, parentToolCallId: callerId))
        return outcome
    }

    public func takeRecord(toolCallId: String) -> NestedCallSummary? {
        scopes.removeValue(forKey: toolCallId)
        guard let recorder = recorders.removeValue(forKey: toolCallId) else { return nil }
        return NestedCallSummary(calls: recorder.snapshot(), usage: recorder.totalUsage)
    }

    public func clear() {
        scopes.removeAll()
        recorders.removeAll()
    }
}
