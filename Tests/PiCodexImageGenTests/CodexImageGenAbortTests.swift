import Foundation
import Testing
@testable import PiCodexImageGen
import PiSwiftAI
import PiSwiftAgent
import PiSwiftCodingAgent

/// A response body that sends one event, then stays open until cancelled.
private func hangingBody(terminated: LockedState<Bool>) -> AsyncThrowingStream<Data, Error> {
    AsyncThrowingStream { continuation in
        continuation.yield(sse([["type": "response.created", "response": ["id": "resp_1"]]]))
        continuation.onTermination = { _ in terminated.withLock { $0 = true } }
    }
}

private final class HangingClient: ProviderHTTPClient, Sendable {
    let terminated = LockedState(false)
    func send(_ request: URLRequest) async throws -> ProviderHTTPResponse {
        ProviderHTTPResponse(statusCode: 200, body: hangingBody(terminated: terminated))
    }
}

private func waitUntil(_ condition: @Sendable () -> Bool) async {
    for _ in 0..<200 where !condition() {
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
}

@Suite("PiCodexImageGen abort")
struct CodexImageGenAbortTests {
    @Test(.timeLimit(.minutes(1))) func abortStopsTheStreamReader() async throws {
        let terminated = LockedState(false)
        let signal = CancellationToken()
        let parse = Task {
            try await parseCodexSse(ProviderHTTPResponse(statusCode: 200, body: hangingBody(terminated: terminated)),
                                    secrets: [], signal: signal)
        }
        try await Task.sleep(nanoseconds: 50_000_000)
        signal.cancel()
        parse.cancel()
        await #expect(throws: (any Error).self) { _ = try await parse.value }
        await waitUntil { terminated.withLock { $0 } }
        #expect(terminated.withLock { $0 })
    }

    @Test(.timeLimit(.minutes(1))) func abortAfterDispatchWarnsAboutQuota() async throws {
        let client = HangingClient()
        let harness = Harness(replies: [])
        let api = HookAPI(events: createEventBus(), hookPath: "<test:abort>")
        let agentDir = harness.agentDir
        registerCodexImageGen(api, environment: CodexImageGenEnvironment(
            httpClient: client, admission: ImageAdmission(), agentDir: { agentDir }))
        for handler in api.handlers["session_start"] ?? [] {
            _ = try await handler(SessionStartEvent(), harness.hookContext(chatGPTModel))
        }
        let tool = try require_tool(api, CodexImageGen.inlineToolName)
        let signal = CancellationToken()
        let run = Task {
            try await tool.execute("call_1", ["prompt": AnyCodable("x"), "save": AnyCodable("none")], nil,
                                   harness.toolContext(chatGPTModel), signal)
        }
        try await Task.sleep(nanoseconds: 100_000_000)
        signal.cancel()
        do {
            _ = try await run.value
            Issue.record("expected failure")
        } catch {
            #expect(error.localizedDescription
                    == "Image generation was aborted after dispatch. Image quota may have been consumed. No automatic retry was made.")
        }
        await waitUntil { client.terminated.withLock { $0 } }
        #expect(client.terminated.withLock { $0 })
    }
}
