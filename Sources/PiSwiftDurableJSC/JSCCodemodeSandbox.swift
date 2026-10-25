import Foundation
import PiSwiftChord
import PiSwiftCodemodeRuntime
import PiSwiftDurable

/// Runs durable JavaScript with the deterministic JavaScriptCore engine.
/// A watchdog can end a run before its JavaScript thread stops. This is the iOS path.
public actor JSCCodemodeSandbox: CodemodeSandbox {
    private let forceWatchdog: Bool
    private var closed = false
    private var runs: [UUID: JSCCodemodeRun] = [:]

    public init(forceWatchdog: Bool = false) {
        self.forceWatchdog = forceWatchdog
    }

    public func start(source: String, name: String, options: CodemodeRunOptions) async throws -> any CodemodeRun {
        guard !closed else { throw CodemodeError(kind: .sandbox, message: "Sandbox is closed") }
        try options.validate()
        guard !name.isEmpty else { throw CodemodeProtocolError.invalidSourceName }
        let timeout: Int?
        if let milliseconds = options.timeoutMs, milliseconds.isFinite {
            guard let value = Int(exactly: max(0, milliseconds).rounded(.up)) else {
                throw CodemodeProtocolError.invalidClock
            }
            timeout = value
        } else { timeout = nil }

        let id = UUID()
        let run = JSCCodemodeRun()
        // Reserve the run before start can suspend in a host callback.
        runs[id] = run
        var input = CodemodeRuntimeStartOptions(
            startedAt: options.startedAt, seed: options.seed,
            tools: options.tools.map { declaration in
                var tool = CodemodeRuntimeTool(name: declaration.name, description: declaration.description ?? "")
                tool.jsName = declaration.scriptName
                return tool
            },
            globals: options.globals.map { .init(name: $0.name, spread: $0.spread) },
            timeoutMs: timeout, forceWatchdog: forceWatchdog,
            onStarted: { fingerprint, runtime in
                await run.attach(runtime)
                await options.onStarted(fingerprint, run)
            },
            onCall: { call, _ in
                do {
                    let args = try call.argsJSON.map { try JSONValue(jsonText: $0) }
                    await run.record(call)
                    await options.onCall(.init(id: call.id, target: call.target == .tool ? .tool : .global,
                                              name: call.name, args: args), run)
                } catch {
                    await run.rejectBridge("Call arguments are not valid durable JSON: \(error)")
                }
            },
            onIdle: { seq, issued, _ in await options.onIdle(seq, issued, run) })
        // The prelude accepts a map from each exact key to its encoded JSON value.
        input.rawStoreJSON = JSONValue.object(JSONObject(options.store.map { ($0.key, .string($0.value.description)) })).description
        do {
            _ = try await JSCCodemodeEngine.start(code: source, name: name, options: input)
        } catch {
            runs.removeValue(forKey: id)
            throw mapProtocolError(error)
        }
        Task { [weak self] in
            _ = await run.result
            await self?.remove(id)
        }
        return run
    }

    /// Ends active runs and rejects later starts. This does not join watchdog threads.
    public func close() async {
        closed = true
        let active = Array(runs.values)
        runs.removeAll()
        for run in active { await run.abort(message: "Sandbox closed") }
    }

    private func remove(_ id: UUID) { runs.removeValue(forKey: id) }
}

