import Foundation
import Testing
@testable import PiCodexImageGen
import PiSwiftAI
import PiSwiftAgent
import PiSwiftCodingAgent

/// A response body that sends two events, then stays open until cancelled.
/// The second event makes a progress report, so a test knows the parser runs.
private func hangingBody(terminated: LockedState<Bool>) -> AsyncThrowingStream<Data, Error> {
    AsyncThrowingStream { continuation in
        continuation.yield(sse([
            ["type": "response.created", "response": ["id": "resp_1"]],
            ["type": "response.image_generation_call.in_progress"],
        ]))
        continuation.onTermination = { _ in terminated.withLock { $0 = true } }
    }
}

private final class HangingClient: ProviderHTTPClient, Sendable {
    let terminated = LockedState(false)
    func send(_ request: URLRequest) async throws -> ProviderHTTPResponse {
        ProviderHTTPResponse(statusCode: 200, body: hangingBody(terminated: terminated))
    }
}

@Suite("PiCodexImageGen abort", .timeLimit(.minutes(1)))
struct CodexImageGenAbortTests {
    @Test func abortStopsTheStreamReader() async throws {
        let terminated = LockedState(false)
        let signal = CancellationToken()
        let started = LockedState(false)
        let parse = Task {
            try await parseCodexSse(ProviderHTTPResponse(statusCode: 200, body: hangingBody(terminated: terminated)),
                                    secrets: [], signal: signal) { _ in started.withLock { $0 = true } }
        }
        #expect(await waitUntil { started.withLock { $0 } })
        signal.cancel()
        parse.cancel()
        await #expect(throws: (any Error).self) { _ = try await parse.value }
        #expect(await waitUntil { terminated.withLock { $0 } })
    }

    @Test func abortAfterDispatchWarnsAboutQuota() async throws {
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
        let stages = LockedState<[String]>([])
        let onUpdate: AgentToolUpdateCallback = { result in
            if case .text(let text)? = result.content.first { stages.withLock { $0.append(text.text) } }
        }
        let run = Task {
            try await tool.execute("call_1", ["prompt": AnyCodable("x"), "save": AnyCodable("none")], onUpdate,
                                   harness.toolContext(chatGPTModel), signal)
        }
        #expect(await waitUntil { stages.withLock { $0.contains("Codex image stage: in_progress.") } })
        signal.cancel()
        do {
            _ = try await run.value
            Issue.record("expected failure")
        } catch {
            #expect(error.localizedDescription
                    == "Image generation was aborted after dispatch. Image quota may have been consumed. No automatic retry was made.")
        }
        #expect(await waitUntil { client.terminated.withLock { $0 } })
    }
}
