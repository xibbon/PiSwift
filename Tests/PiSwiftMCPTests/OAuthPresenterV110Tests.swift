import Foundation
import Testing
import PiSwiftAI
@testable import PiSwiftMCP

#if os(macOS)
private actor PresenterV110Gate {
    private var entered = false
    private var released = false
    private(set) var finished = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var finishWaiters: [CheckedContinuation<Void, Never>] = []
    private var blocked: CheckedContinuation<Void, Never>?
    private(set) var cancelled = false

    func block() async {
        signal()
        if !released { await withCheckedContinuation { blocked = $0 } }
    }

    func signal() {
        entered = true
        for waiter in entryWaiters { waiter.resume() }
        entryWaiters.removeAll()
    }

    func waitForEntry() async {
        if !entered { await withCheckedContinuation { entryWaiters.append($0) } }
    }

    func release() {
        released = true
        blocked?.resume()
        blocked = nil
    }

    func finish(cancelled: Bool) {
        self.cancelled = cancelled
        finished = true
        for waiter in finishWaiters { waiter.resume() }
        finishWaiters.removeAll()
    }

    func waitForFinish() async {
        if !finished { await withCheckedContinuation { finishWaiters.append($0) } }
    }
}

private actor PresenterV110Result {
    private(set) var value: Result<URL, any Error>?
    func record(_ value: Result<URL, any Error>) { self.value = value }
}

/// Use an unstructured observer so a failed bound does not wait for a blocked host closure.
private func cancelPresenterWithinTwoSeconds(
    _ task: Task<URL, any Error>, presenter: McpMacOSSignInPresenter,
    blockedHost: PresenterV110Gate? = nil
) async {
    let completion = PresenterV110Result()
    let observer = Task { await completion.record(await task.result) }
    let clock = ContinuousClock()
    let start = clock.now
    task.cancel()
    while await completion.value == nil, clock.now - start < .seconds(2) {
        try? await Task.sleep(for: .milliseconds(5))
    }
    let result = await completion.value
    #expect(result != nil, "Cancellation must finish within two seconds")
    if let result {
        switch result {
        case .success: Issue.record("A cancelled presentation returned a redirect")
        case .failure(let error): #expect(error is CancellationError)
        }
    } else {
        // Release test closures and close the listener after a failed assertion.
        await blockedHost?.release()
        await presenter.cancel()
    }
    await observer.value
}

private func requireClosedPresenterPort(_ redirect: URL) async throws {
    let session = URLSession(configuration: .ephemeral)
    defer { session.invalidateAndCancel() }
    var late = URLComponents(url: redirect, resolvingAgainstBaseURL: false)!
    late.queryItems = [URLQueryItem(name: "code", value: "late"), URLQueryItem(name: "state", value: "cancel")]
    do {
        _ = try await session.data(for: URLRequest(url: late.url!, timeoutInterval: 1))
        Issue.record("The callback listener accepted a late request after cancellation")
    } catch {}
    let port = try #require(redirect.port.flatMap { UInt16(exactly: $0) })
    let replacement = try await OAuthCallbackServer<String>.start(
        providerName: "MCP cancellation test", port: port, path: "/callback", state: "replacement",
        complete: { _ in "replacement" })
    #expect(URL(string: await replacement.redirectUri())?.port == Int(port))
    await replacement.close()
}

@Test("Caller cancellation stops the callback wait and frees its port", .timeLimit(.minutes(1)))
func macOSOAuthPresenterV110CancellationStopsCallback() async throws {
    let opened = PresenterV110Gate()
    let timer = PresenterV110Gate()
    let presenter = McpMacOSSignInPresenter(callbackTimeoutSeconds: 600,
        openAuthorizationURL: { _ in await opened.signal() }, callbackTimeoutSleep: { _ in
            await timer.block()
            await timer.finish(cancelled: Task.isCancelled)
        })
    let redirect = try await presenter.redirectURL(for: "cancel")
    await timer.waitForEntry()
    let task = Task {
        try await presenter.present(authorizationURL: URL(string: "https://auth.example/authorize")!, state: "cancel")
    }
    await opened.waitForEntry()
    await cancelPresenterWithinTwoSeconds(task, presenter: presenter)
    await timer.release()
    await timer.waitForFinish()
    #expect(await timer.cancelled)
    try await requireClosedPresenterPort(redirect)
}

@Test("Caller cancellation stops a paste closure that ignores cancellation", .timeLimit(.minutes(1)))
func macOSOAuthPresenterV110CancellationStopsPaste() async throws {
    let paste = PresenterV110Gate()
    let presenter = McpMacOSSignInPresenter(callbackTimeoutSeconds: 600, pasteRedirectURL: {
        await paste.block()
        await paste.finish(cancelled: Task.isCancelled)
        return "http://127.0.0.1/callback?code=late&state=cancel"
    }, openAuthorizationURL: { _ in })
    let redirect = try await presenter.redirectURL(for: "cancel")
    let task = Task {
        try await presenter.present(authorizationURL: URL(string: "https://auth.example/authorize")!, state: "cancel")
    }
    await paste.waitForEntry()
    await cancelPresenterWithinTwoSeconds(task, presenter: presenter, blockedHost: paste)
    // The late pasted result must not resume the presentation a second time.
    await paste.release()
    await paste.waitForFinish()
    #expect(await paste.cancelled)
    try await requireClosedPresenterPort(redirect)
}

@Test("Caller cancellation stops a browser closure that ignores cancellation", .timeLimit(.minutes(1)))
func macOSOAuthPresenterV110CancellationStopsBrowserOpen() async throws {
    let opening = PresenterV110Gate()
    let presenter = McpMacOSSignInPresenter(callbackTimeoutSeconds: 600, openAuthorizationURL: { _ in
        await opening.block()
        await opening.finish(cancelled: Task.isCancelled)
    })
    let redirect = try await presenter.redirectURL(for: "cancel")
    let task = Task {
        try await presenter.present(authorizationURL: URL(string: "https://auth.example/authorize")!, state: "cancel")
    }
    await opening.waitForEntry()
    await cancelPresenterWithinTwoSeconds(task, presenter: presenter, blockedHost: opening)
    await opening.release()
    await opening.waitForFinish()
    #expect(await opening.cancelled)
    try await requireClosedPresenterPort(redirect)
}

@Test("A cancelled caller does not open the browser", .timeLimit(.minutes(1)))
func macOSOAuthPresenterV110PrecancelledCaller() async throws {
    let entry = PresenterV110Gate()
    let opened = PresenterV110Gate()
    let presenter = McpMacOSSignInPresenter(openAuthorizationURL: { _ in
        await opened.finish(cancelled: false)
    })
    let redirect = try await presenter.redirectURL(for: "cancel")
    let task = Task {
        await entry.block()
        return try await presenter.present(authorizationURL: URL(string: "https://auth.example/authorize")!, state: "cancel")
    }
    await entry.waitForEntry()
    task.cancel()
    await entry.release()
    await cancelPresenterWithinTwoSeconds(task, presenter: presenter)
    try await requireClosedPresenterPort(redirect)
    #expect(await opened.finished == false)
}
#endif
