import Foundation
import Testing
@testable import PiSwiftMCP

#if os(macOS)
private actor CallbackTimeoutSleepRecorder {
    private(set) var durations: [Duration] = []
    private var waiter: CheckedContinuation<Duration, Never>?

    func record(_ duration: Duration) {
        durations.append(duration)
        waiter?.resume(returning: duration)
        waiter = nil
    }

    func first() async -> Duration {
        if let first = durations.first { return first }
        return await withCheckedContinuation { waiter = $0 }
    }
}

@Test("The presenter starts a callback wait greater than 300 seconds", .timeLimit(.minutes(1)))
func macOSOAuthPresenterUsesLongCallbackTimeout() async throws {
    let recorder = CallbackTimeoutSleepRecorder()
    let presenter = McpMacOSSignInPresenter(callbackTimeoutSeconds: 600.5,
        openAuthorizationURL: { _ in }, callbackTimeoutSleep: { duration in
            await recorder.record(duration)
            try await Task.sleep(for: .seconds(86_400))
        })
    let redirect = try await presenter.redirectURL(for: "long-timeout")
    #expect(redirect.port != nil)
    #expect(await recorder.first() == .seconds(600.5))
    await presenter.cancel()
}

@Test("The presenter accepts the largest finite positive timeout", .timeLimit(.minutes(1)))
func macOSOAuthPresenterAcceptsLargestFiniteCallbackTimeout() async throws {
    let recorder = CallbackTimeoutSleepRecorder()
    let presenter = McpMacOSSignInPresenter(callbackTimeoutSeconds: .greatestFiniteMagnitude,
        openAuthorizationURL: { _ in }, callbackTimeoutSleep: { duration in
            await recorder.record(duration)
            try await Task.sleep(for: .seconds(86_400))
        })
    let redirect = try await presenter.redirectURL(for: "largest-timeout")
    #expect(redirect.port != nil)
    let step = await recorder.first()
    #expect(step > .zero)
    #expect(step <= .seconds(86_400))
    await presenter.cancel()
}

@Test("The default callback timeout is 300 seconds")
func macOSOAuthPresenterDefaultCallbackTimeout() async throws {
    let presenter = McpMacOSSignInPresenter(openAuthorizationURL: { _ in })
    let timeout = await presenter.callbackTimeout
    #expect(timeout.seconds == 300)
}

@Test("The callback wait expires at the configured timeout", .timeLimit(.minutes(1)))
func macOSOAuthPresenterCallbackTimeoutExpires() async throws {
    let presenter = McpMacOSSignInPresenter(callbackTimeoutSeconds: 0.02,
        openAuthorizationURL: { _ in })
    _ = try await presenter.redirectURL(for: "short-timeout")
    do {
        _ = try await presenter.present(authorizationURL: URL(string: "https://auth.example/authorize")!,
            state: "short-timeout")
        Issue.record("Sign-in did not time out")
    } catch {
        #expect(error.localizedDescription == "MCP sign-in timed out")
    }
    await presenter.cancel()
}

@Test("The callback timeout rejects zero, negative, and nonfinite seconds",
    .timeLimit(.minutes(1)), arguments: [0.0, -1.0, .infinity, -.infinity, .nan])
func macOSOAuthPresenterRejectsInvalidCallbackTimeout(seconds: Double) async throws {
    let presenter = McpMacOSSignInPresenter(callbackTimeoutSeconds: seconds,
        openAuthorizationURL: { _ in })
    await #expect(throws: McpOAuthError.self) {
        _ = try await presenter.redirectURL(for: "invalid-timeout")
    }
}

