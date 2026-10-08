import Foundation
import JavaScriptCore
import PiSwiftAI
#if os(macOS)
import Darwin
#endif

public struct CodemodeRuntimeTool: Sendable, Codable {
    public var name: String
    public var description: String
    public var jsName: String

    public init(name: String, description: String = "") {
        self.name = name
        self.description = description
        self.jsName = toCodemodeIdentifier(name)
    }
}

public struct CodemodeRuntimeGlobal: Sendable, Codable {
    public var name: String
    public var spread: Bool

    public init(name: String, spread: Bool = false) {
        self.name = name
        self.spread = spread
    }
}

public struct CodemodeRuntimeCall: Sendable {
    public enum Target: String, Sendable { case tool, global }
    public var id: Int
    public var target: Target
    public var name: String
    public var argsJSON: String?
    public var signal: CancellationToken

    public init(id: Int, target: Target, name: String, argsJSON: String?, signal: CancellationToken) {
        self.id = id
        self.target = target
        self.name = name
        self.argsJSON = argsJSON
        self.signal = signal
    }
}

public struct CodemodeRuntimeReply: Sendable {
    public var ok: Bool
    /// JSON text on success, plain error text on failure. Nil means JavaScript undefined.
    public var payloadJSON: String?

    public init(ok: Bool, payloadJSON: String? = nil) {
        self.ok = ok
        self.payloadJSON = payloadJSON
    }
}

public struct CodemodeStoreWrites: Sendable {
    public var set: [String: AnyCodable]
    public var delete: [String]

    public init(set: [String: AnyCodable] = [:], delete: [String] = []) {
        self.set = set
        self.delete = delete
    }
}

public struct CodemodeRuntimeResult: Sendable {
    public var execution: CodemodeExecutionResult
    public var storeWrites: CodemodeStoreWrites
    /// True when a timeout cannot stop the JavaScriptCore thread and the host abandons it.
    public var usedWatchdog: Bool

    public init(execution: CodemodeExecutionResult, storeWrites: CodemodeStoreWrites = .init(), usedWatchdog: Bool) {
        self.execution = execution
        self.storeWrites = storeWrites
        self.usedWatchdog = usedWatchdog
    }
}

private enum RuntimeEvent: Sendable {
    case output(CodemodeOutputItem)
    case call(id: Int, target: CodemodeRuntimeCall.Target, name: String, argsJSON: String?)
    case callResult(id: Int, CodemodeRuntimeReply)
    case done(ok: Bool, payload: String?, writes: String?)
    case crash(String)
    case bridgeBroken(String)
    case timeout(Int)
    case aborted
    case stopped
    case stopGraceExpired
}

private enum RuntimeMessage: Sendable {
    case settle(Int, CodemodeRuntimeReply)
    case stop
}

private final class RuntimeMailbox: Sendable {
    private let queue = LockedState<[RuntimeMessage]>([])
    private let available = DispatchSemaphore(value: 0)

    func send(_ message: RuntimeMessage) {
        queue.withLock { $0.append(message) }
        available.signal()
    }

    func next() -> RuntimeMessage {
        available.wait()
        return queue.withLock { $0.removeFirst() }
    }
}

private final class RuntimeStopFlag: Sendable {
    private let state = LockedState(false)

    func cancel() { state.withLock { $0 = true } }
    var isCancelled: Bool { state.withLock { $0 } }
}

private struct RuntimeInput: Sendable {
    var code: String
    var preludeSource: String
    var toolsJSON: String
    var globalsJSON: String
    var storeJSON: String
    var useTimeLimit: Bool
}

public enum CodemodeSandbox {
    static func usesTimeLimit(forceWatchdog: Bool) -> Bool {
        #if os(macOS)
        return !forceWatchdog && runtimeSetExecutionTimeLimit != nil
        #else
        return false
        #endif
    }

    /// Run one script in a new JavaScriptCore VM on its own thread.
    public static func execute(
        code: String,
        tools: [CodemodeRuntimeTool],
        globals: [CodemodeRuntimeGlobal] = [],
        store: [String: AnyCodable] = [:],
        timeoutMs: Int? = nil,
        signal: CancellationToken? = nil,
        forceWatchdog: Bool = false,
        onCall: @escaping @Sendable (CodemodeRuntimeCall) async -> CodemodeRuntimeReply
    ) async -> CodemodeRuntimeResult {
        await execute(code: code, tools: tools, globals: globals, store: store, timeoutMs: timeoutMs,
                      signal: signal, forceWatchdog: forceWatchdog, preludeSource: codemodePreludeSource,
                      onCall: onCall)
    }

