import Foundation
import PiSwiftAI

/// The reply being processed and the number of calls issued when a script ended.
public struct CodemodeRuntimeDuring: Sendable, Equatable {
    public var seq: Int
    public var issued: Int

    public init(seq: Int, issued: Int) {
        self.seq = seq
        self.issued = issued
    }
}

/// JSON text preserves JavaScript undefined (nil) separately from JSON null ("null").
public enum CodemodeRuntimeOutcome: Sendable {
    case success(json: String?)
    case failure(message: String, propertiesJSON: String? = nil)
}

public enum CodemodeRuntimeProtocolError: Error, Sendable, Equatable {
    case invalidClock
    case invalidJSON
    case invalidProperties
    case invalidSequence(Int)
    case callNotWaiting(Int)
    case invalidToolName(String)
    case invalidGlobalName(String)
    case invalidSourceName
}

public struct CodemodeRuntimeStartOptions: Sendable {
    public var startedAt: Double
    public var seed: UInt32
    public var tools: [CodemodeRuntimeTool]
    public var globals: [CodemodeRuntimeGlobal]
    public var store: [String: AnyCodable]
    public var timeoutMs: Int?
    public var signal: CancellationToken?
    public var forceWatchdog: Bool
    /// Awaited before the worker starts. The handle permits abort during this callback.
    public var onStarted: @Sendable (String, CodemodeRuntimeRun) async -> Void
    /// Calls and idle callbacks are awaited in worker event order. Callbacks can deliver replies.
    /// Do not wait for the run's result in a callback: it would block later worker events.
    public var onCall: @Sendable (CodemodeRuntimeCall, CodemodeRuntimeRun) async -> Void
    public var onIdle: @Sendable (Int, Int, CodemodeRuntimeRun) async -> Void

    public init(startedAt: Double, seed: UInt32, tools: [CodemodeRuntimeTool] = [],
                globals: [CodemodeRuntimeGlobal] = [], store: [String: AnyCodable] = [:],
                timeoutMs: Int? = nil, signal: CancellationToken? = nil, forceWatchdog: Bool = false,
                onStarted: @escaping @Sendable (String, CodemodeRuntimeRun) async -> Void = { _, _ in },
                onCall: @escaping @Sendable (CodemodeRuntimeCall, CodemodeRuntimeRun) async -> Void,
                onIdle: @escaping @Sendable (Int, Int, CodemodeRuntimeRun) async -> Void = { _, _, _ in }) {
        self.startedAt = startedAt
        self.seed = seed
        self.tools = tools
        self.globals = globals
        self.store = store
        self.timeoutMs = timeoutMs
        self.signal = signal
        self.forceWatchdog = forceWatchdog
        self.onStarted = onStarted
        self.onCall = onCall
        self.onIdle = onIdle
    }
}

struct RuntimeDeterministicInput: Sendable {
    var startedAt: Double
    var seed: UInt32
    var name: String
}

extension JSCCodemodeEngine {
    /// Start a host-controlled run. Use the same name, declarations, seed, and replies for replay.
    /// The real deadline remains active while the virtual clock is stopped.
    public static func start(code: String, name: String = "codemode.js",
                             options: CodemodeRuntimeStartOptions) async throws -> CodemodeRuntimeRun {
        guard !name.isEmpty else { throw CodemodeRuntimeProtocolError.invalidSourceName }
        guard options.startedAt.isFinite, options.startedAt >= 0 else {
            throw CodemodeRuntimeProtocolError.invalidClock
        }
        var names: Set<[UInt16]> = []
        var scriptNames: Set<[UInt16]> = []
        for tool in options.tools {
            guard names.insert(Array(tool.name.utf16)).inserted,
                  scriptNames.insert(Array(tool.jsName.utf16)).inserted else {
                throw CodemodeRuntimeProtocolError.invalidToolName(tool.name)
            }
        }
        if let reason = validateGlobals(options.globals) {
            throw CodemodeRuntimeProtocolError.invalidGlobalName(reason)
        }
        let storeJSON: String
        do {
            var store: [String: String] = [:]
            for (key, value) in options.store { store[key] = try jsonString(value) }
            storeJSON = try jsonString(store)
        } catch {
            throw CodemodeRuntimeProtocolError.invalidJSON
        }
        let input = RuntimeInput(code: code, preludeSource: codemodePreludeSource,
                                 toolsJSON: try jsonString(options.tools),
                                 globalsJSON: try jsonString(options.globals), storeJSON: storeJSON,
                                 useTimeLimit: usesTimeLimit(forceWatchdog: options.forceWatchdog),
                                 deterministic: .init(startedAt: options.startedAt, seed: options.seed, name: name))
        let run = CodemodeRuntimeRun(useTimeLimit: input.useTimeLimit)
        await run.start(input: input, options: options)
        return run
    }
}