private actor CallbackTimerGate {
    private var entered = false
    private var released = false
    private var finished = false
    private var sleepWaiter: CheckedContinuation<Void, Never>?
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var finishWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var cancelled = false

    func sleep() async {
        entered = true
        for waiter in entryWaiters { waiter.resume() }
        entryWaiters.removeAll()
        if !released {
            await withCheckedContinuation { sleepWaiter = $0 }
        }
    }

    func waitForEntry() async {
        if entered { return }
        await withCheckedContinuation { entryWaiters.append($0) }
    }

    func release() {
        released = true
        sleepWaiter?.resume()
        sleepWaiter = nil
    }

    func finish(cancelled: Bool) {
        self.cancelled = cancelled
        finished = true
        for waiter in finishWaiters { waiter.resume() }
        finishWaiters.removeAll()
    }

    func waitForFinish() async {
        if finished { return }
        await withCheckedContinuation { finishWaiters.append($0) }
    }
}

private actor CallbackTimerSequence {
    private var gates: [CallbackTimerGate]
    init(_ gates: [CallbackTimerGate]) { self.gates = gates }
    func next() -> CallbackTimerGate { gates.removeFirst() }
}

private actor PresenterOpenSignal {
    private var opened = false
    private var waiter: CheckedContinuation<Void, Never>?

    func signal() {
        opened = true
        waiter?.resume()
        waiter = nil
    }

    func wait() async {
        if opened { return }
        await withCheckedContinuation { waiter = $0 }
    }
}

private func waitForClosedCallbackListener(_ url: URL) async {
    let session = URLSession(configuration: .ephemeral)
    defer { session.invalidateAndCancel() }
    let request = URLRequest(url: url, timeoutInterval: 1)
    while true {
        do { _ = try await session.data(for: request) }
        catch { return }
    }
}

@Test("An early callback remains successful after the timer expires", .timeLimit(.minutes(1)))
func macOSOAuthPresenterKeepsEarlyCallbackAfterTimeout() async throws {
    let timer = CallbackTimerGate()
    let presenter = McpMacOSSignInPresenter(callbackTimeoutSeconds: 600,
        openAuthorizationURL: { _ in }, callbackTimeoutSleep: { _ in
            await timer.sleep()
            await timer.finish(cancelled: Task.isCancelled)
        })
    let redirect = try await presenter.redirectURL(for: "early")
    await timer.waitForEntry()
    let callback = try #require(URL(string: "\(redirect.absoluteString)?code=early-code&state=early"))
    _ = try await URLSession.shared.data(from: callback)
    await timer.release()
    await timer.waitForFinish()
    // Wait for the timer to close the listener before presentation starts.
    // No delay is needed between callback settlement and timer release.
    await waitForClosedCallbackListener(callback)
    let result = try await presenter.present(authorizationURL: URL(string: "https://auth.example/authorize")!,
        state: "early")
    // The shared callback server builds components from the request path.
    #expect(result == URL(string: "http://localhost/callback?code=early-code&state=early"))
    await presenter.cancel()
}

@Test("A pasted redirect stops the callback timer", .timeLimit(.minutes(1)))
func macOSOAuthPresenterPasteCancelsCallbackTimeout() async throws {
    let timer = CallbackTimerGate()
    let pasted = URL(string: "http://127.0.0.1/callback?code=pasted&state=paste")!
    let presenter = McpMacOSSignInPresenter(callbackTimeoutSeconds: 600,
        pasteRedirectURL: { pasted.absoluteString }, openAuthorizationURL: { _ in },
        callbackTimeoutSleep: { _ in
            await timer.sleep()
            await timer.finish(cancelled: Task.isCancelled)
        })
    _ = try await presenter.redirectURL(for: "paste")
    await timer.waitForEntry()
    let result = try await presenter.present(authorizationURL: URL(string: "https://auth.example/authorize")!,
        state: "paste")
    #expect(result == pasted)
    await timer.release()
    await timer.waitForFinish()
    #expect(await timer.cancelled)
    await presenter.cancel()
}

