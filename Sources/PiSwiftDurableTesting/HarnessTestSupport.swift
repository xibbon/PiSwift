import Synchronization
import PiSwiftChord
import PiSwiftDurable

/// Error reports from concurrent handlers.
public final class HarnessReports: Sendable {
    private let state = Mutex<[any Error]>([])
    /// Creates an empty collection of concurrent handler reports.
    public init() {}
    /// The error reports recorded so far.
    public var values: [any Error] { state.withLock { $0 } }
    /// The number of values currently recorded.
    public var count: Int { state.withLock { $0.count } }
    /// Records one error report for later test inspection.
    public func append(_ error: any Error) { state.withLock { $0.append(error) } }
}
/// An opened test harness with its registry and captured error reports.
public struct OpenHarnessResult: Sendable {
    /// The opened harness returned by test setup.
    public let harness: Harness
    /// The installed extension and task definitions used by this harness.
    public let registry: Registry
    /// Errors captured from concurrent test handlers.
    public let reports: HarnessReports
}
/// Opens a test harness with fake models and captured error reports.
public func openHarness(storage: any DurableStorage = MemoryStorage(), registry: Registry = Registry(),
                        settings: HarnessSettingsProvider? = nil,
                        clock: any DurableClock = SystemDurableClock(),
                        context: ChordContext = .background) async throws -> OpenHarnessResult {
    let reports = HarnessReports()
    let harness = try await Harness.open(storage: storage,
        options: HarnessOptions(models: FakeDurableModels(), registry: registry, settings: settings,
                                clock: clock, onReport: { reports.append($0) }), context: context)
    return OpenHarnessResult(harness: harness, registry: registry, reports: reports)
}
/// Installs application tasks and opens a test harness with fake models.
public func openTasks(storage: any DurableStorage = MemoryStorage(), tasks: [AnyTaskDefinition],
                      registry: Registry = Registry(), now: (@Sendable () -> Int64)? = nil,
                      settings: HarnessSettingsProvider? = nil,
                      clock: any DurableClock = SystemDurableClock(),
                      context: ChordContext = .background) async throws -> OpenHarnessResult {
    if !tasks.isEmpty { try registry.install(Extension(name: "tasks", tasks: tasks)) }
    let reports = HarnessReports()
    let harness = try await Harness.open(storage: storage,
        options: HarnessOptions(models: FakeDurableModels(), registry: registry, settings: settings,
                                clock: clock, now: now, onReport: { reports.append($0) }), context: context)
    return OpenHarnessResult(harness: harness, registry: registry, reports: reports)
}
/// Creates a completed terminal task state with a JSON-encoded result.
public func completed<Result: Codable & Sendable>(_ result: Result) throws -> TaskState {
    .terminal(outcome: .completed(result: try JSONValue(encoding: result)))
}
/// Creates an aborted terminal task state with the supplied reason.
public func abortedWith(_ reason: String) -> TaskState { .terminal(outcome: .aborted(reason: reason)) }
/// A test condition did not complete before its deadline.
public struct TestDeadlineError: Error, Sendable {
    /// Creates the error for an expired test condition deadline.
    public init() {}
}
/// Recheck until the condition is true or the deadline expires. No fixed delay controls correctness.
public func eventually(timeout: Duration = .seconds(5),
                       _ check: @escaping @Sendable () async throws -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while try await !check() {
        guard ContinuousClock.now < deadline else { throw TestDeadlineError() }
        try Task.checkCancellation()
        await Task.yield()
    }
}
/// An observer of completion, including a failed operation.
public final class SettledObserver<Value: Sendable>: Sendable {
    private let state = Mutex<Result<Value, any Error>?>(nil)
    /// Starts the operation and records either its value or error.
    public init(_ operation: @escaping @Sendable () async throws -> Value) {
        Task { [self] in
            let result: Result<Value, any Error>
            do { result = .success(try await operation()) } catch { result = .failure(error) }
            state.withLock { $0 = result }
        }
    }
    /// Whether the observed operation has completed, including failure.
    public var isSettled: Bool { state.withLock { $0 != nil } }
    /// The completed operation result, including failure when present.
    public var result: Result<Value, any Error>? { state.withLock { $0 } }
}
/// Starts a test operation and returns an observer of its completion.
public func settled<Value: Sendable>(_ operation: @escaping @Sendable () async throws -> Value) -> SettledObserver<Value> {
    SettledObserver(operation)
}
/// Registry reader with a count of active subscriptions.
public final class CountingRegistryReader: RegistryReader, Sendable {
    private let registry: any RegistryReader
    private let count = Mutex(0)
    /// Wraps a registry reader with an active-listener counter.
    public init(_ registry: any RegistryReader) { self.registry = registry }
    /// The number of registry listeners that have not been removed.
    public var subscriptionCount: Int { count.withLock { $0 } }
    /// Returns the current immutable registry snapshot.
    public func snapshot() -> RegistrySnapshot { registry.snapshot() }
    /// Adds a registry-publication listener, counts it, and returns an idempotent removal closure.
    public func subscribe(_ listener: @escaping @Sendable () -> Void) -> @Sendable () -> Void {
        count.withLock { $0 += 1 }
        let remove = registry.subscribe(listener)
        let active = Mutex(true)
        return { [self] in
            let shouldRemove = active.withLock { value in let wasActive = value; value = false; return wasActive }
            if shouldRemove { count.withLock { $0 -= 1 }; remove() }
        }
    }
}
/// Wraps a registry reader and counts its active subscriptions.
public func countingReader(_ registry: any RegistryReader) -> CountingRegistryReader { CountingRegistryReader(registry) }
