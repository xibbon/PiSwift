import PiSwiftChord
import Synchronization
import Testing
@testable import PiSwiftDurable

private struct CountedSnapshot: Codable, Sendable, Equatable {
    static let decodes = Mutex(0)
    let count: Int
    init(count: Int) { self.count = count }
    init(from decoder: any Decoder) throws {
        Self.decodes.withLock { $0 += 1 }
        let values = try decoder.container(keyedBy: CodingKeys.self)
        count = try values.decode(Int.self, forKey: .count)
    }
}

@Suite struct SessionSnapshotTests {
    @Test func decodesOnceForEachRevisionAndDefinitionVersion() async throws {
        let harness = try await openTestSession()
        let token = try SessionDocToken<CountedSnapshot>(kind: "decode", version: 1, initial: { CountedSnapshot(count: 0) })
        try await harness.session.commit({ tx in _ = try await tx.doc(token) }, context: .background)
        CountedSnapshot.decodes.withLock { $0 = 0 }
        let a = try await harness.session.snapshot(token, context: .background)
        let b = try await harness.session.snapshot(token, context: .background)
        #expect(a == b)
        #expect(CountedSnapshot.decodes.withLock { $0 } == 1)
        try await harness.session.commit({ tx in try await tx.doc(token).set("count", 1) }, context: .background)
        let c = try await harness.session.snapshot(token, context: .background)
        _ = try await harness.session.snapshot(token, context: .background)
        #expect(c?.count == 1)
        #expect(a?.count == 0)
        #expect(CountedSnapshot.decodes.withLock { $0 } == 2)
        let newer = try SessionDocToken<CountedSnapshot>(kind: "decode", version: 2, initial: { CountedSnapshot(count: 0) }, migrate: { value, _ in value })
        _ = try await harness.session.snapshot(newer, context: .background)
        _ = try await harness.session.snapshot(newer, context: .background)
        #expect(CountedSnapshot.decodes.withLock { $0 } == 3)
        try await harness.session.close(context: .background)
    }

    @Test func familyAddressesUseExactStringUnits() async throws {
        let harness = try await openTestSession()
        let token = try SessionDocFamilyToken<JSONObject, Int>(kind: "unicode", version: 1, initial: { ["seed": .number(Double($0))] })
        try await harness.session.commit({ tx in
            _ = try await tx.doc(token, key: "é", seed: 1)
            _ = try await tx.doc(token, key: "e\u{301}", seed: 2)
        }, context: .background)
        #expect(try await harness.session.snapshot(token, key: "é", context: .background) == ["seed": 1])
        #expect(try await harness.session.snapshot(token, key: "e\u{301}", context: .background) == ["seed": 2])
        try await harness.session.unloadDocuments()
        #expect(try await harness.session.snapshot(token, key: "é", context: .background) == ["seed": 1])
        #expect(try await harness.session.snapshot(token, key: "e\u{301}", context: .background) == ["seed": 2])
        try await harness.session.close(context: .background)
    }

    @Test func createsEditsAndRetiresAllScopeTokens() async throws {
        let harness = try await openTestSession()
        let tokens = try DefinitionTokens()
        let conversation = try await createConversation(harness.session)
        let kind = TaskKind<JSONObject, JSONObject>(name: "scopes", version: 1, initial: { $0 })
        let task = try await harness.session.commit({ tx in
            try await tx.createTask(kind, input: [:], options: TaskOptions(ownership: .conversation(), conversationId: conversation))
        }, context: .background)
        try await harness.session.commit({ tx in
            let drafts = [
                try await tx.doc(tokens.session),
                try await tx.doc(tokens.latest, conversationId: conversation),
                try await tx.doc(tokens.rewindable, conversationId: conversation),
                try await tx.doc(tokens.task, taskId: task),
                try await tx.doc(tokens.sessionFamily, key: "k", seed: 1),
                try await tx.doc(tokens.latestFamily, conversationId: conversation, key: "k", seed: 1),
                try await tx.doc(tokens.rewindableFamily, conversationId: conversation, key: "k", seed: 1),
                try await tx.doc(tokens.taskFamily, taskId: task, key: "k", seed: 1)
            ]
            for draft in drafts { try draft.set("value", 9) }
        }, context: .background)
        let snapshots = [
            try await harness.session.snapshot(tokens.session, context: .background),
            try await harness.session.snapshot(tokens.latest, conversationId: conversation, context: .background),
            try await harness.session.snapshot(tokens.rewindable, conversationId: conversation, context: .background),
            try await harness.session.snapshot(tokens.task, taskId: task, context: .background),
            try await harness.session.snapshot(tokens.sessionFamily, key: "k", context: .background),
            try await harness.session.snapshot(tokens.latestFamily, conversationId: conversation, key: "k", context: .background),
            try await harness.session.snapshot(tokens.rewindableFamily, conversationId: conversation, key: "k", context: .background),
            try await harness.session.snapshot(tokens.taskFamily, taskId: task, key: "k", context: .background)
        ]
        #expect(snapshots.allSatisfy { $0?.value == 9 })
        try await harness.session.commit({ tx in
            try await tx.retireDoc(tokens.session)
            try await tx.retireDoc(tokens.latest, conversationId: conversation)
            try await tx.retireDoc(tokens.rewindable, conversationId: conversation)
            try await tx.retireDoc(tokens.task, taskId: task)
            try await tx.retireDoc(tokens.sessionFamily, key: "k")
            try await tx.retireDoc(tokens.latestFamily, conversationId: conversation, key: "k")
            try await tx.retireDoc(tokens.rewindableFamily, conversationId: conversation, key: "k")
            try await tx.retireDoc(tokens.taskFamily, taskId: task, key: "k")
        }, context: .background)
        #expect(documentChanges(try #require(harness.publications.values.last)).count == 8)
        #expect(try await harness.session.snapshot(tokens.session, context: .background) == nil)
        #expect(try await harness.session.snapshot(tokens.taskFamily, taskId: task, key: "k", context: .background) == nil)
        try await harness.session.close(context: .background)
    }
}