/// A deterministic run. The first terminal outcome wins. Result readiness does not prove VM exit.
public actor CodemodeRuntimeRun {
    /// Signal cancellation is visible before the actor handles its abort task.
    public var finished: Bool { selected != nil || cancellation.isCancelled }
    private let cancellation = CancellationToken()
    private let mailbox = RuntimeMailbox()
    private let stopFlag = RuntimeStopFlag()
    private let watchdog: Bool
    private var workerStarted = false
    private var output: [CodemodeOutputItem] = []
    private var pending: [Int: CodemodeRuntimeCall] = [:]
    private var issued = 0
    private var delivered: Set<Int> = []
    private var early: [Int: RuntimeMessage] = [:]
    private var nextSeq = 1
    private var selected: CodemodeRuntimeResult?
    private var completed: CodemodeRuntimeResult?
    private var waiters: [CheckedContinuation<CodemodeRuntimeResult, Never>] = []
    private var deadline: Task<Void, Never>?
    private var grace: Task<Void, Never>?
    private var removeAbort: (@Sendable () -> Void)?
    private var emitter: AsyncStream<RuntimeEvent>.Continuation?
    private var onCall: (@Sendable (CodemodeRuntimeCall, CodemodeRuntimeRun) async -> Void)?
    private var onIdle: (@Sendable (Int, Int, CodemodeRuntimeRun) async -> Void)?

    init(useTimeLimit: Bool) {
        self.watchdog = !useTimeLimit
    }

    public var result: CodemodeRuntimeResult {
        get async {
            if let completed { return completed }
            return await withCheckedContinuation { waiters.append($0) }
        }
    }

    /// Accept a reply once. A valid reply consumes its call even if an earlier sequence is absent.
    /// Invalid input changes neither the waiting calls nor the accepted sequence numbers.
    /// Delivery after the terminal outcome has no effect, including invalid delivery.
    public func deliver(seq: Int, now: Double, id: Int, outcome: CodemodeRuntimeOutcome) throws {
        guard !finished else { return }
        guard now.isFinite else { throw CodemodeRuntimeProtocolError.invalidClock }
        guard seq > 0, !delivered.contains(seq) else {
            throw CodemodeRuntimeProtocolError.invalidSequence(seq)
        }
        guard pending[id] != nil else { throw CodemodeRuntimeProtocolError.callNotWaiting(id) }
        let reply: CodemodeRuntimeReply
        let propertiesJSON: String?
        switch outcome {
        case .success(let json):
            if let json { try validateReplyJSON(json) }
            reply = .init(ok: true, payloadJSON: json)
            propertiesJSON = nil
        case .failure(let message, let properties):
            if let properties {
                guard try validateReplyJSON(properties) else { throw CodemodeRuntimeProtocolError.invalidProperties }
            }
            reply = .init(ok: false, payloadJSON: message)
            propertiesJSON = properties
        }
        delivered.insert(seq)
        pending.removeValue(forKey: id)
        early[seq] = .deterministicSettle(seq: seq, now: now, id: id, reply: reply, propertiesJSON: propertiesJSON)
        while let message = early.removeValue(forKey: nextSeq) {
            mailbox.send(message)
            // A sequence at Int.max cannot have a later representable sequence.
            if nextSeq == Int.max { break }
            nextSeq += 1
        }
    }

    /// End the run outside JavaScript. This does not reject a promise the script can catch.
    public func abort(message: String = "Execution aborted") {
        select(failure(.aborted, message: message))
    }

    func start(input: RuntimeInput, options: CodemodeRuntimeStartOptions) async {
        onCall = options.onCall
        onIdle = options.onIdle
        if let duration = options.timeoutMs {
            deadline = Task { [weak self] in
                do { try await Task.sleep(for: .milliseconds(duration)) } catch { return }
                await self?.timeout(duration)
            }
        }
        if let signal = options.signal {
            if signal.isCancelled {
                abort()
                return
            }
            removeAbort = signal.onCancel { [weak self, cancellation] in
                cancellation.cancel()
                Task { await self?.abort() }
            }
        }
        await options.onStarted(deterministicFingerprint(useTimeLimit: input.useTimeLimit), self)
        guard !finished else { return }
        let (events, emitter) = AsyncStream<RuntimeEvent>.makeStream()
        self.emitter = emitter
        let mailbox = self.mailbox
        let stopFlag = self.stopFlag
        workerStarted = true
        Thread.detachNewThread {
            defer { emitter.yield(.stopped) }
            runtimeWorker(input: input, mailbox: mailbox, stopFlag: stopFlag, emit: emitter)
        }
        Task {
            for await event in events { await receive(event) }
        }
    }

    private func timeout(_ duration: Int) {
        select(failure(.timeout, message: "Execution timed out after \(duration) ms"))
    }

    private func receive(_ event: RuntimeEvent) async {
        if cancellation.isCancelled, selected == nil { abort() }
        if finished {
            switch event {
            case .stopped:
                complete()
            case .stopGraceExpired:
                selected?.usedWatchdog = true
                complete()
            case .call(let id, let target, let name, let argsJSON):
                stopFlag.reject(.init(id: id, target: target, name: name, argsJSON: argsJSON, signal: CancellationToken()))
            default:
                break
            }
            return
        }
        switch event {
        case .output(let item):
            output.append(item)
        case .call(let id, let target, let name, let argsJSON):
            guard id == issued + 1, pending[id] == nil else {
                select(brokenBridgeResult("invalid call id \(id)", output: output, watchdog: watchdog))
                return
            }
            if let argsJSON {
                do { try validateRuntimeJSONSyntax(argsJSON) }
                catch { select(brokenBridgeResult("call arguments are not valid JSON", output: output, watchdog: watchdog)); return }
            }
            let call = CodemodeRuntimeCall(id: id, target: target, name: name,
                                           argsJSON: argsJSON, signal: CancellationToken())
            issued = id
            pending[id] = call
            await onCall?(call, self)
        case .idle(let seq, let count):
            await onIdle?(seq, count, self)
        case .deterministicDone(let ok, let payload, let writes, let during):
            do {
                var result: CodemodeRuntimeResult
                if ok {
                    let value = try payload.map { try decodeAnyCodable($0, what: "return value") }
                    let storeWrites = try writes.map(parseWrites) ?? .init()
                    result = .init(execution: .init(output: output, returnedValue: value),
                                   storeWrites: storeWrites, usedWatchdog: watchdog)
                } else {
                    result = .init(execution: .init(output: output, failure: try parseFailure(payload)), usedWatchdog: watchdog)
                }
                result.during = during
                select(result)
            } catch let error as RuntimeBridgeError {
                select(brokenBridgeResult(error.reason, output: output, watchdog: watchdog))
            } catch {
                select(failure(.sandbox, message: "Sandbox host failed: \(error)"))
            }
        case .bridgeBroken(let reason):
            select(brokenBridgeResult(reason, output: output, watchdog: watchdog))
        case .crash(let message):
            select(failure(.sandbox, message: message))
        case .timeout(let duration):
            timeout(duration)
        case .aborted:
            abort()
        case .stopped:
            workerStarted = false
            select(failure(.sandbox, message: "JavaScriptCore stopped before the script settled"))
        case .done, .callResult, .stopGraceExpired:
            select(brokenBridgeResult("unexpected deterministic worker event", output: output, watchdog: watchdog))
        }
    }

    private func failure(_ kind: CodemodeFailureKind, message: String) -> CodemodeRuntimeResult {
        .init(execution: .init(output: output, failure: .init(kind: kind, message: message)), usedWatchdog: watchdog)
    }

    private func select(_ result: CodemodeRuntimeResult) {
        guard selected == nil else { return }
        var result = cancellation.isCancelled ? failure(.aborted, message: "Execution aborted") : result
        result.unfinishedCalls = pending.values.sorted { $0.id < $1.id }
        result.readRejectedCalls { [stopFlag] in stopFlag.rejectedCalls }
        selected = result
        for call in result.unfinishedCalls { call.signal.cancel() }
        pending.removeAll()
        early.removeAll()
        delivered.removeAll()
        stopFlag.cancel()
        mailbox.send(.stop)
        deadline?.cancel()
        deadline = nil
        removeAbort?()
        removeAbort = nil
        onCall = nil
        onIdle = nil
        if watchdog || !workerStarted {
            complete()
        } else {
            grace = Task { [weak self] in
                do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
                await self?.receive(.stopGraceExpired)
            }
        }
    }

    private func complete() {
        guard completed == nil, let selected else { return }
        completed = selected
        grace?.cancel()
        grace = nil
        emitter?.finish()
        emitter = nil
        let waiters = self.waiters
        self.waiters.removeAll()
        for waiter in waiters { waiter.resume(returning: selected) }
    }
}