@Test("Cancel stops an active presentation and its timer", .timeLimit(.minutes(1)))
func macOSOAuthPresenterCancelStopsActivePresentation() async throws {
    let timer = CallbackTimerGate()
    let opened = PresenterOpenSignal()
    let presenter = McpMacOSSignInPresenter(callbackTimeoutSeconds: 600,
        openAuthorizationURL: { _ in await opened.signal() }, callbackTimeoutSleep: { _ in
            await timer.sleep()
            await timer.finish(cancelled: Task.isCancelled)
        })
    _ = try await presenter.redirectURL(for: "cancel")
    await timer.waitForEntry()
    let presentation = Task {
        try await presenter.present(authorizationURL: URL(string: "https://auth.example/authorize")!,
            state: "cancel")
    }
    await opened.wait()
    await presenter.cancel()
    do {
        _ = try await presentation.value
        Issue.record("Presentation did not stop after cancel")
    } catch {
        #expect(error.localizedDescription == "OAuth callback server closed")
    }
    await timer.release()
    await timer.waitForFinish()
    #expect(await timer.cancelled)
}

@Test("A presenter can be used again after a callback timeout", .timeLimit(.minutes(1)))
func macOSOAuthPresenterCanBeUsedAfterTimeout() async throws {
    let firstTimer = CallbackTimerGate()
    let secondTimer = CallbackTimerGate()
    let timers = CallbackTimerSequence([firstTimer, secondTimer])
    let presenter = McpMacOSSignInPresenter(callbackTimeoutSeconds: 600,
        openAuthorizationURL: { authorizationURL in
            guard let redirect = URLComponents(url: authorizationURL, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "redirect_uri" })?.value else { return }
            let callback = try #require(URL(string: "\(redirect)?code=reused&state=second"))
            _ = try await URLSession.shared.data(from: callback)
        }, callbackTimeoutSleep: { _ in
            let timer = await timers.next()
            await timer.sleep()
            await timer.finish(cancelled: Task.isCancelled)
        })
    _ = try await presenter.redirectURL(for: "first")
    await firstTimer.waitForEntry()
    await firstTimer.release()
    do {
        _ = try await presenter.present(authorizationURL: URL(string: "https://auth.example/authorize")!,
            state: "first")
        Issue.record("First presentation did not time out")
    } catch {
        #expect(error.localizedDescription == "MCP sign-in timed out")
    }
    let secondRedirect = try await presenter.redirectURL(for: "second")
    await secondTimer.waitForEntry()
    var authorization = URLComponents(string: "https://auth.example/authorize")!
    authorization.queryItems = [URLQueryItem(name: "redirect_uri", value: secondRedirect.absoluteString)]
    let result = try await presenter.present(authorizationURL: authorization.url!, state: "second")
    #expect(URLComponents(url: result, resolvingAgainstBaseURL: false)?
        .queryItems?.first(where: { $0.name == "code" })?.value == "reused")
    await secondTimer.release()
    await secondTimer.waitForFinish()
    #expect(await secondTimer.cancelled)
    await presenter.cancel()
}
private enum PresenterOpenFailure: Error { case failed }

@Test("Browser-open failure is preserved after callback timeout", .timeLimit(.minutes(1)))
func macOSOAuthPresenterKeepsOpenErrorAfterTimeout() async throws {
    let timer = CallbackTimerGate()
    let presenter = McpMacOSSignInPresenter(callbackTimeoutSeconds: 600,
        openAuthorizationURL: { authorizationURL in
            let redirect = try #require(URLComponents(url: authorizationURL, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "redirect_uri" })?.value)
            await timer.release()
            await timer.waitForFinish()
            await waitForClosedCallbackListener(try #require(URL(string: redirect)))
            throw PresenterOpenFailure.failed
        }, callbackTimeoutSleep: { _ in
            await timer.sleep()
            await timer.finish(cancelled: Task.isCancelled)
        })
    let redirect = try await presenter.redirectURL(for: "open-error")
    await timer.waitForEntry()
    var authorization = URLComponents(string: "https://auth.example/authorize")!
    authorization.queryItems = [URLQueryItem(name: "redirect_uri", value: redirect.absoluteString)]
    await #expect(throws: PresenterOpenFailure.self) {
        _ = try await presenter.present(authorizationURL: authorization.url!, state: "open-error")
    }
    await presenter.cancel()
}
#endif
