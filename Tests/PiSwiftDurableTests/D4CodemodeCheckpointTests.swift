import Foundation
import Testing
import PiSwiftChord
@testable import PiSwiftDurable

@Suite("PiSwiftDurableTests.D4CodemodeCheckpoint")
struct D4CodemodeCheckpointTests {
    // Upstream v1.4.0 codemode-checkpoints.test.ts:14–60.
    @Test func nativeCounterSequenceMatchesEveryUpstreamBatchAndSnapshot() async throws {
        let url = try #require(Bundle.module.url(forResource: "codemode-v140", withExtension: "json", subdirectory: "Fixtures"))
        let evidence = try #require(JSONValue(jsonData: Data(contentsOf: url))["checkpointEvidence"])
        let opened = try await openTestSession(now: { 1_700_000_000_000 })
        let session = opened.session, storage = opened.storage
        _ = try await session.commit({ tx in try await tx.createRootConversation() }, context: .background)
        let conversation = try await createConversation(session)
        #expect(try JSONValue(encoding: conversation) == evidence["conversationId"])
        var cutoff = try await session.commit({ tx in
            try await tx.doc(CodemodeStoreDoc, conversationId: conversation).child("values")!.set("counter", 0)
            return try await tx.appendEntry(conversation, value: .init(kind: "test.counter")).id
        }, context: .background)
        let address = DocumentAddress(kind: "pi.codemode.store", scope: .conversation(conversationId: conversation))
        let record = try #require(await storage.findDocument(address, at: .current, context: .background))
        #expect(try JSONValue(encoding: record.id) == evidence["documentId"])
        for counter in 1...64 {
            let entry = try await session.commit({ tx in
                try await tx.doc(CodemodeStoreDoc, conversationId: conversation).child("values")!.set("counter", .number(Double(counter)))
                return try await tx.appendEntry(conversation, value: .init(kind: "test.counter")).id
            }, context: .background)
            if counter == 32 { cutoff = entry }
        }
        #expect(try JSONValue(encoding: cutoff) == evidence["cutoffId"])
        #expect(try JSONValue(encoding: await storage.document(record.id, at: .current, context: .background)) == evidence["after64"])
        try await session.commit({ tx in
            try await tx.doc(CodemodeStoreDoc, conversationId: conversation).child("values")!.set("counter", 65)
        }, context: .background)
        #expect(try JSONValue(encoding: await storage.document(record.id, at: .current, context: .background)) == evidence["after65"])
        let base = try #require(await storage.commits.last)
        #expect(try JSONValue(encoding: base) == evidence["baseBatch"]?["writes"])
        #expect(try await session.snapshotAsOf(CodemodeStoreDoc, conversationId: conversation, at: cutoff, context: .background) == evidence["historical"]?.objectValue)
        let fork = try await session.commit({ tx in
            try await tx.forkConversation(conversation, at: cutoff, ownership: .ownerless())
        }, context: .background)
        #expect(try JSONValue(encoding: fork.id) == evidence["forkId"])
        #expect(try await session.snapshot(CodemodeStoreDoc, conversationId: fork.id, context: .background) == evidence["forkSnapshot"]?.objectValue)
        try await session.commit({ tx in
            try await tx.doc(CodemodeStoreDoc, conversationId: conversation).child("values")!.set("counter", 66)
        }, context: .background)
        #expect(try JSONValue(encoding: await storage.document(record.id, at: .current, context: .background)) == evidence["after66"])
        let batches = try #require(evidence["batches"]?.arrayValue)
        let commits = await storage.commits
        #expect(commits.count == batches.count)
        for (writes, batch) in zip(commits, batches) {
            #expect(try JSONValue(encoding: writes) == batch["writes"])
        }
        try await session.close(context: .background)
    }
}