    // Upstream #10444: tests can supply the equivalent of the raw-worker fixture.
    static func execute(
        code: String,
        tools: [CodemodeRuntimeTool],
        globals: [CodemodeRuntimeGlobal] = [],
        store: [String: AnyCodable] = [:],
        timeoutMs: Int? = nil,
        signal: CancellationToken? = nil,
        forceWatchdog: Bool = false,
        preludeSource: String = codemodePreludeSource,
        onCall: @escaping @Sendable (CodemodeRuntimeCall) async -> CodemodeRuntimeReply
    ) async -> CodemodeRuntimeResult {
        if signal?.isCancelled == true {
            return CodemodeRuntimeResult(execution: .init(output: [],
                failure: .init(kind: .aborted, message: "Execution aborted")),
                usedWatchdog: !usesTimeLimit(forceWatchdog: forceWatchdog))
        }
        let validation = validateGlobals(globals)
        if let validation {
            return CodemodeRuntimeResult(execution: .init(output: [], failure: .init(kind: .sandbox, message: validation)), usedWatchdog: !usesTimeLimit(forceWatchdog: forceWatchdog))
        }
        let toolsJSON = (try? jsonString(tools)) ?? "[]"
        let globalsJSON = (try? jsonString(globals)) ?? "[]"
        var serializedStore: [String: String] = [:]
        for (key, value) in store {
            if let json = try? jsonString(value) { serializedStore[key] = json }
        }
        let storeJSON = (try? jsonString(serializedStore)) ?? "{}"
        let input = RuntimeInput(code: code, preludeSource: preludeSource, toolsJSON: toolsJSON, globalsJSON: globalsJSON,
                                 storeJSON: storeJSON, useTimeLimit: usesTimeLimit(forceWatchdog: forceWatchdog))
        let watchdog = !input.useTimeLimit
        let mailbox = RuntimeMailbox()
        let stopFlag = RuntimeStopFlag()
        let (events, emitter) = AsyncStream<RuntimeEvent>.makeStream()
        Thread.detachNewThread {
            defer { emitter.yield(.stopped) }
            runtimeWorker(input: input, mailbox: mailbox, stopFlag: stopFlag, emit: emitter)
        }

        let deadline = timeoutMs.map { duration in
            Task {
                try? await Task.sleep(for: .milliseconds(duration))
                if !Task.isCancelled {
                    stopFlag.cancel()
                    emitter.yield(.timeout(duration))
                }
            }
        }
        let removeAbort = signal?.onCancel {
            stopFlag.cancel()
            emitter.yield(.aborted)
        }
        var output: [CodemodeOutputItem] = []
        var pending: [Int: CancellationToken] = [:]
        var result: CodemodeRuntimeResult?
        var waitingForThread = false
        var graceTask: Task<Void, Never>?
        for await event in events {
            if waitingForThread {
                switch event {
                case .stopped:
                    break
                case .stopGraceExpired:
                    // A native call can still leave a JSC thread running despite the callback.
                    result?.usedWatchdog = true
                default:
                    continue
                }
                break
            }
            switch event {
            case .output(let block):
                output.append(block)
            case .call(let id, let target, let name, let argsJSON):
                guard pending[id] == nil else {
                    result = brokenBridgeResult("duplicate call id \(id)", output: output, watchdog: watchdog)
                    break
                }
                let callSignal = CancellationToken()
                pending[id] = callSignal
                let call = CodemodeRuntimeCall(id: id, target: target, name: name,
                                               argsJSON: argsJSON, signal: callSignal)
                Task {
                    let reply = await onCall(call)
                    emitter.yield(.callResult(id: id, reply))
                }
            case .callResult(let id, let reply):
                guard pending.removeValue(forKey: id) != nil else { continue }
                mailbox.send(.settle(id, reply))
            case .done(let ok, let payload, let writes):
                do {
                    // Decode all fields before the run has a result, as in upstream host.ts.
                    if ok {
                        let value = try payload.map { try decodeAnyCodable($0, what: "return value") }
                        let parsedWrites = try writes.map(parseWrites) ?? .init()
                        result = CodemodeRuntimeResult(execution: .init(output: output, returnedValue: value),
                                                       storeWrites: parsedWrites, usedWatchdog: watchdog)
                    } else {
                        let failure = try parseFailure(payload)
                        result = CodemodeRuntimeResult(execution: .init(output: output, failure: failure),
                                                       usedWatchdog: watchdog)
                    }
                } catch let error as RuntimeBridgeError {
                    result = brokenBridgeResult(error.reason, output: output, watchdog: watchdog)
                } catch {
                    result = CodemodeRuntimeResult(execution: .init(output: output,
                        failure: .init(kind: .sandbox, message: "Sandbox host failed: \(error)")),
                        usedWatchdog: watchdog)
                }
            case .bridgeBroken(let reason):
                result = brokenBridgeResult(reason, output: output, watchdog: watchdog)
            case .crash(let message):
                result = CodemodeRuntimeResult(execution: .init(output: output,
                    failure: .init(kind: .sandbox, message: message)), usedWatchdog: watchdog)
            case .timeout(let duration):
                result = CodemodeRuntimeResult(execution: .init(output: output,
                    failure: .init(kind: .timeout, message: "Execution timed out after \(duration) ms")),
                    usedWatchdog: watchdog)
            case .aborted:
                result = CodemodeRuntimeResult(execution: .init(output: output,
                    failure: .init(kind: .aborted, message: "Execution aborted")), usedWatchdog: watchdog)
            case .stopped:
                result = CodemodeRuntimeResult(execution: .init(output: output,
                    failure: .init(kind: .sandbox, message: "JavaScriptCore stopped before the script settled")),
                    usedWatchdog: watchdog)
            case .stopGraceExpired:
                continue
            }
            if result != nil {
                for token in pending.values { token.cancel() }
                stopFlag.cancel()
                mailbox.send(.stop)
                if watchdog { break }
                waitingForThread = true
                graceTask = Task {
                    try? await Task.sleep(for: .milliseconds(500))
                    if !Task.isCancelled { emitter.yield(.stopGraceExpired) }
                }
            }
        }
        deadline?.cancel()
        graceTask?.cancel()
        removeAbort?()
        if result == nil {
            for token in pending.values { token.cancel() }
            stopFlag.cancel()
            mailbox.send(.stop)
        }
        emitter.finish()
        return result ?? CodemodeRuntimeResult(execution: .init(output: output,
            failure: .init(kind: .sandbox, message: "JavaScriptCore stopped before the script settled")),
            usedWatchdog: watchdog)
    }
}

