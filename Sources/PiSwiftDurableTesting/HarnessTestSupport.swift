import Synchronization
import PiSwiftChord
import PiSwiftDurable

/// Error reports from concurrent handlers.
public final class HarnessReports: Sendable {
    private let state = Mutex<[any Error]>([])
    public init() {}
    public var values: [any Error] { state.withLock { $0 } }
    public var count: Int { state.withLock { $0.count } }
    public func append(_ error: any Error) { state.withLock { $0.append(error) } }
}
public struct OpenHarnessResult: Sendable {
    public let harness: Harness
    public let registry: Registry
    public let reports: HarnessReports
}
public func openHarness(storage: any DurableStorage = MemoryStorage(), registry: Registry = Registry(),
                        settings: HarnessSettingsProvider? = nil,
                        clock: any DurableClock = SystemDurableClock(),
                        context: PiSwiftChord.Context = .background) async throws -> OpenHarnessResult {
    let reports = HarnessReports()
    let harness = try await Harness.open(storage: storage,
        options: HarnessOptions(models: FakeDurableModels(), registry: registry, settings: settings,
                                clock: clock, onReport: { reports.append($0) }), context: context)
    return OpenHarnessResult(harness: harness, registry: registry, reports: reports)
}
public func openTasks(storage: any DurableStorage = MemoryStorage(), tasks: [AnyTaskDefinition],
                      registry: Registry = Registry(), now: (@Sendable () -> Int64)? = nil,
                      settings: HarnessSettingsProvider? = nil,
                      clock: any DurableClock = SystemDurableClock(),
                      context: PiSwiftChord.Context = .background) async throws -> OpenHarnessResult {
    if !tasks.isEmpty { try registry.install(Extension(name: "tasks", tasks: tasks)) }
    let reports = HarnessReports()
    let harness = try await Harness.open(storage: storage,
        options: HarnessOptions(models: FakeDurableModels(), registry: registry, settings: settings,
                                clock: clock, now: now, onReport: { reports.append($0) }), context: context)
    return OpenHarnessResult(harness: harness, registry: registry, reports: reports)
}
public func completed<Result: Codable & Sendable>(_ result: Result) throws -> TaskState {
    .terminal(outcome: .completed(result: try JSONValue(encoding: result)))
}
public func abortedWith(_ reason: String) -> TaskState { .terminal(outcome: .aborted(reason: reason)) }
public struct TestDeadlineError: Error, Sendable { public init() {} }
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
    public init(_ operation: @escaping @Sendable () async throws -> Value) {
        Task { [self] in
            let result: Result<Value, any Error>
            do { result = .success(try await operation()) } catch { result = .failure(error) }
            state.withLock { $0 = result }
        }
    }
    public var isSettled: Bool { state.withLock { $0 != nil } }
    public var result: Result<Value, any Error>? { state.withLock { $0 } }
}
public func settled<Value: Sendable>(_ operation: @escaping @Sendable () async throws -> Value) -> SettledObserver<Value> {
    SettledObserver(operation)
}
/// Registry reader with a count of active subscriptions.
public final class CountingRegistryReader: RegistryReader, Sendable {
    private let registry: any RegistryReader
    private let count = Mutex(0)
    public init(_ registry: any RegistryReader) { self.registry = registry }
    public var subscriptionCount: Int { count.withLock { $0 } }
    public func snapshot() -> RegistrySnapshot { registry.snapshot() }
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
public func countingReader(_ registry: any RegistryReader) -> CountingRegistryReader { CountingRegistryReader(registry) }
