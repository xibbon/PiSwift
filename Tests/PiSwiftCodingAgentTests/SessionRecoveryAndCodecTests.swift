import Foundation
import Testing
import PiSwiftAI
import PiSwiftAgent
@testable import PiSwiftCodingAgent

// MARK: - C1: content-block codec round-trip fidelity
//
// The session JSONL is the source of truth for resuming a conversation. Two ContentBlock
// fields are load-bearing for reasoning models and must survive the persistence round-trip:
//   - ThinkingContent.redacted  — marks a redacted_thinking block whose signature is an opaque
//     encrypted payload. Losing the flag makes the outbound Anthropic path emit an invalid
//     `thinking` block, so the resumed conversation is rejected.
//   - TextContent.textSignature — carries OpenAI Responses reasoning-item ids / Gemini thought
//     signatures. Losing it breaks reasoning continuity on resume.

/// Simulate the disk round-trip: encode → JSON bytes → JSON object → decode.
private func roundTripThroughJson(_ block: ContentBlock) throws -> ContentBlock? {
    let dict = contentBlockToDict(block)
    let data = try JSONSerialization.data(withJSONObject: dict)
    let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    return parsed.flatMap { contentBlockFromDict($0) }
}

@Test func redactedThinkingSurvivesCodecRoundTrip() throws {
    let original = ContentBlock.thinking(ThinkingContent(
        thinking: "[Reasoning redacted]",
        thinkingSignature: "b3BhcXVlLXJlZGFjdGVkLXBheWxvYWQ=",
        redacted: true
    ))

    let restored = try roundTripThroughJson(original)
    guard case .thinking(let thinking)? = restored else {
        Issue.record("expected a thinking block, got \(String(describing: restored))")
        return
    }
    #expect(thinking.redacted == true)
    #expect(thinking.thinkingSignature == "b3BhcXVlLXJlZGFjdGVkLXBheWxvYWQ=")
    #expect(thinking.thinking == "[Reasoning redacted]")
}

@Test func normalThinkingRoundTripDoesNotInventRedactedFlag() throws {
    let original = ContentBlock.thinking(ThinkingContent(
        thinking: "step by step",
        thinkingSignature: "valid-signature"
    ))

    let restored = try roundTripThroughJson(original)
    guard case .thinking(let thinking)? = restored else {
        Issue.record("expected a thinking block")
        return
    }
    #expect(thinking.redacted == nil)
    #expect(thinking.thinkingSignature == "valid-signature")
}

@Test func textSignatureSurvivesCodecRoundTrip() throws {
    let original = ContentBlock.text(TextContent(text: "answer", textSignature: "reasoning-item-42"))

    let restored = try roundTripThroughJson(original)
    guard case .text(let text)? = restored else {
        Issue.record("expected a text block")
        return
    }
    #expect(text.text == "answer")
    #expect(text.textSignature == "reasoning-item-42")
}

@Test func assistantReasoningBlocksSurviveSessionPersistence() throws {
    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("session-codec-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let sm = SessionManager.create("/tmp", tempDir.path)
    let assistant = AssistantMessage(
        content: [
            .thinking(ThinkingContent(thinking: "[Reasoning redacted]", thinkingSignature: "opaque==", redacted: true)),
            .text(TextContent(text: "done", textSignature: "sig-123")),
        ],
        api: .anthropicMessages,
        provider: "anthropic",
        model: "claude-opus",
        usage: Usage(input: 1, output: 1, cacheRead: 0, cacheWrite: 0, totalTokens: 2),
        stopReason: .stop
    )
    // An assistant message flushes the deferred session file to disk.
    sm.appendMessage(.assistant(assistant))

    let file = try #require(sm.getSessionFile())

    // Reload straight from disk (fresh parse, not the in-memory copy).
    let entries = loadEntriesFromFile(file)
    let message = entries.compactMap { entry -> AssistantMessage? in
        if case .entry(.message(let msg)) = entry, case .assistant(let a) = msg.message { return a }
        return nil
    }.first
    let reloaded = try #require(message)

    let thinking = reloaded.content.compactMap { block -> ThinkingContent? in
        if case .thinking(let t) = block { return t }
        return nil
    }.first
    #expect(thinking?.redacted == true)
    #expect(thinking?.thinkingSignature == "opaque==")

    let text = reloaded.content.compactMap { block -> TextContent? in
        if case .text(let t) = block { return t }
        return nil
    }.first
    #expect(text?.textSignature == "sig-123")
}

// MARK: - C2: corrupt-header recovery must not destroy history

@Test func openWithCorruptHeaderPreservesOriginalInsteadOfTruncating() throws {
    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("session-recover-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    // A file whose header line is garbled but that still holds intact message entries below.
    let file = tempDir.appendingPathComponent("2025-01-01_broken.jsonl")
    let corruptContent = """
    {"type":"session","id":"abc"  <-- TORN HEADER LINE
    {"type":"message","id":"m1","parentId":null,"timestamp":"2025-01-01T00:00:00Z","message":{"role":"user","content":"important history","timestamp":123}}
    """
    try corruptContent.write(to: file, atomically: true, encoding: .utf8)

    // parseSessionEntries yields nothing (first decodable line isn't a session header),
    // so open() takes the recovery path.
    #expect(loadEntriesFromFile(file.path).isEmpty)

    _ = SessionManager.open(file.path)

    // The original content must be preserved in a sibling `.corrupt-*` file, never truncated.
    let siblings = try FileManager.default.contentsOfDirectory(atPath: tempDir.path)
    let backup = siblings.first { $0.hasPrefix("2025-01-01_broken.jsonl.corrupt-") }
    let backupName = try #require(backup, "expected a .corrupt-* backup of the original file")

    let backupContent = try String(contentsOfFile: tempDir.appendingPathComponent(backupName).path, encoding: .utf8)
    #expect(backupContent.contains("important history"))

    // And the original path is now a fresh, valid session (recovered, not destroyed-in-place).
    #expect(isValidSessionFile(file.path))
}