private func jsonString<T: Encodable>(_ value: T) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return String(decoding: try encoder.encode(value), as: UTF8.self)
}

// The prelude and script share built-ins. Do not trust the prelude's serialized fields.
private struct RuntimeBridgeError: Error {
    var reason: String
}

private func brokenBridgeResult(_ reason: String, output: [CodemodeOutputItem], watchdog: Bool) -> CodemodeRuntimeResult {
    .init(execution: .init(output: output, failure: .init(kind: .sandbox,
        message: "Sandbox bridge broken: \(reason). The script may have modified built-ins such as a prototype's toJSON.")),
        usedWatchdog: watchdog)
}

private func decodeAnyCodable(_ json: String, what: String) throws -> AnyCodable {
    do {
        return try JSONDecoder().decode(AnyCodable.self, from: Data(json.utf8))
    } catch {
        throw RuntimeBridgeError(reason: "\(what) is not valid JSON")
    }
}

private func parseBridgeJSON(_ json: String, what: String) throws -> Any {
    do {
        return try JSONSerialization.jsonObject(with: Data(json.utf8), options: [.fragmentsAllowed])
    } catch {
        throw RuntimeBridgeError(reason: "\(what) is not valid JSON")
    }
}

private func parseWrites(_ json: String) throws -> CodemodeStoreWrites {
    guard let entries = try parseBridgeJSON(json, what: "store writes") as? [Any] else {
        throw RuntimeBridgeError(reason: "store writes are not an array")
    }
    var writes = CodemodeStoreWrites()
    for value in entries {
        guard let entry = value as? [Any], let key = entry.first as? String,
              entry.count == 1 || (entry.count == 2 && entry[1] is String) else {
            throw RuntimeBridgeError(reason: "store writes contain a malformed entry")
        }
        if entry.count == 1 {
            writes.delete.append(key)
        } else if let value = entry[1] as? String {
            let encodedKey = try jsonString(key)
            writes.set[key] = try decodeAnyCodable(value, what: "store value for \(encodedKey)")
        }
    }
    return writes
}

private func parseFailure(_ json: String?) throws -> CodemodeFailure {
    let parsed = try parseBridgeJSON(json ?? "", what: "script error")
    guard parsed is [String: Any] || parsed is [Any] else {
        throw RuntimeBridgeError(reason: "script error is not an object")
    }
    guard let object = parsed as? [String: Any], let message = object["message"] as? String,
          object["name"] == nil || object["name"] is String,
          object["stack"] == nil || object["stack"] is String else {
        throw RuntimeBridgeError(reason: "script error is malformed")
    }
    return .init(kind: .script, message: message, name: object["name"] as? String, stack: object["stack"] as? String)
}

