import Foundation
import Testing
@testable import PiSwiftCodingAgent
import PiSwiftAI
import PiSwiftAgent

@Test func splitTurnSummariesAreSerialized() async throws {
    let state = LockedState((historyFinished: false, prefixStartedEarly: false, order: [String]()))

    let summary = try await serializeSplitTurnSummaries(
        history: {
            state.withLock { $0.order.append("history") }
            try await Task.sleep(nanoseconds: 10_000_000)
            state.withLock { $0.historyFinished = true }
            return "history"
        },
        turnPrefix: {
            state.withLock {
                $0.prefixStartedEarly = !$0.historyFinished
                $0.order.append("prefix")
            }
            return "prefix"
        }
    )

    #expect(state.withLock { !$0.prefixStartedEarly })
    #expect(state.withLock { $0.order } == ["history", "prefix"])
    #expect(summary == "history\n\n---\n\n**Turn Context (split turn):**\n\nprefix")
}

@Test(arguments: [0, -1, Double.nan])
func shellTimeoutRejectsNonPositiveAndNonFiniteValues(_ timeout: Double) async {
    do {
        _ = try await executeBash("echo should-not-run", options: BashExecutorOptions(timeoutSeconds: timeout))
        Issue.record("Expected invalid timeout to throw")
    } catch {
        #expect(error.localizedDescription == "Invalid timeout: must be a finite number of seconds")
    }
}

@Test func shellTimeoutRejectsOversizedValue() async {
    do {
        _ = try await execCommand("echo", ["should-not-run"], "/", ExecOptions(timeout: maximumShellTimeoutSeconds + 1))
        Issue.record("Expected oversized timeout to throw")
    } catch {
        #expect(error.localizedDescription == "Invalid timeout: maximum is \(maximumShellTimeoutSeconds) seconds")
    }
}

@Test func sessionHeaderMetadataAndEntryIdsRoundTrip() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("behavioral-fixes-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let manager = SessionManager.create(directory.path, directory.path)
    let file = try #require(manager.newSession(NewSessionOptions(
        id: "metadata-session",
        metadata: ["profile": AnyCodable("reviewer"), "attempt": AnyCodable(2)]
    )))
    for index in 0..<256 {
        _ = manager.appendMessage(.user(UserMessage(content: .text("message \(index)"))))
    }

    let ids = manager.getEntries().map(\.id)
    #expect(ids.count == 256)
    #expect(Set(ids).count == ids.count)
    #expect(ids.allSatisfy { $0.count == 8 })

    let reopened = SessionManager.open(file)
    let metadata = try #require(reopened.getHeader()?.metadata)
    #expect(metadata["profile"]?.value as? String == "reviewer")
    #expect(metadata["attempt"]?.value as? Int == 2)
}

@Test func sessionIngestionNormalizesNullAndMissingContent() {
    let content = """
    {"type":"session","version":3,"id":"session","timestamp":"2026-01-01T00:00:00Z","cwd":"/tmp"}
    {"type":"message","id":"assistant","parentId":null,"timestamp":"2026-01-01T00:00:01Z","message":{"role":"assistant","content":null,"api":"openai-responses","provider":"openai","model":"test","usage":{},"stopReason":"stop"}}
    {"type":"message","id":"tool","parentId":"assistant","timestamp":"2026-01-01T00:00:02Z","message":{"role":"toolResult","toolCallId":"call","toolName":"tool"}}
    """
    let entries = parseSessionEntries(content).compactMap { entry -> SessionEntry? in
        guard case .entry(let entry) = entry else { return nil }
        return entry
    }
    let context = buildSessionContext(entries)

    #expect(context.messages.count == 2)
    if case .assistant(let assistant) = context.messages[0] {
        #expect(assistant.content.isEmpty)
    } else {
        Issue.record("Expected assistant message")
    }
    if case .toolResult(let result) = context.messages[1] {
        #expect(result.content.isEmpty)
    } else {
        Issue.record("Expected tool-result message")
    }
}
