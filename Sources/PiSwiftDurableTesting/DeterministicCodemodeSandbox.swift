import PiSwiftChord
import PiSwiftDurable

/// A call in a fake script plan. The run assigns its numeric ID.
public struct DeterministicCodemodeCall: Sendable, Equatable {
    public var target: CodemodeCallTarget
    public var name: String
    public var args: JSONValue?
    public init(target: CodemodeCallTarget = .tool, name: String, args: JSONValue? = nil) {
        self.target = target; self.name = name; self.args = args
    }
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.target == rhs.target && lhs.name.utf16.elementsEqual(rhs.name.utf16) && lhs.args == rhs.args
    }
}

/// One result applied by the fake run, in sequence order.
public struct DeterministicCodemodeDelivery: Sendable, Equatable {
    public var seq: Int
    public var now: Double
    public var id: Int
    public var outcome: CodemodeOutcome
    public init(seq: Int, now: Double, id: Int, outcome: CodemodeOutcome) {
        self.seq = seq; self.now = now; self.id = id; self.outcome = outcome
    }
}

/// The state passed to a fake plan at start and after each applied delivery.
public struct DeterministicCodemodeState: Sendable {
    public let source: String
    public let name: String
    public let options: CodemodeRunOptions
    public let now: Double
    public let calls: [CodemodeHostCall]
    public let deliveries: [DeterministicCodemodeDelivery]
    public var seq: Int { deliveries.last?.seq ?? 0 }
}

/// A plan step can issue calls, add output, or finish. Nil result means wait.
public struct DeterministicCodemodeStep: Sendable {
    public var calls: [DeterministicCodemodeCall]
    public var output: [CodemodeOutputItem]
    public var result: CodemodeResult?
    public init(calls: [DeterministicCodemodeCall] = [], output: [CodemodeOutputItem] = [], result: CodemodeResult? = nil) {
        self.calls = calls; self.output = output; self.result = result
    }
}

/// A small scripted fake. It does not parse or execute JavaScript.
/// Each plan is called once at start and once for each applied result.
public actor DeterministicCodemodeSandbox: CodemodeSandbox {
    public typealias Plan = @Sendable (DeterministicCodemodeState) -> DeterministicCodemodeStep
    public struct Start: Sendable {
        public let source: String
        public let name: String
        public let options: CodemodeRunOptions
    }
    public private(set) var starts: [Start] = []
    public let fingerprint: String
    private let plan: Plan
    private var closed = false
    private var nextRunID = 0
    private var activeRuns: [Int: DeterministicCodemodeRun] = [:]
    public init(fingerprint: String = "piswift-scripted-sandbox-v1", plan: @escaping Plan = { _ in
        .init(result: .init())
    }) {
        self.fingerprint = fingerprint; self.plan = plan
    }
    public func start(source: String, name: String, options: CodemodeRunOptions) async throws -> any CodemodeRun {
        guard !closed else { throw CodemodeError(kind: .sandbox, message: "Sandbox is closed") }
        try options.validate()
        guard !name.isEmpty else { throw CodemodeProtocolError.invalidSourceName }
        starts.append(Start(source: source, name: name, options: options))
        let run = DeterministicCodemodeRun(source: source, name: name, options: options, plan: plan)
        nextRunID += 1
        let id = nextRunID
        activeRuns[id] = run
        await run.begin(fingerprint: fingerprint)
        if await run.finished { activeRuns.removeValue(forKey: id) }
        else {
            Task { [weak self] in
                _ = await run.result
                await self?.removeRun(id)
            }
        }
        return run
    }
    /// Aborts current runs and rejects later starts, like the upstream sandbox close.
    public func close() async {
        closed = true
        let runs = Array(activeRuns.values)
        activeRuns.removeAll()
        for run in runs { await run.abort(message: "Sandbox closed") }
    }
    private func removeRun(_ id: Int) { activeRuns.removeValue(forKey: id) }
}

