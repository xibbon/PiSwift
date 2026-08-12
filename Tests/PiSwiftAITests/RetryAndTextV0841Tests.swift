import Testing
@testable import PiSwiftAI

private func retryTestMessage(
    stopReason: StopReason,
    text: String = "",
    errorMessage: String? = nil
) -> AssistantMessage {
    AssistantMessage(
        content: [.text(TextContent(text: text))],
        api: .openAICompletions,
        provider: "faux",
        model: "faux-1",
        usage: Usage(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0),
        stopReason: stopReason,
        errorMessage: errorMessage
    )
}

@Test func retryAssistantCallRetriesTransientFailureAndOrdersCallbacks() async {
    let calls = LockedState(0)
    let events = LockedState<[String]>([])
    let response = await retryAssistantCall(
        produce: {
            let call = calls.withLock { count -> Int in
                count += 1
                return count
            }
            events.withLock { $0.append("produce:\(call)") }
            if call < 3 {
                return retryTestMessage(stopReason: .error, errorMessage: "terminated")
            }
            return retryTestMessage(stopReason: .stop, text: "recovered")
        },
        policy: RetryPolicy(enabled: true, maxRetries: 3, baseDelayMs: 0),
        callbacks: RetryCallbacks(
            onRetryScheduled: { attempt, maxAttempts, delayMs, errorMessage in
                events.withLock {
                    $0.append("scheduled:\(attempt)/\(maxAttempts):\(Int(delayMs)):\(errorMessage)")
                }
            },
            onRetryAttemptStart: {
                events.withLock { $0.append("attempt-start") }
            },
            onRetryFinished: { success, attempt, finalError in
                events.withLock {
                    $0.append("finished:\(success):\(attempt):\(finalError ?? "nil")")
                }
            }
        )
    )

    #expect(response.stopReason == .stop)
    #expect(contentText(response.content) == "recovered")
    #expect(calls.withLock { $0 } == 3)
    #expect(events.withLock { $0 } == [
        "produce:1",
        "scheduled:1/3:0:terminated",
        "attempt-start",
        "produce:2",
        "scheduled:2/3:0:terminated",
        "attempt-start",
        "produce:3",
        "finished:true:2:nil",
    ])
}

@Test func retryAssistantCallStopsAtRetryBound() async {
    let calls = LockedState(0)
    let finished = LockedState<(Bool, Int, String?)?>(nil)
    let response = await retryAssistantCall(
        produce: {
            calls.withLock { $0 += 1 }
            return retryTestMessage(stopReason: .error, errorMessage: "503 service unavailable")
        },
        policy: RetryPolicy(enabled: true, maxRetries: 2, baseDelayMs: 0),
        callbacks: RetryCallbacks(
            onRetryFinished: { success, attempt, error in
                finished.withLock { $0 = (success, attempt, error) }
            }
        )
    )

    #expect(response.stopReason == .error)
    #expect(response.errorMessage == "503 service unavailable")
    #expect(calls.withLock { $0 } == 3)
    #expect(finished.withLock { $0?.0 } == false)
    #expect(finished.withLock { $0?.1 } == 2)
    #expect(finished.withLock { $0?.2 } == "503 service unavailable")
}

@Test func retryAssistantCallAbortsBackoffPromptly() async {
    let token = CancellationToken()
    let retryScheduled = LockedState(false)
    let finished = LockedState<(Bool, Int, String?)?>(nil)
    let clock = ContinuousClock()
    let start = clock.now
    let task = Task {
        await retryAssistantCall(
            produce: {
                retryTestMessage(stopReason: .error, errorMessage: "terminated")
            },
            policy: RetryPolicy(enabled: true, maxRetries: 5, baseDelayMs: 10_000),
            signal: token,
            callbacks: RetryCallbacks(
                onRetryScheduled: { _, _, _, _ in
                    retryScheduled.withLock { $0 = true }
                },
                onRetryFinished: { success, attempt, error in
                    finished.withLock { $0 = (success, attempt, error) }
                }
            )
        )
    }

    while !retryScheduled.withLock({ $0 }) {
        await Task.yield()
    }
    token.cancel()
    let response = await task.value
    let elapsed = start.duration(to: clock.now)

    #expect(response.stopReason == .aborted)
    #expect(response.errorMessage == nil)
    #expect(elapsed < .seconds(1))
    #expect(finished.withLock { $0?.0 } == false)
    #expect(finished.withLock { $0?.1 } == 1)
    #expect(finished.withLock { $0?.2 } == "terminated")
}

@Test func contentTextJoinsOnlyTextBlocks() {
    let blocks: [ContentBlock] = [
        .thinking(ThinkingContent(thinking: "hidden")),
        .text(TextContent(text: "first")),
        .toolCall(ToolCall(id: "1", name: "read", arguments: [:])),
        .image(ImageContent(data: "...", mimeType: "image/png")),
        .text(TextContent(text: "second")),
    ]

    #expect(contentText(blocks) == "first\nsecond")
    #expect(contentText(blocks, separator: "") == "firstsecond")
    #expect(contentText(UserContent.blocks(blocks), separator: "|") == "first|second")
    #expect(contentText(UserContent.text("hello")) == "hello")
    #expect(contentText("hello") == "hello")
}
