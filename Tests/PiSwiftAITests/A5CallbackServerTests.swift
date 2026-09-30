import Foundation
import Testing
@testable import PiSwiftAI

#if canImport(Network)

private func a5Request(_ uri: String, method: String = "GET") async throws -> (Int, String) {
    var request = URLRequest(url: URL(string: uri)!)
    request.httpMethod = method
    let (data, response) = try await URLSession.shared.data(for: request)
    return ((response as? HTTPURLResponse)?.statusCode ?? 0, String(decoding: data, as: UTF8.self))
}

private func a5Start(
    state: String? = "state", timeoutMs: Int? = nil,
    complete: @escaping @Sendable (URLComponents) async throws -> String = { components in
        "completed:\(components.queryItems?.first { $0.name == "code" }?.value ?? "")"
    }
) async throws -> OAuthCallbackServer<String> {
    try await OAuthCallbackServer.start(
        providerName: "Example", port: 0, path: "/callback", state: state,
        timeoutMs: timeoutMs, complete: complete
    )
}

@Suite("A5 shared OAuth callback server")
struct A5SharedCallbackServerTests {
    @Test func pathMethodStateAndMissingCodeKeepWaiting() async throws {
        let server = try await a5Start()
        defer { Task { await server.close() } }
        let uri = await server.redirectUri()
        #expect((try await a5Request(uri.replacingOccurrences(of: "/callback", with: "/other"))).0 == 404)
        #expect((try await a5Request(uri + "?state=wrong&code=x")).0 == 400)
        #expect((try await a5Request(uri + "?state=state&code=x", method: "POST")).0 == 404)
        #expect((try await a5Request(uri + "?state=state")).0 == 400)
        let (status, body) = try await a5Request(uri + "?state=state&code=good")
        #expect(status == 200)
        #expect(body.contains("Signed in to Example."))
        #expect(try await server.wait() == "completed:good")
    }

    @Test func redirectHostAndOptionalState() async throws {
        let server = try await OAuthCallbackServer<String>.start(
            providerName: "Example", port: 0, path: "/callback", redirectHost: "localhost"
        ) { components in components.queryItems?.first { $0.name == "code" }?.value ?? "" }
        defer { Task { await server.close() } }
        let uri = await server.redirectUri()
        #expect(uri.hasPrefix("http://localhost:"))
        #expect((try await a5Request(uri + "?code=no-state")).0 == 200)
        #expect(try await server.wait() == "no-state")
    }