private actor DeterministicCodemodeRun: CodemodeRun {
    private let source: String
    private let name: String
    private let options: CodemodeRunOptions
    private let plan: DeterministicCodemodeSandbox.Plan
    private var now: Double
    private var calls: [CodemodeHostCall] = []
    private var records: [Int: CodemodeCall] = [:]
    private var waiting: Set<Int> = []
    private var received: Set<Int> = []
    private var buffered: [Int: DeterministicCodemodeDelivery] = [:]
    private var deliveries: [DeterministicCodemodeDelivery] = []
    private var output: [CodemodeOutputItem] = []
    private var terminal: CodemodeResult?
    private var waiters: [CheckedContinuation<CodemodeResult, Never>] = []
    private var processing = false
    private var deadline: Task<Void, Never>?
    init(source: String, name: String, options: CodemodeRunOptions, plan: @escaping DeterministicCodemodeSandbox.Plan) {
        self.source = source; self.name = name; self.options = options; self.plan = plan; self.now = options.startedAt
    }
    var finished: Bool { terminal != nil }
    var result: CodemodeResult {
        get async {
            if let terminal { return terminal }
            return await withCheckedContinuation { waiters.append($0) }
        }
    }
    func begin(fingerprint: String) async {
        processing = true
        if let timeout = options.timeoutMs, timeout.isFinite {
            deadline = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(timeout / 1000)) } catch { return }
                await self?.timeOut(timeout)
            }
        }
        await options.onStarted(fingerprint, self)
        if !finished { await advance() }
        processing = false
        await drain()
    }
    func deliver(seq: Int, now: Double, id: Int, outcome: CodemodeOutcome) async throws {
        if finished { return }
        guard now.isFinite else { throw CodemodeProtocolError.invalidClock }
        guard seq > 0, !received.contains(seq) else { throw CodemodeProtocolError.invalidSequence(seq) }
        guard waiting.contains(id) else { throw CodemodeProtocolError.callNotWaiting(id) }
        guard outcome.isStrictJSON else { throw CodemodeProtocolError.invalidJSON }
        received.insert(seq)
        waiting.remove(id)
        if var record = records[id] {
            if case .success = outcome { record.status = .ok } else { record.status = .error }
            records[id] = record
        }
        buffered[seq] = .init(seq: seq, now: now, id: id, outcome: outcome)
        await drain()
    }
    func abort(message: String) { finish(.init(error: .init(kind: .aborted, message: message)), scriptEnded: false) }
    private func timeOut(_ timeout: Double) {
        finish(.init(error: .init(kind: .timeout, message: "Execution timed out after \(timeout) ms")), scriptEnded: false)
    }
    private func drain() async {
        guard !processing else { return }
        processing = true
        defer { processing = false }
        while !finished, var delivery = buffered.removeValue(forKey: deliveries.count + 1) {
            now = max(now, delivery.now)
            delivery.now = now
            deliveries.append(delivery)
            await advance()
        }
    }
    private func advance() async {
        let state = DeterministicCodemodeState(source: source, name: name, options: options, now: now,
                                               calls: calls, deliveries: deliveries)
        let step = plan(state)
        output.append(contentsOf: step.output)
        var issued: [CodemodeHostCall] = []
        for planned in step.calls {
            let declared: Bool
            switch planned.target {
            case .tool: declared = options.tools.contains { $0.name.utf16.elementsEqual(planned.name.utf16) }
            case .global: declared = options.globals.contains { $0.name.utf16.elementsEqual(planned.name.utf16) }
            }
            guard declared, planned.args?.isStrictJSON ?? true else {
                finish(.init(error: .init(kind: .sandbox, message: "Invalid planned call: \(planned.name)")), scriptEnded: false)
                return
            }
            let call = CodemodeHostCall(id: calls.count + 1, target: planned.target, name: planned.name, args: planned.args)
            calls.append(call); waiting.insert(call.id); issued.append(call)
            if call.target == .tool { records[call.id] = .init(name: call.name, status: .cancelled) }
        }
        for call in issued {
            guard !finished else { return }
            await options.onCall(call, self)
        }
        guard !finished else { return }
        if let result = step.result { finish(result, scriptEnded: true) }
        else { await options.onIdle(deliveries.count, calls.count, self) }
    }
    private func finish(_ result: CodemodeResult, scriptEnded: Bool) {
        guard terminal == nil else { return }
        var result = result
        result.output = output + result.output
        result.calls = calls.compactMap { records[$0.id] }
        result.during = scriptEnded ? .init(seq: deliveries.count, issued: calls.count) : nil
        if !result.ok { result.storeWrites = nil }
        terminal = result
        deadline?.cancel(); deadline = nil
        buffered.removeAll(); waiting.removeAll()
        let pending = waiters; waiters.removeAll()
        for waiter in pending { waiter.resume(returning: result) }
    }
}
