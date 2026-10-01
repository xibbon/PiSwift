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

private actor FirstOAuthRedirect {
    private var result: Result<URL, any Error>?
    private var waiter: CheckedContinuation<URL, any Error>?
    private var timeoutRequested = false

    func requestTimeout() {
        timeoutRequested = true
    }

    func finishCallback(_ value: Result<URL, any Error>) {
        if case .failure(let error) = value,
           timeoutRequested,
           error.localizedDescription == "OAuth callback server closed" {
            finish(.failure(McpCallbackTimeoutError()))
        } else {
            finish(value)
        }
    }

    func finish(_ value: Result<URL, any Error>) {
        guard result == nil else { return }
        result = value
        waiter?.resume(with: value)
        waiter = nil
    }

    func wait() async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            if let result { continuation.resume(with: result) }
            else { waiter = continuation }
        }
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
    private var callbackTimeoutTask: Task<Void, Never>?
    private var callbackTask: Task<Void, Never>?
    private var callbackRace: FirstOAuthRedirect?
    private var callback: OAuthCallbackServer<String>?
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
        callbackTimeoutTask?.cancel()
        if let callback { await callback.close() }
        let server = try await OAuthCallbackServer<String>.start(
            providerName: "MCP", host: callbackHost, port: callbackPort,
            path: callbackPath, redirectHost: redirectHost, state: state,
            complete: { components in
                guard let url = components.url else { throw McpOAuthError.invalidRedirect }
                return url.absoluteString
            }
        )
        callback = server
        let race = FirstOAuthRedirect()
        callbackRace = race
        callbackTask = Task {
            do {
                guard let value = try await server.wait(), let url = URL(string: value) else {
                    throw McpOAuthError.invalidRedirect
                }
                await race.finishCallback(.success(url))
            } catch { await race.finishCallback(.failure(error)) }
        }
        let timeout = callbackTimeout
        let sleep = callbackTimeoutSleep
        callbackTimeoutTask = Task {
            do {
                try await timeout.wait(sleep: sleep)
                try Task.checkCancellation()
                await race.requestTimeout()
                await server.close()
            } catch {
                // Cancellation stops the timeout when sign-in finishes.
            }
        }
        guard let url = URL(string: await server.redirectUri()) else { throw McpOAuthError.invalidRedirect }
        return url
    }

    public func present(authorizationURL: URL, state: String) async throws -> URL {
        guard let callback, let race = callbackRace else { throw McpOAuthError.invalidRedirect }
        do {
            activeRace = race
            try await openAuthorizationURL(authorizationURL)
            let manualTask: Task<Void, Never>?
            if let pasteRedirectURL {
                manualTask = Task {
                    do {
                        guard let url = URL(string: try await pasteRedirectURL()) else {
                            throw McpOAuthError.invalidRedirect
                        }
                        await race.finish(.success(url))
                    } catch { await race.finish(.failure(error)) }
                }
            } else {
                manualTask = nil
            }
            let result: URL
            do {
                result = try await race.wait()
            } catch {
                callbackTask?.cancel()
                manualTask?.cancel()
                throw error
            }
            manualTask?.cancel()
            callbackTimeoutTask?.cancel()
            callbackTimeoutTask = nil
            callbackTask?.cancel()
            callbackTask = nil
            await callback.close()
            self.callback = nil
            callbackRace = nil
            activeRace = nil
            return result
        } catch {
            callbackTimeoutTask?.cancel()
            callbackTimeoutTask = nil
            callbackTask?.cancel()
            callbackTask = nil
            await callback.close()
            self.callback = nil
            callbackRace = nil
            activeRace = nil
            throw error
        }
    }

    /// Host UI may always submit a pasted redirect, even when no paste prompt closure was supplied.
    public func submitPastedRedirectURL(_ url: URL) async throws {
        guard let activeRace else { throw McpOAuthError.invalidRedirect }
        await activeRace.finish(.success(url))
    }

    public func cancel() async {
        callbackTimeoutTask?.cancel()
        callbackTimeoutTask = nil
        callbackTask?.cancel()
        callbackTask = nil
        if let callback { await callback.close() }
        callback = nil
        callbackRace = nil
        activeRace = nil
    }
}
#endif