    @Test func providerErrorUsesDescriptionAndFinishes() async throws {
        let server = try await a5Start()
        defer { Task { await server.close() } }
        let (status, body) = try await a5Request(await server.redirectUri() + "?state=state&error=access_denied&error_description=User%20denied%20access")
        #expect(status == 400)
        #expect(body.contains("User denied access"))
        do { _ = try await server.wait(); Issue.record("Expected provider error") }
        catch { #expect(error.localizedDescription == "Example authorization failed: User denied access") }
    }

    @Test func completionRunsBeforePageAndFailureReturns502() async throws {
        let server = try await a5Start { _ in throw OAuthCallbackFailure(message: "token exchange failed") }
        defer { Task { await server.close() } }
        let (status, body) = try await a5Request(await server.redirectUri() + "?state=state&code=bad")
        #expect(status == 502)
        #expect(body.contains("Example sign-in failed."))
        #expect(body.contains("token exchange failed"))
        do { _ = try await server.wait(); Issue.record("Expected exchange failure") }
        catch { #expect(error.localizedDescription == "token exchange failed") }
    }

    @Test func onlyFirstCallbackCompletes() async throws {
        let server = try await a5Start()
        defer { Task { await server.close() } }
        let uri = await server.redirectUri()
        #expect((try await a5Request(uri + "?state=state&code=first")).0 == 200)
        #expect((try await a5Request(uri + "?state=state&code=second")).0 == 409)
        #expect(try await server.wait() == "completed:first")
    }

    @Test func cancelAndTimeoutSettleWithoutPolling() async throws {
        let cancelled = try await a5Start()
        let uri = await cancelled.redirectUri()
        await cancelled.cancel()
        #expect(try await cancelled.wait() == nil)
        #expect((try await a5Request(uri + "?state=state&code=late")).0 == 409)
        await cancelled.close()

        let timedOut = try await a5Start(timeoutMs: 40)
        defer { Task { await timedOut.close() } }
        do { _ = try await timedOut.wait(); Issue.record("Expected timeout") }
        catch { #expect(error.localizedDescription == "Example sign-in timed out") }
    }

    @Test func abortAndCloseRejectWait() async throws {
        let signal = CancellationToken()
        let aborted = try await OAuthCallbackServer<String>.start(
            providerName: "Example", port: 0, path: "/callback", signal: signal
        ) { _ in "unused" }
        signal.cancel()
        do { _ = try await aborted.wait(); Issue.record("Expected cancellation") }
        catch { #expect(error.localizedDescription == "Login cancelled") }
        await aborted.close()

        let closed = try await a5Start()
        await closed.close()
        do { _ = try await closed.wait(); Issue.record("Expected close failure") }
        catch { #expect(error.localizedDescription == "OAuth callback server closed") }
    }

    @Test func callbackAndManualPromptRace() async throws {
        let callback = try await a5Start()
        defer { Task { await callback.close() } }
        let callbacks = OAuthLoginCallbacks(
            onAuth: { _ in },
            onPrompt: { _ in try await Task.sleep(for: .seconds(10)); return "manual" }
        )
        let wait = Task {
            try await waitForCallbackOrManualInput(
                callbacks: callbacks, callback: callback,
                prompt: OAuthPrompt(message: "Paste callback")
            )
        }
        #expect((try await a5Request(await callback.redirectUri() + "?state=state&code=browser")).0 == 200)
        switch try await wait.value {
        case .callback(let value): #expect(value == "completed:browser")
        case .manual: Issue.record("Expected browser callback")
        }

        let manual = try await a5Start()
        defer { Task { await manual.close() } }
        let manualCallbacks = OAuthLoginCallbacks(onAuth: { _ in }, onPrompt: { _ in "pasted" })
        let result = try await waitForCallbackOrManualInput(
            callbacks: manualCallbacks, callback: manual, prompt: OAuthPrompt(message: "Paste callback")
        )
        switch result {
        case .manual(let input): #expect(input == "pasted")
        case .callback: Issue.record("Expected pasted input")
        }
        #expect((try await a5Request(await manual.redirectUri() + "?state=state&code=late")).0 == 409)
    }

    @Test func manualPromptFailurePropagates() async throws {
        let server = try await a5Start()
        defer { Task { await server.close() } }
        let callbacks = OAuthLoginCallbacks(onAuth: { _ in }, onPrompt: { _ in
            throw OAuthCallbackFailure(message: "prompt cancelled")
        })
        do {
            _ = try await waitForCallbackOrManualInput(
                callbacks: callbacks, callback: server, prompt: OAuthPrompt(message: "Paste")
            )
            Issue.record("Expected prompt failure")
        } catch {
            #expect(error.localizedDescription == "prompt cancelled")
        }
        #expect((try await a5Request(await server.redirectUri() + "?state=state&code=late")).0 == 409)
    }
}

@Suite("A5 ChatGPT callback mode")
struct A5ChatGPTCallbackModeTests {
    @Test func invalidCallbackKeepsWaitingSuccessHasNo409() async throws {
        let server = try await OAuthCallbackServer<String>.start(
            providerName: "ChatGPT", port: 0, path: "/auth/callback", mode: .chatGPT
        ) { components in
            let value: (String) -> String? = { key in components.queryItems?.first { $0.name == key }?.value }
            guard value("code") != nil else { throw OAuthCallbackFailure(message: "Missing authorization code") }
            guard value("state") == "right" else { throw OAuthCallbackFailure(message: "OAuth state mismatch") }
            guard let clientId = value("client_id") else {
                throw OAuthCallbackFailure(message: "OpenAI OAuth registration callback did not contain an issued client ID")
            }
            return clientId
        }
        defer { Task { await server.close() } }
        let uri = await server.redirectUri()
        #expect((try await a5Request(uri.replacingOccurrences(of: "/auth/callback", with: "/other"))).0 == 404)
        let (badStatus, badPage) = try await a5Request(uri + "?code=x&state=wrong")
        #expect(badStatus == 400)
        #expect(badPage.contains("OAuth state mismatch"))
        #expect((try await a5Request(uri + "?code=x&state=right")).0 == 400)
        #expect((try await a5Request(uri + "?code=x&state=right&client_id=issued")).0 == 200)
        #expect(try await server.wait() == "issued")
        #expect((try await a5Request(uri + "?code=x&state=right&client_id=again")).0 == 200)
    }

    @Test func providerErrorReturns400AndFailsWithCode() async throws {
        let server = try await OAuthCallbackServer<String>.start(
            providerName: "ChatGPT", port: 0, path: "/auth/callback", mode: .chatGPT
        ) { _ in "unused" }
        defer { Task { await server.close() } }
        let (status, body) = try await a5Request(await server.redirectUri() + "?error=access_denied")
        #expect(status == 400)
        #expect(body.contains("ChatGPT was not connected."))
        do { _ = try await server.wait(); Issue.record("Expected provider error") }
        catch { #expect(error.localizedDescription == "ChatGPT authorization failed: access_denied") }
    }
}
#endif
