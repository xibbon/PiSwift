import Foundation

public final class EventStream<Element: Sendable, Result: Sendable>: AsyncSequence, Sendable {
    public typealias AsyncIterator = AsyncStream<Element>.Iterator

    private let stream: AsyncStream<Element>
    private let continuation: AsyncStream<Element>.Continuation
    private let isComplete: @Sendable (Element) -> Bool
    private let extractResult: @Sendable (Element) -> Result
    private let state = LockedState(State())

    private struct State: Sendable {
        var done = false
        var resultValue: Result?
        var resultContinuation: CheckedContinuation<Result, Never>?
    }

    public init(isComplete: @escaping @Sendable (Element) -> Bool, extractResult: @escaping @Sendable (Element) -> Result) {
        self.isComplete = isComplete
        self.extractResult = extractResult
        var capturedContinuation: AsyncStream<Element>.Continuation!
        self.stream = AsyncStream { continuation in
            capturedContinuation = continuation
        }
        self.continuation = capturedContinuation
    }

    public func push(_ event: Element) {
        var resumeContinuation: CheckedContinuation<Result, Never>?
        var resumeValue: Result?
        let shouldProcess = state.withLock { state in
            guard !state.done else { return false }
            if isComplete(event) {
                let result = extractResult(event)
                state.resultValue = result
                resumeContinuation = state.resultContinuation
                state.resultContinuation = nil
                resumeValue = result
            }
            return true
        }

        if let resumeContinuation, let resumeValue {
            resumeContinuation.resume(returning: resumeValue)
        }

        guard shouldProcess else { return }
        _ = continuation.yield(event)
    }

    public func end(_ result: Result? = nil) {
        var resumeContinuation: CheckedContinuation<Result, Never>?
        var resumeValue: Result?
        let shouldFinish = state.withLock { state in
            guard !state.done else { return false }
            state.done = true
            if let result {
                state.resultValue = result
                resumeContinuation = state.resultContinuation
                state.resultContinuation = nil
                resumeValue = result
            }
            return true
        }

        if let resumeContinuation, let resumeValue {
            resumeContinuation.resume(returning: resumeValue)
        }

        guard shouldFinish else { return }
        continuation.finish()
    }

    public func result() async -> Result {
        if let existing = state.withLock({ $0.resultValue }) {
            return existing
        }

        return await withCheckedContinuation { continuation in
            var immediate: Result?
            state.withLock { state in
                if let value = state.resultValue {
                    immediate = value
                } else {
                    state.resultContinuation = continuation
                }
            }
            if let immediate {
                continuation.resume(returning: immediate)
            }
        }
    }

    public func makeAsyncIterator() -> AsyncStream<Element>.Iterator {
        stream.makeAsyncIterator()
    }
}

/// A stream for one assistant response. The first terminal event settles the stream.
public final class AssistantMessageEventStream: AsyncSequence, Sendable {
    public typealias Element = AssistantMessageEvent
    public typealias AsyncIterator = AsyncStream<Element>.Iterator

    private let stream: AsyncStream<Element>
    private let continuation: AsyncStream<Element>.Continuation
    private let startedAt: Int64
    private let startedAtMonotonic: ContinuousClock.Instant
    private let state = LockedState(State())
    private let onStart = LockedState<(@Sendable () -> Void)?>(nil)

    private struct State: Sendable {
        var settled = false
        var pending: [Element] = []
        var publishing = false
        var resultValue: AssistantMessage?
        var resultContinuation: CheckedContinuation<AssistantMessage, Never>?
    }

    public init() {
        startedAt = Int64(Date().timeIntervalSince1970 * 1000)
        startedAtMonotonic = ContinuousClock.now
        let pair = AsyncStream<Element>.makeStream()
        stream = pair.stream
        continuation = pair.continuation
    }

    func time(_ message: AssistantMessage) -> AssistantMessage {
        var message = message
        guard message.durationMs == nil, message.timestamp >= startedAt else { return message }
        let elapsed = startedAtMonotonic.duration(to: ContinuousClock.now).components
        let milliseconds = Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15
        message.durationMs = Swift.max(0, Int(milliseconds.rounded()))
        return message
    }

    public func push(_ event: AssistantMessageEvent) {
        var delivered = event
        var resume: CheckedContinuation<AssistantMessage, Never>?
        var result: AssistantMessage?
        let publish = state.withLock { state in
            guard !state.settled else { return false }
            switch event {
            case .done(let reason, let message):
                let timed = time(message)
                delivered = .done(reason: reason, message: timed)
                result = timed
            case .error(let reason, let message):
                let timed = time(message)
                delivered = .error(reason: reason, error: timed)
                result = timed
            default:
                break
            }
            if let result {
                state.settled = true
                state.resultValue = result
                resume = state.resultContinuation
                state.resultContinuation = nil
            }
            state.pending.append(delivered)
            guard !state.publishing else { return false }
            state.publishing = true
            return true
        }
        if publish { publishPending() }
        if let result { resume?.resume(returning: result) }
    }

    // One publisher keeps push/end order while it calls the continuation outside the lock.
    private func publishPending() {
        while true {
            let batch = state.withLock { state -> (events: [Element], finish: Bool) in
                guard !state.pending.isEmpty else {
                    state.publishing = false
                    return ([], state.settled)
                }
                let events = state.pending
                state.pending.removeAll(keepingCapacity: true)
                return (events, false)
            }
            for event in batch.events { continuation.yield(event) }
            if batch.events.isEmpty {
                if batch.finish { continuation.finish() }
                return
            }
        }
    }

    /// Start a deferred producer when the stream is observed for the first time.
    public func setOnStart(_ action: @escaping @Sendable () -> Void) {
        onStart.withLock { $0 = action }
    }

    private func startIfNeeded() {
        let action = onStart.withLock { action -> (@Sendable () -> Void)? in
            let pending = action
            action = nil
            return pending
        }
        action?()
    }

    public func end(_ result: AssistantMessage? = nil) {
        var resume: CheckedContinuation<AssistantMessage, Never>?
        var timed: AssistantMessage?
        let publish = state.withLock { state in
            if !state.settled, let result {
                timed = time(result)
                state.resultValue = timed
                resume = state.resultContinuation
                state.resultContinuation = nil
            }
            state.settled = true
            guard !state.publishing else { return false }
            state.publishing = true
            return true
        }
        if publish { publishPending() }
        if let timed { resume?.resume(returning: timed) }
    }

    public func result() async -> AssistantMessage {
        startIfNeeded()
        return await withCheckedContinuation { continuation in
            var immediate: AssistantMessage?
            state.withLock { state in
                if let result = state.resultValue {
                    immediate = result
                } else {
                    state.resultContinuation = continuation
                }
            }
            if let immediate { continuation.resume(returning: immediate) }
        }
    }

    public func makeAsyncIterator() -> AsyncStream<Element>.Iterator {
        startIfNeeded()
        return stream.makeAsyncIterator()
    }
}