// The wrapper is attached before the first host callback. No JSValue leaves the runtime.
internal actor JSCCodemodeRun: CodemodeRun {
    private var runtime: CodemodeRuntimeRun?
    private var pendingAbort: String?
    private struct Record: Sendable {
        var call: CodemodeCall
        var started: ContinuousClock.Instant
    }
    private var records: [Int: Record] = [:]
    private var terminal: CodemodeResult?
    private var deliveries = 0
    private var deliveryWaiters: [CheckedContinuation<Void, Never>] = []

    func attach(_ runtime: CodemodeRuntimeRun) async {
        self.runtime = runtime
        if let pendingAbort { await runtime.abort(message: pendingAbort) }
    }

    var finished: Bool {
        get async {
            if let runtime { return await runtime.finished }
            return pendingAbort != nil
        }
    }

    // Separate from finished: tests use this to check actual worker cleanup.
    var workerHasStopped: Bool { get async { await runtime?.workerHasStopped ?? true } }

    func record(_ call: CodemodeRuntimeCall) {
        guard terminal == nil else { return }
        if call.target == .tool {
            records[call.id] = Record(call: .init(name: call.name, status: .cancelled), started: .now)
        }
    }

    func rejectBridge(_ message: String) async {
        await runtime?.failBridge(message: message)
    }

    func deliver(seq: Int, now: Double, id: Int, outcome: CodemodeOutcome) async throws {
        guard let runtime else { throw CodemodeProtocolError.callNotWaiting(id) }
        if await runtime.finished { return }
        let reply: CodemodeRuntimeOutcome
        switch outcome {
        case .success(let value): reply = .success(json: value?.description)
        case .failure(let message, let properties):
            reply = .failure(message: message, propertiesJSON: JSONValue.object(properties).description)
        }
        deliveries += 1
        defer {
            deliveries -= 1
            if deliveries == 0 {
                let waiters = deliveryWaiters
                deliveryWaiters.removeAll()
                for waiter in waiters { waiter.resume() }
            }
        }
        do {
            if try await runtime.deliverIfWaiting(seq: seq, now: now, id: id, outcome: reply), var record = records[id] {
                // Upstream records completion when the host accepts a reply, including a buffered reply.
                if case .success = outcome { record.call.status = .ok } else { record.call.status = .error }
                record.call.durationMs = elapsed(record.started)
                records[id] = record
            }
        } catch { throw mapProtocolError(error) }
    }

    func abort(message: String) async {
        pendingAbort = message
        await runtime?.abort(message: message)
    }

    var result: CodemodeResult {
        get async {
            if let terminal { return terminal }
            guard let runtime else {
                return .init(error: .init(kind: .sandbox, message: "JavaScriptCore run is not attached"))
            }
            let result = await runtime.result
            // A result can arrive while accepted deliveries are returning to this actor.
            if deliveries > 0 { await withCheckedContinuation { deliveryWaiters.append($0) } }
            if let terminal { return terminal }
            let calls = records.sorted { $0.key < $1.key }.map { _, record in
                var call = record.call
                if call.status == .cancelled { call.durationMs = elapsed(record.started, to: result.endedAt ?? .now) }
                return call
            }
            let output: [PiSwiftDurable.CodemodeOutputItem] = result.execution.output.map {
                switch $0 {
                case .text(let text, let console): .text(text, console: console)
                case .image(let image): .image(data: image.data, mimeType: image.mimeType)
                }
            }
            let during = result.during.map { CodemodeDuring(seq: $0.seq, issued: $0.issued) }
            var mapped: CodemodeResult
            do {
                if let failure = result.execution.failure {
                    mapped = .init(error: .init(kind: CodemodeErrorKind(rawValue: failure.kind.rawValue)!,
                        name: failure.name, message: failure.message, stack: failure.stack), output: output, calls: calls, during: during)
                } else {
                    let value = try result.rawValueJSON.map { try JSONValue(jsonText: $0) }
                    let writes = try result.rawStoreWritesJSON.map { try JSONValue(jsonText: $0) }
                    var set = JSONObject()
                    var delete: [String] = []
                    for entry in writes?.arrayValue ?? [] {
                        guard let parts = entry.arrayValue, let key = parts.first?.stringValue else {
                            throw CodemodeProtocolError.invalidJSON
                        }
                        if parts.count == 1 { delete.append(key) }
                        else if parts.count == 2, let json = parts[1].stringValue {
                            set[key] = try JSONValue(jsonText: json)
                        } else { throw CodemodeProtocolError.invalidJSON }
                    }
                    mapped = .init(value: value, output: output, calls: calls,
                                   storeWrites: .init(set: set, delete: delete), during: during)
                }
            } catch {
                mapped = .init(error: .init(kind: .sandbox, message: "JavaScriptCore result is not valid durable JSON: \(error)"),
                               output: output, calls: calls, during: during)
            }
            terminal = mapped
            return mapped
        }
    }
}

private func elapsed(_ start: ContinuousClock.Instant, to end: ContinuousClock.Instant = .now) -> Double {
    let duration = start.duration(to: end).components
    return max(0, Double(duration.seconds) * 1000 + Double(duration.attoseconds) / 1e15)
}

private func mapProtocolError(_ error: any Error) -> any Error {
    guard let error = error as? CodemodeRuntimeProtocolError else { return error }
    switch error {
    case .invalidClock: return CodemodeProtocolError.invalidClock
    case .invalidJSON, .invalidProperties: return CodemodeProtocolError.invalidJSON
    case .invalidSequence(let seq): return CodemodeProtocolError.invalidSequence(seq)
    case .callNotWaiting(let id): return CodemodeProtocolError.callNotWaiting(id)
    case .invalidToolName(let name): return CodemodeProtocolError.invalidToolName(name)
    case .invalidGlobalName(let name): return CodemodeProtocolError.invalidGlobalName(name)
    case .invalidSourceName: return CodemodeProtocolError.invalidSourceName
    }
}
