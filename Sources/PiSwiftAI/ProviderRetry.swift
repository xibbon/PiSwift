import Foundation

public let DEFAULT_MAX_RETRY_DELAY_MS = 60_000

/// Provider errors can expose status and response headers to the shared retry policy.
public protocol ProviderError: Error, Sendable {
    var providerStatusCode: Int? { get }
    var providerHeaders: [String: String]? { get }
}

extension StreamError: ProviderError {
    public var providerStatusCode: Int? {
        guard case .providerRequest(let statusCode, _, _) = self else { return nil }
        return statusCode
    }

    public var providerHeaders: [String: String]? {
        guard case .providerRequest(_, let headers, _) = self else { return nil }
        return headers
    }
}

public func isProviderError(_ error: Error) -> Bool {
    providerMetadata(error) != nil
}

public func isRetryableProviderError(_ error: Error) -> Bool {
    if let providerError = providerMetadata(error) {
        let shouldRetry = headerValue("x-should-retry", in: providerError.headers)
        if shouldRetry == "true" { return true }
        if shouldRetry == "false" { return false }

        guard let status = providerError.statusCode else { return true }
        return status == 408 || status == 409 || status == 429 || status >= 500
    }
    return isRetryableTransportError(error)
}

func validateServerRetryDelayMs(
    _ delayMs: Double,
    maxRetryDelayMs: Int?,
    providerErrorMessage: String
) throws -> Double? {
    guard delayMs.isFinite, delayMs >= 0 else { return nil }
    let maximum = Double(maxRetryDelayMs ?? DEFAULT_MAX_RETRY_DELAY_MS)
    if maximum > 0, delayMs > maximum {
        throw StreamError.retryDelayExceedsMaximum(
            requestedMs: delayMs,
            maximumMs: maximum,
            providerMessage: providerErrorMessage
        )
    }
    return delayMs
}

public func getRetryDelayMs(
    error: Error,
    retryIndex: Int,
    maxRetryDelayMs: Int? = nil
) throws -> Double {
    if let providerError = providerMetadata(error) {
        if let raw = headerValue("retry-after-ms", in: providerError.headers),
           let value = parseLeadingDouble(raw),
           let valid = try validateServerRetryDelayMs(
               value,
               maxRetryDelayMs: maxRetryDelayMs,
               providerErrorMessage: error.localizedDescription
           ) {
            return valid
        }

        if let raw = headerValue("retry-after", in: providerError.headers) {
            let delayMs: Double?
            if let seconds = parseLeadingDouble(raw) {
                delayMs = seconds * 1_000
            } else {
                delayMs = parseHTTPDate(raw).map { $0.timeIntervalSinceNow * 1_000 }
            }
            if let delayMs,
               let valid = try validateServerRetryDelayMs(
                   delayMs,
                   maxRetryDelayMs: maxRetryDelayMs,
                   providerErrorMessage: error.localizedDescription
               ) {
                return valid
            }
        }
    }

    // `maxRetryDelayMs` governs only *server-requested* delays: it means "fail fast rather than
    // wait this long", not "clamp every wait". Upstream deliberately does not apply it to the
    // fallback backoff, which is already bounded at 8s by its own formula. Clamping here would
    // make an explicit small cap retry *more* aggressively against a struggling provider.
    let index = max(0, retryIndex)
    let exponential = min(500 * pow(2, Double(index)), 8_000)
    return exponential * Double.random(in: 0.75...1.0)
}

public func abortableSleep(ms: Double, signal: CancellationToken? = nil) async throws {
    let delay = max(0, ms)
    try await runAbortable(signal: signal) {
        try await Task.sleep(for: .milliseconds(delay))
    }
}

public func retryProviderRequest<T: Sendable>(
    maxRetries: Int? = nil,
    maxRetryDelayMs: Int? = nil,
    signal: CancellationToken? = nil,
    request: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await retryProviderRequestDriver(
        maxRetries: maxRetries,
        maxRetryDelayMs: maxRetryDelayMs,
        signal: signal,
        abortRequestOnSignal: true,
        request: request
    )
}

private typealias RetryScheduledHandler = @Sendable (
    _ attempt: Int,
    _ maxAttempts: Int,
    _ delayMs: Double,
    _ error: Error
) async -> Void

