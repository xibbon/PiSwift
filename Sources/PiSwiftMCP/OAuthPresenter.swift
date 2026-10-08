import Foundation
import PiSwiftAI
#if os(macOS)
import AppKit
#endif

/// The host controls browser presentation on iOS. A presenter can also accept a pasted redirect URL.
public protocol McpSignInPresenter: Sendable {
    func redirectURL(for state: String) async throws -> URL
    func present(authorizationURL: URL, state: String) async throws -> URL
    func cancel() async
}

public extension McpSignInPresenter {
    func cancel() async {}
}

/// A host-supplied paste flow, useful on iOS and when a browser cannot return to the app.
public actor McpPasteRedirectPresenter: McpSignInPresenter {
    private let callbackURL: URL
    private let openAuthorizationURL: @Sendable (URL) async throws -> Void
    private let pasteRedirectURL: @Sendable () async throws -> String

    public init(callbackURL: URL,
                openAuthorizationURL: @escaping @Sendable (URL) async throws -> Void,
                pasteRedirectURL: @escaping @Sendable () async throws -> String) {
        self.callbackURL = callbackURL
        self.openAuthorizationURL = openAuthorizationURL
        self.pasteRedirectURL = pasteRedirectURL
    }

    public func redirectURL(for state: String) -> URL { callbackURL }

    public func present(authorizationURL: URL, state: String) async throws -> URL {
        try await openAuthorizationURL(authorizationURL)
        guard let url = URL(string: try await pasteRedirectURL()) else { throw McpOAuthError.invalidRedirect }
        return url
    }
}

#if os(macOS)
/// Use bounded sleep steps to avoid an integer conversion limit for long timeouts.
struct McpCallbackTimeout: Sendable {
    let seconds: TimeInterval

    func validate() throws {
        guard seconds.isFinite, seconds > 0 else {
            throw McpOAuthError.invalidMetadata("callbackTimeoutSeconds")
        }
    }

    func wait(
        sleep: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) async throws {
        try validate()
        var pending = [seconds]
        while let interval = pending.popLast() {
            try Task.checkCancellation()
            if interval > 86_400 {
                // Split large values before subtraction. Both parts have the same
                // scale, so a large Double cannot discard a short sleep step.
                let half = interval / 2
                pending.append(interval - half)
                pending.append(half)
            } else {
                try await sleep(.seconds(interval))
            }
        }
        try Task.checkCancellation()
    }
}

private struct McpCallbackTimeoutError: Error, LocalizedError, Sendable {
    var errorDescription: String? { "MCP sign-in timed out" }
}

private struct McpCallbackClosedError: Error, LocalizedError, Sendable {
    var errorDescription: String? { "OAuth callback server closed" }
}

