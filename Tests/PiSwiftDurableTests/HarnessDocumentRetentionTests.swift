import Testing
import PiSwiftChord
@testable import PiSwiftDurable
import PiSwiftDurableTesting

// Upstream v1.4.0 types.ts:78 requires an explicit checkpoint policy in each definition.

@Suite struct HarnessDocumentRetentionTests {
    // v1.4.0 uses Harness timers for eviction; SessionDocumentTimer.continuous was removed.
    @Test func documentRetentionUsesTheHarnessTimerClock() async throws {
        let clock = TestClock(now: 1_000)
        let setup = HarnessChatSetup(settings: .init(documentRetentionMs: 600_000), clock: clock)
        let harness = try await Harness.open(storage: MemoryStorage(), options: .init(
            models: setup.models, registry: setup.registry, settings: setup.settingsProvider,
            clock: clock), context: .background)
        let token = try SessionDocToken<JSONObject>(kind: "retention.harness.clock", version: 1,
            initial: { ["count": 0] }, checkpointWhen: { _, _, _ in false })
        try await harness.session.commit({ tx in
            try await tx.doc(token).set("count", 7)
        }, context: .background)
        try await harness.session.readOnLine {}
        #expect(harness.session.documentCacheSizes.cached == 1)
        try await eventually { clock.pendingDocumentRetentionCount == 1 }
        #expect(clock.pendingSleeperCount == 0)

        clock.advance(by: 600_000)
        try await eventually { harness.session.documentCacheSizes.cached == 0 }
        #expect(clock.pendingDocumentRetentionCount == 0)
        #expect(clock.pendingSleeperCount == 0)
        #expect(try await harness.session.snapshot(token, context: .background) == ["count": 7])
        try await harness.close(context: .background)
        #expect(clock.pendingSleeperCount == 0)
        #expect(clock.pendingDocumentRetentionCount == 0)
    }

    @Test func settingsResolveDocumentRetentionWithoutChangingContextRetention() {
        let defaults = resolveSettings()
        #expect(defaults.documentRetentionMs == Session.defaultDocumentRetentionMs)
        #expect(defaults.contextRetentionMs == 600000)
        for invalid in [Double.nan, -1, -Double.infinity] {
            let settings = resolveSettings(.init(contextRetentionMs: 17, documentRetentionMs: invalid))
            #expect(settings.documentRetentionMs == Session.defaultDocumentRetentionMs)
            #expect(settings.contextRetentionMs == 17)
        }
        for retention in [0, 12.5, Double.infinity] {
            let settings = resolveSettings(.init(contextRetentionMs: 23, documentRetentionMs: retention))
            #expect(settings.documentRetentionMs == retention)
            #expect(settings.contextRetentionMs == 23)
        }
    }

    // Upstream session-document-retention.test.ts: case 18.
    @Test func liveSettingsChangeAppliesAtNextDocumentUse() async throws {
        let setup = HarnessChatSetup(settings: .init(documentRetentionMs: 600000))
        let opened = try await openChat(setup: setup)
        _ = try await opened.harness.snapshot(LiveDoc, conversationId: opened.root.id, context: .background)
        #expect(opened.harness.session.documentCacheSizes.cached > 0)
        setup.updateSettings { $0.documentRetentionMs = 0 }
        _ = try await opened.harness.snapshot(LiveDoc, conversationId: opened.root.id, context: .background)
        try await eventually {
            try await opened.harness.session.readOnLine {}
            return opened.harness.session.documentCacheSizes.cached == 0
        }
        try await opened.harness.close(context: .background)
    }

    // Upstream session-document-retention.test.ts: case 19.
    @Test func immediateEvictionPreservesStreamedToolEvents() async throws {
        let evicted = try await streamedEvents(retention: 0)
        let retained = try await streamedEvents(retention: 600000)
        #expect(evicted == retained)
    }

    private func streamedEvents(retention: Double) async throws -> [JSONValue] {
        let setup = HarnessChatSetup(settings: .init(progress: .init(outputIntervalMs: 0), documentRetentionMs: retention))
        let releases = (0..<3).map { _ in HarnessChatSignal() }
        try installHarnessTool(harnessTestTool("steps", execute: { _, api, _ in
            for (index, step) in ["a\n", "b\n", "c\n"].enumerated() {
                try api.output(.text(step), nil)
                await releases[index].wait()
            }
            return .init(output: [])
        }), setup: setup)
        setup.models.setResponses([.message(try toolCalls([("steps", [:], "s1")])), .message(chatAssistant("done"))])
        let opened = try await openChat(setup: setup)
        let (stream, log) = try await eventListen(opened)
        let input = try await generationSubmit(opened)
        for index in releases.indices {
            try await log.waitForType("tool_execution_update", count: index + 1)
            releases[index].signal()
        }
        _ = try await input.wait(context: .background)
        try await opened.harness.waitForIdle(context: .background)
        try await log.waitForDone(input.id)
        _ = await stream.stop()
        try await opened.harness.close(context: .background)
        let events = log.events
        #expect(events.filter { $0["type"] == "tool_execution_update" }.count == 3)
        #expect(events.contains { $0["type"] == "message_end" && $0["entry"]?["model"]?[0]?["content"]?[0]?["text"] == "done" })
        return events.map { event in
            event["type"] == "tool_execution_update"
                ? ["type": event["type"]!, "output": event["output"] ?? .null]
                : event["type"] ?? .null
        }
    }
}
