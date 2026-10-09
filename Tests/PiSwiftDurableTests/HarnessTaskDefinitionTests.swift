import Testing
import PiSwiftChord
@testable import PiSwiftDurable

private struct DefinitionCheckpoint: TaskCheckpoint, Equatable {
    enum Phase: String, Codable, Sendable { case work, joined }
    var phase: Phase
    var count: Int
}
private struct DefinitionHooks: Sendable {
    var value: Int
}
private func definitionTask(_ name: String = "test.definition", version: Double = 1) -> TaskDefinition<Int, DefinitionCheckpoint, Int, DefinitionHooks> {
    TaskDefinition(name: name, version: version, initial: { DefinitionCheckpoint(phase: .work, count: $0) },
                   phase: { _, _, _ in }, abort: { _, _, _ in },
                   migrate: { input, checkpoint, _ in
        (try input.decode(Int.self), try checkpoint.decode(DefinitionCheckpoint.self))
    })
}
private struct DefinitionAgentHooks: SessionHooks {
    func conversationCreated(_ tx: Transaction, record: ConversationRecord) async throws {
        try await createAgent(tx: tx, conversation: record)
    }
}

@Suite struct HarnessTaskDefinitionTests {
    @Test func typedCheckpointKeepsUpstreamJSONShape() throws {
        let definition = definitionTask()
        let erased = AnyTaskDefinition(defineTask(definition))
        #expect(erased.identity == AnyTaskDefinition(definition).identity)
        let value = try erased.initial(.number(3))
        #expect(value == .object(["phase": .string("work"), "count": .number(3)]))
        let migrate = try #require(erased.migrate)
        let migrated = try migrate(.number(4), value, 0)
        #expect(migrated.input == .number(4))
        #expect(migrated.checkpoint == value)
        #expect(try definition.completed(7) == .terminal(outcome: .completed(result: .number(7))))
        let registered = hook(definition, handlers: DefinitionHooks(value: 9))
        #expect(registered.task == definition.name)
        #expect(registered.handlers(as: DefinitionHooks.self)?.value == 9)
    }

    @Test func invalidCheckpointEncodingIsRejected() throws {
        struct Invalid: TaskCheckpoint {
            enum Phase: String, Codable, Sendable { case work }
            var phase: Phase { .work }
            enum CodingKeys: String, CodingKey { case count }
            var count = 1
        }
        let definition = TaskDefinition<Int, Invalid, Int, NoTaskHooks>(name: "invalid", version: 1,
            initial: { _ in Invalid() }, phase: { _, _, _ in }, abort: { _, _, _ in })
        #expect(throws: TaskDefinitionError.self) { try definition.kind.initial(1) }
    }

    @Test func registryReservesBuiltinsAndPublishesTaskSnapshots() throws {
        let registry = Registry()
        let before = registry.snapshot()
        #expect(before.tasks().map(\.name) == ["pi.generation", "pi.tool", "pi.compaction"])
        // All built-ins are real since H7/H8 (upstream registry.ts:10 installs them in every registry).
        #expect(before.tasks().map(\.identity) == AnyTaskDefinition.builtins.map(\.identity))
        let definition = definitionTask()
        try registry.install(Extension(name: "user", tasks: [AnyTaskDefinition(definition)]))
        let published = registry.snapshot()
        #expect(before.task(name: definition.name) == nil)
        #expect(published.task(name: definition.name)?.version == 1)
        #expect(throws: HarnessDefinitionError.duplicateTask(extensionName: "other", name: definition.name)) {
            try registry.install(Extension(name: "other", tasks: [AnyTaskDefinition(definition)]))
        }
        #expect(registry.snapshot().installed().map(\.name) == ["user"])
        #expect(throws: HarnessDefinitionError.duplicateTask(extensionName: "built-in", name: "pi.tool")) {
            try registry.install(Extension(name: "built-in", tasks: [AnyTaskDefinition(definitionTask("pi.tool"))]))
        }
        try registry.install(Extension(name: "user", tasks: [AnyTaskDefinition(definitionTask(version: 2))]))
        #expect(registry.snapshot().task(name: definition.name)?.version == 2)
        #expect(published.task(name: definition.name)?.version == 1)
        registry.uninstall(name: "user")
        #expect(registry.snapshot().tasks().count == 3)
    }

    @Test func taskOwnedConversationCopiesStoredAgentInCreationCommit() async throws {
        let storage = MemoryStorage()
        let session = try await Session.open(storage: storage, hooks: DefinitionAgentHooks(), context: .background)
        let definition = definitionTask()
        let values = try await session.commit({ tx in
            let root = try await tx.createConversation(ownership: .ownerless())
            try await tx.doc(AgentDoc, conversationId: root.id).set("future", .string("retained"))
            try await configure(tx: tx, conversationId: root.id, change: AgentChange(instructions: .set("Owner"), cwd: .set("/owner")))
            let task = try await tx.createTask(definition, input: 3,
                options: TaskOptions(ownership: .conversation(), conversationId: root.id))
            let owned = try await tx.createConversation(ownership: .task(taskId: task))
            return (root.id, owned.id)
        }, context: .background)
        let initialRoot = try await session.snapshot(AgentDoc, conversationId: values.0, context: .background)
        let initialOwned = try await session.snapshot(AgentDoc, conversationId: values.1, context: .background)
        #expect(initialRoot == initialOwned)
        let rawToken = try RewindableConversationDocToken<JSONObject>(kind: "pi.agent", version: 1, fork: .asOf, initial: { [:] })
        let raw = try await session.snapshot(rawToken, conversationId: values.1, context: .background)
        #expect(raw?["future"] == .string("retained"))
        try await session.commit({ tx in
            try await configure(tx: tx, conversationId: values.1,
                change: AgentChange(instructions: .clear, cwd: .set("/child")))
        }, context: .background)
        #expect(try await session.snapshot(AgentDoc, conversationId: values.0, context: .background)?.instructions == "Owner")
        let owned = try await session.snapshot(AgentDoc, conversationId: values.1, context: .background)
        #expect(owned?.instructions == nil)
        #expect(owned?.cwd == "/child")
        try await session.commit({ tx in
            try await tx.doc(AgentDoc, conversationId: values.0).set("model", .number(1))
            try await configure(tx: tx, conversationId: values.0, change: AgentChange(model: .clear))
        }, context: .background)
        #expect(try await session.snapshot(AgentDoc, conversationId: values.0, context: .background)?.model == nil)
        try await session.close(context: .background)
    }
}