private actor FirstOAuthRedirect {
    private let callback: OAuthCallbackServer<String>
    private var result: Result<URL, any Error>?
    private var waiter: CheckedContinuation<URL, any Error>?
    private var openingResult: Result<Void, any Error>?
    private var openingWaiter: CheckedContinuation<Void, any Error>?
    private var timeoutRequested = false
    private var stopped = false
    private var stopError: (any Error)?
    private var cleanupFinished = false
    private var cleanupWaiters: [CheckedContinuation<Void, Never>] = []
    private var callbackTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?
    private var openingTask: Task<Void, Never>?
    private var manualTask: Task<Void, Never>?

    init(callback: OAuthCallbackServer<String>) {
        self.callback = callback
    }

    func start(timeout: McpCallbackTimeout, sleep: @escaping @Sendable (Duration) async throws -> Void) {
        guard !stopped else { return }
        callbackTask = Task {
            do {
                guard let value = try await callback.wait(), let url = URL(string: value) else {
                    throw McpOAuthError.invalidRedirect
                }
                finishCallback(.success(url))
            } catch { finishCallback(.failure(error)) }
        }
        timeoutTask = Task {
            do {
                try await timeout.wait(sleep: sleep)
                try Task.checkCancellation()
                guard !stopped else { return }
                timeoutRequested = true
                await callback.close()
            } catch {
                // Cancellation stops the timer when sign-in finishes.
            }
        }
    }

    func open(_ url: URL, using open: @escaping @Sendable (URL) async throws -> Void) async throws {
        if !stopped {
            openingTask = Task {
                do {
                    try await open(url)
                    finishOpening(.success(()))
                } catch { finishOpening(.failure(error)) }
            }
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            if cleanupFinished, let stopError { continuation.resume(throwing: stopError) }
            else if !stopped, let openingResult { continuation.resume(with: openingResult) }
            else { openingWaiter = continuation }
        }
    }

    func startManual(_ paste: @escaping @Sendable () async throws -> String) {
        guard !stopped else { return }
        manualTask = Task {
            do {
                guard let url = URL(string: try await paste()) else {
                    throw McpOAuthError.invalidRedirect
                }
                finish(.success(url))
            } catch { finish(.failure(error)) }
        }
    }

    private func finishOpening(_ value: Result<Void, any Error>) {
        guard !stopped, openingResult == nil else { return }
        openingResult = value
        openingWaiter?.resume(with: value)
        openingWaiter = nil
    }

    private func finishCallback(_ value: Result<URL, any Error>) {
        if case .failure(let error) = value,
           timeoutRequested,
           error.localizedDescription == "OAuth callback server closed" {
            finish(.failure(McpCallbackTimeoutError()))
        } else {
            finish(value)
        }
    }

    func finish(_ value: Result<URL, any Error>) {
        guard !stopped, result == nil else { return }
        result = value
        waiter?.resume(with: value)
        waiter = nil
    }

    func wait() async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            if cleanupFinished, let stopError { continuation.resume(throwing: stopError) }
            else if !stopped, let result { continuation.resume(with: result) }
            else { waiter = continuation }
        }
    }

    /// Close the listener before resuming a cancelled presentation. Host closures
    /// can ignore task cancellation, so do not wait for those tasks to finish.
    func stop(with error: (any Error)? = nil) async {
        if stopped {
            if !cleanupFinished {
                await withCheckedContinuation { cleanupWaiters.append($0) }
            }
            return
        }
        stopped = true
        stopError = error
        callbackTask?.cancel()
        timeoutTask?.cancel()
        openingTask?.cancel()
        manualTask?.cancel()
        callbackTask = nil
        timeoutTask = nil
        openingTask = nil
        manualTask = nil
        await callback.close()
        cleanupFinished = true
        if let error {
            openingWaiter?.resume(throwing: error)
            waiter?.resume(throwing: error)
        }
        openingWaiter = nil
        waiter = nil
        for continuation in cleanupWaiters { continuation.resume() }
        cleanupWaiters.removeAll()
    }
}

