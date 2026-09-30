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

public final class AssistantMessageEventStream: AsyncSequence, Sendable {
    public typealias Element = AssistantMessageEvent
    public typealias AsyncIterator = AsyncStream<Element>.Iterator

    private let inner: EventStream<Element, AssistantMessage>
    private let onStart = LockedState<(@Sendable () -> Void)?>(nil)

    public init() {
        self.inner = EventStream<Element, AssistantMessage>(
            isComplete: { event in
                switch event {
                case .done, .error:
                    return true
                default:
                    return false
                }
            },
            extractResult: { event in
                switch event {
                case .done(_, let message):
                    return message
                case .error(_, let error):
                    return error
                default:
                    return AssistantMessage(
                        content: [],
                        api: .openAICompletions,
                        provider: "unknown",
                        model: "unknown",
                        usage: Usage(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0),
                        stopReason: .error,
                        errorMessage: "Unexpected event type for final result"
                    )
                }
            }
        )
    }

    public func push(_ event: AssistantMessageEvent) {
        inner.push(event)
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
        if let result = result {
            inner.end(result)
        } else {
            inner.end(nil)
        }
    }

    public func result() async -> AssistantMessage {
        startIfNeeded()
        return await inner.result()
    }

    public func makeAsyncIterator() -> AsyncStream<Element>.Iterator {
        startIfNeeded()
        return inner.makeAsyncIterator()
    }
}
