import Testing
import PiSwiftChord
@testable import PiSwiftDurable

struct DefinitionState: Codable, Sendable, Equatable {
    let value: Int
}

@Suite struct SessionDefinitionsTests {
    // session-definitions.test.ts:69. Fractional versions cannot enter an Int API.
    @Test func SessionDefinitionsValidateVersions() throws {
        for version in [0, -1, 9_007_199_254_740_992] {
            #expect(throws: DocumentDefinitionError.self) {
                try SessionDocToken<DefinitionState>(kind: "k", version: version, initial: { DefinitionState(value: 0) })
            }
        }
        let empty = try SessionDocToken<DefinitionState>(kind: "", version: 1, initial: { DefinitionState(value: 0) })
        let token = try SessionDocToken<DefinitionState>(kind: "t.session", version: 1, initial: { DefinitionState(value: 0) })
        #expect(empty.definition.kind == "")
        #expect(token.definition.kind == "t.session")
    }

    // session-definitions.test.ts:78. All reads are absent and do not create records.
    @Test func SessionDefinitionsSnapshotOverloads() async throws {
        let harness = try await openTestSession()
        let tokens = try DefinitionTokens()
        let conversation = try await createConversation(harness.session)
        let task = try TaskID(1)
        let a: DefinitionState? = try await harness.session.snapshot(tokens.session, context: .background)
        let b: DefinitionState? = try await harness.session.snapshot(tokens.latest, conversationId: conversation, context: .background)
        let c: DefinitionState? = try await harness.session.snapshot(tokens.rewindable, conversationId: conversation, context: .background)
        let d: DefinitionState? = try await harness.session.snapshot(tokens.task, taskId: task, context: .background)
        let e: DefinitionState? = try await harness.session.snapshot(tokens.sessionFamily, key: "k", context: .background)
        let f: DefinitionState? = try await harness.session.snapshot(tokens.latestFamily, conversationId: conversation, key: "k", context: .background)
        let g: DefinitionState? = try await harness.session.snapshot(tokens.rewindableFamily, conversationId: conversation, key: "k", context: .background)
        let h: DefinitionState? = try await harness.session.snapshot(tokens.taskFamily, taskId: task, key: "k", context: .background)
        #expect([a, b, c, d, e, f, g, h].allSatisfy { $0 == nil })
        try await harness.session.close(context: .background)
    }

    // session-definitions.test.ts:126 has no runtime operation; it defines a function.
    @Test func SessionDefinitionsTypedEntryToken() throws {
        let note = try EntryKind<DefinitionState>("t.note")
        #expect(note.kind == "t.note")
    }
}

struct DefinitionTokens: Sendable {
    let session = try! SessionDocToken<DefinitionState>(kind: "t.session", version: 1, initial: { DefinitionState(value: 0) })
    let latest = try! ConversationDocToken<DefinitionState>(kind: "t.latest", version: 1, fork: .current, initial: { DefinitionState(value: 0) })
    let rewindable = try! RewindableConversationDocToken<DefinitionState>(kind: "t.rewindable", version: 1, fork: .asOf, initial: { DefinitionState(value: 0) })
    let task = try! TaskDocToken<DefinitionState>(kind: "t.task", version: 1, initial: { DefinitionState(value: 0) })
    let sessionFamily = try! SessionDocFamilyToken<DefinitionState, Int>(kind: "t.session-family", version: 1, initial: { DefinitionState(value: $0) })
    let latestFamily = try! ConversationDocFamilyToken<DefinitionState, Int>(kind: "t.latest-family", version: 1, fork: .initial, initial: { DefinitionState(value: $0) })
    let rewindableFamily = try! RewindableConversationDocFamilyToken<DefinitionState, Int>(kind: "t.rewindable-family", version: 1, fork: .initial, initial: { DefinitionState(value: $0) })
    let taskFamily = try! TaskDocFamilyToken<DefinitionState, Int>(kind: "t.task-family", version: 1, initial: { DefinitionState(value: $0) })
    init() throws {}
}