private func validateGlobals(_ globals: [CodemodeRuntimeGlobal]) -> String? {
    let reserved: Set<String> = ["tools", "ALL_TOOLS", "console", "text", "image", "exit", "globalThis", "store", "load"]
    let identifier = try! NSRegularExpression(pattern: "^[A-Za-z_$][A-Za-z0-9_$]*$")
    var seen: Set<String> = []
    var namespaces: Set<String> = []
    for global in globals {
        let parts = global.name.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        if parts.count > 2 || parts.contains(where: { identifier.firstMatch(in: $0, range: NSRange($0.startIndex..., in: $0)) == nil }) || reserved.contains(parts[0]) {
            return "Invalid global name \"\(global.name)\""
        }
        if !seen.insert(global.name).inserted { return "Global \"\(global.name)\" is already registered" }
        if parts.count == 2 { namespaces.insert(parts[0]) }
    }
    for namespace in namespaces where seen.contains(namespace) {
        return "Global \"\(namespace)\" conflicts with the namespace \"\(namespace)\""
    }
    return nil
}

/// This function runs only on the dedicated thread. The context and every JSValue stay here.
private func runtimeWorker(input: RuntimeInput, mailbox: RuntimeMailbox, stopFlag: RuntimeStopFlag,
                           emit: AsyncStream<RuntimeEvent>.Continuation) {
    let vm = JSVirtualMachine()
    guard let context = JSContext(virtualMachine: vm) else {
        emit.yield(.crash("Failed to create JavaScriptCore context"))
        return
    }
    context.isInspectable = false
    #if os(macOS)
    let interruptState = input.useTimeLimit ? RuntimeInterruptState(stopFlag: stopFlag) : nil
    if let interruptState, let setLimit = runtimeSetExecutionTimeLimit {
        let group = JSContextGetGroup(context.jsGlobalContextRef)
        setLimit(group, 0.1, runtimeLimitCallback, Unmanaged.passUnretained(interruptState).toOpaque())
    }
    // The C callback retains no Swift object. Keep its state alive until the VM leaves this scope.
    defer { withExtendedLifetime(interruptState) {} }
    #endif

    // String conversion would turn JavaScript undefined into the literal "undefined".
    // Read JSValue on this thread first; events still carry only Sendable string values.
    let bridge: @convention(block) (String, JSValue, JSValue, JSValue) -> Void = { kind, aValue, bValue, cValue in
        let a = aValue.isUndefined ? nil : aValue.toString()
        let b = bValue.isUndefined ? nil : bValue.toString()
        let c = cValue.isUndefined ? nil : cValue.toString()
        switch kind {
        case "call", "global":
            guard let a, let id = Int(a), bValue.isString, let name = b else {
                emit.yield(.bridgeBroken("unknown message from the worker"))
                return
            }
            emit.yield(.call(id: id, target: kind == "call" ? .tool : .global, name: name, argsJSON: c))
        case "output":
            if a == "image", bValue.isString, let data = b {
                emit.yield(.output(.image(ImageContent(data: data, mimeType: c ?? "application/octet-stream"))))
            } else if a == "text" || a == "console", bValue.isString, let text = b {
                emit.yield(.output(.text(text, console: a == "console")))
            } else {
                emit.yield(.bridgeBroken("unknown message from the worker"))
            }
        case "done":
            emit.yield(.done(ok: a == "true", payload: b, writes: c))
        default:
            emit.yield(.bridgeBroken("unknown message from the worker"))
        }
    }
    // JavaScriptCore supplies a configurable console; upstream QuickJS does not.
    // Remove it before lockdown so the prelude can define its own console afterwards.
    context.evaluateScript("delete globalThis.console")
    let preludeURL = URL(fileURLWithPath: "codemode-prelude.js")
    context.exception = nil
    guard let prelude = context.evaluateScript(input.preludeSource, withSourceURL: preludeURL),
          context.exception == nil,
          let api = prelude.call(withArguments: [bridge, input.toolsJSON, input.globalsJSON, input.storeJSON]),
          context.exception == nil else {
        emit.yield(.crash("Failed to initialize JavaScriptCore prelude: \(runtimeExceptionText(context))"))
        return
    }
    guard let run = api.forProperty("run"), let settle = api.forProperty("settle"),
          let stalled = api.forProperty("stalled") else {
        emit.yield(.crash("JavaScriptCore prelude did not provide run, settle, and stalled"))
        return
    }

    // The wrapper prefix is on the script's first line, as it is upstream.
    let wrapped = "(async (tools, console) => {\(input.code)\n})"
    context.exception = nil
    guard let script = context.evaluateScript(wrapped, withSourceURL: URL(fileURLWithPath: "codemode.js")),
          context.exception == nil else {
        emit.yield(.done(ok: false, payload: runtimeExceptionJSON(context), writes: nil))
        return
    }
    context.exception = nil
    _ = run.call(withArguments: [script])
    if runtimeCheckTermination(context: context, stopFlag: stopFlag, emit: emit) { return }
    _ = stalled.call(withArguments: [])
    if runtimeCheckTermination(context: context, stopFlag: stopFlag, emit: emit) { return }

    while true {
        switch mailbox.next() {
        case .stop:
            return
        case .settle(let id, let reply):
            if stopFlag.isCancelled { return }
            context.exception = nil
            let payload: Any = reply.payloadJSON ?? JSValue(undefinedIn: context)!
            let arguments: [Any] = [id, reply.ok, payload]
            _ = settle.call(withArguments: arguments)
            if runtimeCheckTermination(context: context, stopFlag: stopFlag, emit: emit) { return }
            _ = stalled.call(withArguments: [])
            if runtimeCheckTermination(context: context, stopFlag: stopFlag, emit: emit) { return }
        }
    }
}

