import Testing
import PiSwiftAI
import PiSwiftChord
import PiSwiftDurableTesting
@testable import PiSwiftDurable

@Suite struct HarnessFacadeValueTests {
    @Test func usageSumsStoredDocumentsWithoutWritesOrScheduling() async throws {
        let storage = ControlledStorage(); let h = try await openHarness(storage: storage)
        let root = try await h.harness.root(context: .background)
        let child = try await h.harness.createConversation(options: .init(ownership: .ownerless()), context: .background)
        let token = try ConversationDocToken<UsageState>(kind: "pi.usage", version: 1, fork: .initial, initial: { UsageState() })
        let usage = Usage(input: 2, output: 3, cacheRead: 4, cacheWrite: 5, cacheWrite1h: 1, reasoning: 2, totalTokens: 14,
                          cost: UsageCost(input: 1, output: 2, cacheRead: 3, cacheWrite: 4, total: 10))
        let value = try JSONValue(encoding: UsageState(models: ["p/m": usage], tools: ["__proto__": usage]))
        try await h.harness.commit({ tx in
            for id in [root.id, child.id] {
                let draft = try await tx.doc(token, conversationId: id)
                try draft.set("models", value["models"]!); try draft.set("tools", value["tools"]!)
            }
        }, context: .background)
        let before = await storage.commits.count
        let total = try await h.harness.usage(context: .background)
        #expect(total.models["p/m"]?.input == 4); #expect(total.tools["__proto__"]?.cost.total == 20)
        #expect(total.models["p/m"]?.cacheWrite1h == 2); #expect(total.models["p/m"]?.reasoning == 4)
        #expect(await storage.commits.count == before)
        #expect(try await h.harness.inspect(context: .background).scheduling == .paused)
        try await h.harness.close(context: .background)
    }
    @Test func documentReaderUsesTokenPoliciesAndMigrationForFamilyReads() async throws {
        let storage = MemoryStorage(); let h = try await openHarness(storage: storage); let root = try await h.harness.root(context: .background)
        let old = try RewindableConversationDocFamilyToken<JSONObject, String>(kind: "h5.reader", version: 1, fork: .asOf, initial: { ["text": .string($0)] })
        let at = try await root.commit({ tx in
            _ = try await tx.doc(old, conversationId: root.id, key: "key", seed: "before")
            return try await tx.appendEntry(root.id, value: EntryDraft(kind: "point"))
        }, context: .background)
        try await root.commit({ tx in try await tx.doc(old, conversationId: root.id, key: "key", seed: "unused").set("text", "after") }, context: .background)
        let new = try RewindableConversationDocFamilyToken<JSONObject, String>(kind: "h5.reader", version: 2, fork: .asOf,
            initial: { ["text": .string($0)] }, migrate: { object, _ in var migrated = object; migrated["version"] = 2; return migrated })
        let read = documentReader(session: h.harness.session, storage: storage)
        #expect(try await read.snapshot(new, conversationId: root.id, key: "key", context: .background) == ["text": "after", "version": 2])
        #expect(try await read.snapshotAsOf(new, conversationId: root.id, key: "key", at: at.id, context: .background) == ["text": "before", "version": 2])
        try await h.harness.close(context: .background)
    }
}