@discardableResult
private func validateReplyJSON(_ json: String) throws -> Bool {
    try validateRuntimeJSONSyntax(json)
    return json.utf8.first { ![9, 10, 13, 32].contains($0) } == 123
}

/// FNV-1a over UTF-16 units, as in upstream. This hash identifies source; it is not a security hash.
private func deterministicSourceHash(_ source: String) -> String {
    var hash: UInt32 = 0x811c9dc5
    for unit in source.utf16 { hash = (hash ^ UInt32(unit)) &* 0x01000193 }
    return String(format: "%08x", hash)
}

private func deterministicFingerprint(useTimeLimit: Bool) -> String {
    let os = ProcessInfo.processInfo.operatingSystemVersion
    #if arch(arm64)
    let architecture = "arm64"
    #elseif arch(x86_64)
    let architecture = "x86_64"
    #else
    let architecture = "other"
    #endif
    #if os(macOS)
    let platform = "macOS"
    #elseif os(iOS)
    let platform = "iOS"
    #else
    let platform = "Apple"
    #endif
    return "JavaScriptCore \(platform) \(os.majorVersion).\(os.minorVersion).\(os.patchVersion) \(architecture), " +
        "prelude \(deterministicSourceHash(codemodePreludeSource)), " +
        "bindings \(deterministicSourceHash(codemodeDeterministicPreludeSource)), scheduler 1, seed mulberry32-v1, " +
        "interrupt \(useTimeLimit ? "time-limit" : "watchdog")"
}
