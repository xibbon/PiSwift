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
    case output(ContentBlock)
    case call(id: Int, target: CodemodeRuntimeCall.Target, name: String, argsJSON: String?)
    case callResult(id: Int, CodemodeRuntimeReply)
    case done(ok: Bool, payload: String?, writes: String?)
    case crash(String)
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
        let input = RuntimeInput(code: code, toolsJSON: toolsJSON, globalsJSON: globalsJSON,
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
        var output: [ContentBlock] = []
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
                if ok {
                    let value = payload.flatMap(decodeAnyCodable)
                    let parsedWrites = writes.flatMap(parseWrites) ?? .init()
                    result = CodemodeRuntimeResult(execution: .init(output: output, returnedValue: value),
                                                   storeWrites: parsedWrites, usedWatchdog: watchdog)
                } else {
                    result = CodemodeRuntimeResult(execution: .init(output: output, failure: parseFailure(payload)),
                                                   usedWatchdog: watchdog)
                }
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

private func decodeAnyCodable(_ json: String) -> AnyCodable? {
    try? JSONDecoder().decode(AnyCodable.self, from: Data(json.utf8))
}

private func parseWrites(_ json: String) -> CodemodeStoreWrites? {
    guard let entries = try? JSONDecoder().decode([[String?]].self, from: Data(json.utf8)) else { return nil }
    var writes = CodemodeStoreWrites()
    for entry in entries {
        guard let key = entry.first ?? nil else { continue }
        if entry.count < 2 {
            writes.delete.append(key)
        } else if let value = entry[1], let decoded = decodeAnyCodable(value) {
            writes.set[key] = decoded
        }
    }
    return writes
}

private func parseFailure(_ json: String?) -> CodemodeFailure {
    guard let json, let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else {
        return .init(kind: .script, message: json ?? "Script failed")
    }
    return .init(kind: .script, message: object["message"] as? String ?? "Script failed",
                 name: object["name"] as? String, stack: object["stack"] as? String)
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

    let bridge: @convention(block) (String, String?, String?, String?) -> Void = { kind, a, b, c in
        switch kind {
        case "call", "global":
            guard let a, let id = Int(a), let name = b else { return }
            emit.yield(.call(id: id, target: kind == "call" ? .tool : .global, name: name, argsJSON: c))
        case "output":
            if a == "image", let data = b {
                emit.yield(.output(.image(ImageContent(data: data, mimeType: c ?? "application/octet-stream"))))
            } else if let text = b {
                emit.yield(.output(.text(TextContent(text: text))))
            }
        case "done":
            emit.yield(.done(ok: a == "true", payload: b, writes: c))
        default:
            break
        }
    }
    let preludeURL = URL(fileURLWithPath: "codemode-prelude.js")
    context.exception = nil
    guard let prelude = context.evaluateScript(codemodePreludeSource, withSourceURL: preludeURL),
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