private func retryProviderRequestDriver<T: Sendable>(
    maxRetries: Int?,
    maxRetryDelayMs: Int?,
    signal: CancellationToken?,
    abortRequestOnSignal: Bool,
    onRetryScheduled: RetryScheduledHandler? = nil,
    onRetryAttemptStart: (@Sendable () async -> Void)? = nil,
    request: @escaping @Sendable () async throws -> T
) async throws -> T {
    let retryLimit = max(0, maxRetries ?? 0)
    var retriesRemaining = retryLimit

    while true {
        do {
            if abortRequestOnSignal {
                return try await runAbortable(signal: signal, operation: request)
            }
            return try await request()
        } catch {
            if signal?.isCancelled == true {
                throw StreamError.requestAborted
            }
            guard retriesRemaining > 0, isRetryableProviderError(error) else {
                throw error
            }

            let retryIndex = retryLimit - retriesRemaining
            retriesRemaining -= 1
            let delay = try getRetryDelayMs(
                error: error,
                retryIndex: retryIndex,
                maxRetryDelayMs: maxRetryDelayMs
            )
            await onRetryScheduled?(retryIndex + 1, retryLimit, delay, error)
            try await abortableSleep(ms: delay, signal: signal)
            await onRetryAttemptStart?()
        }
    }
}

private struct RetryableAssistantResponseError: ProviderError, LocalizedError {
    var response: AssistantMessage
    var retryDelayMs: Double

    var providerStatusCode: Int? { nil }
    var providerHeaders: [String: String]? {
        ["retry-after-ms": String(retryDelayMs)]
    }
    var errorDescription: String? {
        response.errorMessage ?? "Unknown error"
    }
}

private struct AssistantRetryState: Sendable {
    var latestResponse: AssistantMessage?
    var retryableFailureCount = 0
    var lastScheduledAttempt = 0
    var lastScheduledError: String?
}

/// Runs an assistant-producing call with bounded retries for transient failures.
///
/// This function uses the provider retry driver for retry bounds, delay parsing, and
/// cancellation-aware sleep. It returns error and aborted assistant messages as values.
public func retryAssistantCall(
    produce: @escaping @Sendable () async -> AssistantMessage,
    policy: RetryPolicy?,
    signal: CancellationToken? = nil,
    callbacks: RetryCallbacks? = nil
) async -> AssistantMessage {
    guard policy?.enabled == true, let policy, policy.maxRetries > 0 else {
        return await produce()
    }

    let state = LockedState(AssistantRetryState())

    do {
        let response: AssistantMessage = try await retryProviderRequestDriver(
            maxRetries: policy.maxRetries,
            maxRetryDelayMs: 0,
            signal: signal,
            abortRequestOnSignal: false,
            onRetryScheduled: { attempt, maxAttempts, delayMs, error in
                let message = error.localizedDescription
                state.withLock {
                    $0.lastScheduledAttempt = attempt
                    $0.lastScheduledError = message
                }
                await callbacks?.onRetryScheduled?(attempt, maxAttempts, delayMs, message)
            },
            onRetryAttemptStart: callbacks?.onRetryAttemptStart,
            request: {
                let response = await produce()
                guard isRetryableAssistantError(response) else {
                    return response
                }

                let failureCount = state.withLock { state -> Int in
                    state.latestResponse = response
                    state.retryableFailureCount += 1
                    return state.retryableFailureCount
                }
                let delayMs = max(0, policy.baseDelayMs) * pow(2, Double(failureCount - 1))
                throw RetryableAssistantResponseError(response: response, retryDelayMs: delayMs)
            }
        )

        let attempt = state.withLock { $0.lastScheduledAttempt }
        if attempt > 0 {
            switch response.stopReason {
            case .error:
                await callbacks?.onRetryFinished?(false, attempt, response.errorMessage)
            case .aborted:
                await callbacks?.onRetryFinished?(false, attempt, nil)
            default:
                await callbacks?.onRetryFinished?(true, attempt, nil)
            }
        }
        return response
    } catch let error as RetryableAssistantResponseError {
        let attempt = state.withLock { $0.lastScheduledAttempt }
        await callbacks?.onRetryFinished?(false, attempt, error.response.errorMessage)
        return error.response
    } catch {
        let snapshot = state.withLock { $0 }
        guard var response = snapshot.latestResponse else {
            return await produce()
        }

        let requestWasAborted: Bool
        if let streamError = error as? StreamError, case .requestAborted = streamError {
            requestWasAborted = true
        } else {
            requestWasAborted = false
        }
        let wasCancelled = signal?.isCancelled == true || error is CancellationError
        if wasCancelled || requestWasAborted {
            response.stopReason = .aborted
            response.errorMessage = nil
            await callbacks?.onRetryFinished?(
                false,
                snapshot.lastScheduledAttempt,
                snapshot.lastScheduledError
            )
        } else {
            response.stopReason = .error
            response.errorMessage = error.localizedDescription
            await callbacks?.onRetryFinished?(
                false,
                snapshot.lastScheduledAttempt,
                error.localizedDescription
            )
        }
        return response
    }
}

