import Foundation
import Testing
@testable import PiSwiftAI

#if canImport(Network)
import Darwin
import Network

private func a5BoundSocket() -> (descriptor: Int32, port: UInt16)? {
    let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
    guard descriptor >= 0 else { return nil }
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    let bound = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    let read = withUnsafeMutablePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            getsockname(descriptor, $0, &length)
        }
    }
    guard bound == 0, read == 0 else {
        Darwin.close(descriptor)
        return nil
    }
    return (descriptor, UInt16(bigEndian: address.sin_port))
}

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

@Suite("A5 shared OAuth callback server", .timeLimit(.minutes(1)))
struct A5SharedCallbackServerTests {
    @Test func fixedFreePortCompletesCallback() async throws {
        let socket = try #require(a5BoundSocket())
        let port = socket.port
        Darwin.close(socket.descriptor)
        let server = try await OAuthCallbackServer<String>.start(
            providerName: "Example", port: port, path: "/callback", state: "state"
        ) { components in
            components.queryItems?.first { $0.name == "code" }?.value ?? ""
        }
        defer { Task { await server.close() } }
        let uri = await server.redirectUri()
        #expect(URL(string: uri)?.port == Int(port))
        #expect((try await a5Request(uri + "?state=state&code=fixed-port")).0 == 200)
        #expect(try await server.wait() == "fixed-port")
    }

    @Test func fixedOccupiedPortFailsToStart() async throws {
        let socket = try #require(a5BoundSocket())
        defer { Darwin.close(socket.descriptor) }
        #expect(Darwin.listen(socket.descriptor, 1) == 0)
        do {
            let server = try await OAuthCallbackServer<String>.start(
                providerName: "Example", port: socket.port, path: "/callback"
            ) { _ in "unused" }
            await server.close()
            Issue.record("Expected the occupied port to fail")
        } catch {
            #expect((error as? NWError) == .posix(.EADDRINUSE))
        }
    }

    @Test func cancelledWaitSettlesBeforeAndAfterRegistration() async throws {
        for cancelBeforeWait in [true, false] {
            let server = try await a5Start()
            let finished = LockedState(false)
            let task = Task {
                if cancelBeforeWait { withUnsafeCurrentTask { $0?.cancel() } }
                defer { finished.withLock { $0 = true } }
                return try await server.wait()
            }
            if !cancelBeforeWait {
                try await Task.sleep(for: .milliseconds(20))
                task.cancel()
            }
            for _ in 0..<100 {
                if finished.withLock({ $0 }) { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(finished.withLock { $0 })
            // Close after the assertion so a failed regression cannot retain the wait.
            await server.close()
            do { _ = try await task.value; Issue.record("Expected task cancellation") }
            catch { #expect(error is CancellationError) }
        }
    }

    @Test func cancelledTaskDoesNotStartListener() async throws {
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                let server = try await a5Start()
                await server.close()
                Issue.record("Expected task cancellation")
            } catch {
                #expect(error is CancellationError)
            }
        }
        await task.value
    }

    @Test func cancelledManualRaceSettlesBeforeAndAfterRegistration() async throws {
        for cancelBeforeWait in [true, false] {
            let server = try await a5Start()
            let promptStarted = AsyncStream<Void>.makeStream()
            let finished = LockedState(false)
            let callbacks = OAuthLoginCallbacks(onAuth: { _ in }, onPrompt: { _ in
                promptStarted.continuation.yield(())
                try await Task.sleep(for: .seconds(3600))
                return "unused"
            })
            let task = Task {
                if cancelBeforeWait { withUnsafeCurrentTask { $0?.cancel() } }
                defer { finished.withLock { $0 = true } }
                return try await waitForCallbackOrManualInput(
                    callbacks: callbacks, callback: server, prompt: OAuthPrompt(message: "Paste")
                )
            }
            if !cancelBeforeWait {
                for await _ in promptStarted.stream { break }
                task.cancel()
            }
            for _ in 0..<100 {
                if finished.withLock({ $0 }) { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(finished.withLock { $0 })
            await server.close()
            promptStarted.continuation.finish()
            do { _ = try await task.value; Issue.record("Expected task cancellation") }
            catch { #expect(error is CancellationError) }
        }
    }

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

@Suite("A5 ChatGPT callback mode", .timeLimit(.minutes(1)))
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
