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
private actor FirstOAuthRedirect {
    private var result: Result<URL, any Error>?
    private var waiter: CheckedContinuation<URL, any Error>?

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
    private var callback: OAuthCallbackServer<String>?
    private var activeRace: FirstOAuthRedirect?

    public init(
        pasteRedirectURL: (@Sendable () async throws -> String)? = nil,
        openAuthorizationURL: @escaping @Sendable (URL) async throws -> Void = { url in
            let opened = await MainActor.run { NSWorkspace.shared.open(url) }
            if !opened { throw McpOAuthError.invalidRedirect }
        }
    ) {
        self.pasteRedirectURL = pasteRedirectURL
        self.openAuthorizationURL = openAuthorizationURL
    }

    public func redirectURL(for state: String) async throws -> URL {
        if let callback { await callback.close() }
        let server = try await OAuthCallbackServer<String>.start(
            providerName: "MCP", port: 0, path: "/callback", state: state,
            timeoutMs: 5 * 60_000,
            complete: { components in
                guard let url = components.url else { throw McpOAuthError.invalidRedirect }
                return url.absoluteString
            }
        )
        callback = server
        guard let url = URL(string: await server.redirectUri()) else { throw McpOAuthError.invalidRedirect }
        return url
    }

    public func present(authorizationURL: URL, state: String) async throws -> URL {
        guard let callback else { throw McpOAuthError.invalidRedirect }
        do {
            let race = FirstOAuthRedirect()
            activeRace = race
            try await openAuthorizationURL(authorizationURL)
            let callbackTask = Task {
                do {
                    guard let value = try await callback.wait(), let url = URL(string: value) else {
                        throw McpOAuthError.invalidRedirect
                    }
                    await race.finish(.success(url))
                } catch { await race.finish(.failure(error)) }
            }
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
            let result = try await race.wait()
            callbackTask.cancel()
            manualTask?.cancel()
            await callback.close()
            self.callback = nil
            activeRace = nil
            return result
        } catch {
            await callback.close()
            self.callback = nil
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
        if let callback { await callback.close() }
        callback = nil
        activeRace = nil
    }
}
#endif