private func headerValue(_ name: String, in headers: [String: String]?) -> String? {
    headers?.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
}

private func providerMetadata(_ error: Error) -> (statusCode: Int?, headers: [String: String]?)? {
    if let streamError = error as? StreamError {
        guard case .providerRequest(let statusCode, let headers, _) = streamError else {
            return nil
        }
        return (statusCode, headers)
    }
    guard let providerError = error as? any ProviderError else { return nil }
    return (providerError.providerStatusCode, providerError.providerHeaders)
}

private func parseHTTPDate(_ value: String) -> Date? {
    let formats = [
        "EEE',' dd MMM yyyy HH':'mm':'ss z",
        "EEEE',' dd-MMM-yy HH':'mm':'ss z",
        "EEE MMM d HH':'mm':'ss yyyy",
    ]
    for format in formats {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = format
        if let date = formatter.date(from: value) {
            return date
        }
    }
    return nil
}

private func parseLeadingDouble(_ value: String) -> Double? {
    Scanner(string: value).scanDouble()
}

private final class AbortRace<Value: Sendable>: Sendable {
    private struct State: Sendable {
        var continuation: CheckedContinuation<Value, Error>?
        var task: Task<Void, Never>?
        var cancellationHandlerID: UUID?
        var pendingResult: Result<Value, Error>?
        var isFinished = false
    }

    private let state = LockedState(State())
    private let signal: CancellationToken?

    init(signal: CancellationToken?) {
        self.signal = signal
    }

    func install(_ continuation: CheckedContinuation<Value, Error>) {
        let pending = state.withLock { state -> Result<Value, Error>? in
            if let pending = state.pendingResult {
                state.pendingResult = nil
                return pending
            }
            state.continuation = continuation
            return nil
        }
        if let pending {
            continuation.resume(with: pending)
        }
    }

    func setTask(_ task: Task<Void, Never>) {
        let cancel = state.withLock { state -> Bool in
            if state.isFinished { return true }
            state.task = task
            return false
        }
        if cancel { task.cancel() }
    }

    func setCancellationHandlerID(_ id: UUID?) {
        guard let id else { return }
        let remove = state.withLock { state -> Bool in
            if state.isFinished { return true }
            state.cancellationHandlerID = id
            return false
        }
        if remove { signal?.removeCancellationHandler(id) }
    }

    func finish(_ result: Result<Value, Error>) {
        let completion = state.withLock { state -> (CheckedContinuation<Value, Error>?, Task<Void, Never>?, UUID?) in
            guard !state.isFinished else { return (nil, nil, nil) }
            state.isFinished = true
            if state.continuation == nil {
                state.pendingResult = result
            }
            let stored = (state.continuation, state.task, state.cancellationHandlerID)
            state.continuation = nil
            state.task = nil
            state.cancellationHandlerID = nil
            return stored
        }
        completion.1?.cancel()
        if let id = completion.2 {
            signal?.removeCancellationHandler(id)
        }
        completion.0?.resume(with: result)
    }
}

private func runAbortable<T: Sendable>(
    signal: CancellationToken?,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    if signal?.isCancelled == true {
        throw StreamError.requestAborted
    }

    let race = AbortRace<T>(signal: signal)
    return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { continuation in
            race.install(continuation)
            let handlerID = signal?.addCancellationHandler {
                race.finish(.failure(StreamError.requestAborted))
            }
            race.setCancellationHandlerID(handlerID)
            let task = Task {
                do {
                    race.finish(.success(try await operation()))
                } catch {
                    race.finish(.failure(error))
                }
            }
            race.setTask(task)
        }
    } onCancel: {
        race.finish(.failure(CancellationError()))
    }
}