/// macOS loopback sign-in using the shared PiSwiftAI callback server.
public actor McpMacOSSignInPresenter: McpSignInPresenter {
    private let pasteRedirectURL: (@Sendable () async throws -> String)?
    private let openAuthorizationURL: @Sendable (URL) async throws -> Void
    private let callbackHost: String
    private let callbackPort: UInt16
    private let callbackPath: String
    private let redirectHost: String?
    let callbackTimeout: McpCallbackTimeout
    private let callbackTimeoutSleep: @Sendable (Duration) async throws -> Void
    private var callbackRace: FirstOAuthRedirect?
    private var activeRace: FirstOAuthRedirect?

    /// The callback timeout is in seconds. It must be finite and greater than zero.
    /// `redirectURL(for:)` rejects an invalid timeout before it starts the server.
    public init(
        callbackHost: String = "127.0.0.1", callbackPort: UInt16 = 0,
        callbackPath: String = "/callback", redirectHost: String? = nil,
        callbackTimeoutSeconds: TimeInterval = 300,
        pasteRedirectURL: (@Sendable () async throws -> String)? = nil,
        openAuthorizationURL: @escaping @Sendable (URL) async throws -> Void = { url in
            let opened = await MainActor.run { NSWorkspace.shared.open(url) }
            if !opened { throw McpOAuthError.invalidRedirect }
        }
    ) {
        self.init(callbackHost: callbackHost, callbackPort: callbackPort,
            callbackPath: callbackPath, redirectHost: redirectHost,
            callbackTimeoutSeconds: callbackTimeoutSeconds,
            pasteRedirectURL: pasteRedirectURL, openAuthorizationURL: openAuthorizationURL,
            callbackTimeoutSleep: { try await Task.sleep(for: $0) })
    }

    init(
        callbackHost: String = "127.0.0.1", callbackPort: UInt16 = 0,
        callbackPath: String = "/callback", redirectHost: String? = nil,
        callbackTimeoutSeconds: TimeInterval = 300,
        pasteRedirectURL: (@Sendable () async throws -> String)? = nil,
        openAuthorizationURL: @escaping @Sendable (URL) async throws -> Void,
        callbackTimeoutSleep: @escaping @Sendable (Duration) async throws -> Void
    ) {
        self.callbackHost = callbackHost
        self.callbackPort = callbackPort
        self.callbackPath = callbackPath
        self.redirectHost = redirectHost
        self.callbackTimeout = McpCallbackTimeout(seconds: callbackTimeoutSeconds)
        self.callbackTimeoutSleep = callbackTimeoutSleep
        self.pasteRedirectURL = pasteRedirectURL
        self.openAuthorizationURL = openAuthorizationURL
    }

    public func redirectURL(for state: String) async throws -> URL {
        try callbackTimeout.validate()
        let previousRace = callbackRace
        callbackRace = nil
        activeRace = nil
        await previousRace?.stop(with: McpCallbackClosedError())
        let server = try await OAuthCallbackServer<String>.start(
            providerName: "MCP", host: callbackHost, port: callbackPort,
            path: callbackPath, redirectHost: redirectHost, state: state,
            complete: { components in
                guard let url = components.url else { throw McpOAuthError.invalidRedirect }
                return url.absoluteString
            }
        )
        let race = FirstOAuthRedirect(callback: server)
        callbackRace = race
        await race.start(timeout: callbackTimeout, sleep: callbackTimeoutSleep)
        guard let url = URL(string: await server.redirectUri()) else { throw McpOAuthError.invalidRedirect }
        return url
    }

    public func present(authorizationURL: URL, state: String) async throws -> URL {
        guard let race = callbackRace else { throw McpOAuthError.invalidRedirect }
        return try await withTaskCancellationHandler {
            do {
                try Task.checkCancellation()
                activeRace = race
                try await race.open(authorizationURL, using: openAuthorizationURL)
                try Task.checkCancellation()
                if let pasteRedirectURL { await race.startManual(pasteRedirectURL) }
                let result = try await race.wait()
                try Task.checkCancellation()
                clear(race)
                await race.stop()
                try Task.checkCancellation()
                return result
            } catch {
                clear(race)
                await race.stop(with: error)
                if Task.isCancelled { throw CancellationError() }
                throw error
            }
        } onCancel: {
            Task { await race.stop(with: CancellationError()) }
        }
    }

    private func clear(_ race: FirstOAuthRedirect) {
        // A previous presentation must not clear a new sign-in session.
        if callbackRace === race { callbackRace = nil }
        if activeRace === race { activeRace = nil }
    }

    /// Host UI may always submit a pasted redirect, even when no paste prompt closure was supplied.
    public func submitPastedRedirectURL(_ url: URL) async throws {
        guard let activeRace else { throw McpOAuthError.invalidRedirect }
        await activeRace.finish(.success(url))
    }

    public func cancel() async {
        guard let race = callbackRace else { return }
        clear(race)
        await race.stop(with: McpCallbackClosedError())
    }
}
#endif