private func runtimeCheckTermination(context: JSContext, stopFlag: RuntimeStopFlag,
                                     emit: AsyncStream<RuntimeEvent>.Continuation) -> Bool {
    if stopFlag.isCancelled { return true }
    if context.exception != nil {
        emit.yield(.done(ok: false, payload: runtimeExceptionJSON(context), writes: nil))
        return true
    }
    return false
}

private func runtimeExceptionText(_ context: JSContext) -> String {
    guard let exception = context.exception else { return "unknown JavaScriptCore error" }
    let name = exception.forProperty("name")?.toString() ?? "Error"
    let message = exception.forProperty("message")?.toString() ?? exception.toString() ?? "JavaScriptCore error"
    return "\(name): \(message)"
}

private func runtimeExceptionJSON(_ context: JSContext) -> String {
    guard let exception = context.exception else {
        return #"{"name":"Error","message":"JavaScriptCore error"}"#
    }
    let name = exception.forProperty("name")?.toString() ?? "Error"
    let message = exception.forProperty("message")?.toString() ?? exception.toString() ?? "JavaScriptCore error"
    let stack = exception.forProperty("stack")?.toString() ?? ""
    let filtered = stack.split(separator: "\n", omittingEmptySubsequences: true)
        .map(String.init).filter { !$0.contains("codemode-prelude.js") }.joined(separator: "\n")
    let data = try? JSONSerialization.data(withJSONObject: ["name": name, "message": message,
        "stack": "\(name): \(message)\n\(filtered)"], options: [.fragmentsAllowed])
    return data.flatMap { String(data: $0, encoding: .utf8) } ?? #"{"name":"Error","message":"JavaScriptCore error"}"#
}

#if os(macOS)
private typealias RuntimeLimitCallback = @convention(c) (JSContextRef?, UnsafeMutableRawPointer?) -> Bool
private typealias RuntimeSetExecutionTimeLimit = @convention(c)
    (JSContextGroupRef?, Double, RuntimeLimitCallback?, UnsafeMutableRawPointer?) -> Void

/// The private symbol is looked up at runtime and is never referenced in an iOS build.
private let runtimeSetExecutionTimeLimit: RuntimeSetExecutionTimeLimit? = {
    guard let handle = dlopen("/System/Library/Frameworks/JavaScriptCore.framework/JavaScriptCore", RTLD_LAZY),
          let symbol = dlsym(handle, "JSContextGroupSetExecutionTimeLimit") else { return nil }
    return unsafeBitCast(symbol, to: RuntimeSetExecutionTimeLimit.self)
}()

private final class RuntimeInterruptState {
    let stopFlag: RuntimeStopFlag

    init(stopFlag: RuntimeStopFlag) {
        self.stopFlag = stopFlag
    }
}

private let runtimeLimitCallback: RuntimeLimitCallback = { context, pointer in
    guard let pointer else { return false }
    let interruptState = Unmanaged<RuntimeInterruptState>.fromOpaque(pointer).takeUnretainedValue()
    if interruptState.stopFlag.isCancelled { return true }
    // Some shipped JSC versions do not schedule a second callback after `false`.
    // The private API permits setting the next slice from inside this callback.
    if let context, let setLimit = runtimeSetExecutionTimeLimit {
        setLimit(JSContextGetGroup(context), 0.1, runtimeLimitCallback, pointer)
    }
    return false
}
#endif
