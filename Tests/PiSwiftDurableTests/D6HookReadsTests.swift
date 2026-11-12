import Testing
import PiSwiftAI
import PiSwiftChord
import PiSwiftDurableTesting
@testable import PiSwiftDurable

// Direct mirrors of v1.5.2 harness-hook-reads.test.ts:16–94.
@Suite("PiSwiftDurableTests.D6HookReads", .timeLimit(.minutes(1)))
struct D6HookReadsTests {
    @Test("reads raw history and single entries from a hook")
    func generationYieldReadsBeforeAnswerCommit() async throws {
        let seen = SessionTestLog<[String]>()
        let userToken = try EntryKind<JSONValue>("pi.user")
        let otherToken = try EntryKind<JSONValue>("pi.generation")
        let setup = HarnessChatSetup()
        try setup.registry.install(Extension(name: "reader", hooks: [hook(GenerationHooks(onYield: { _, api, context in
            let page = try await api.entries(.init(order: .ascending), limit: 10, context: context)
            let first = try #require(page.items.first)
            let user = try await api.entry(userToken, id: first.id, context: context)
            #expect(user?.kind == "pi.user")
            #expect(try await api.entry(otherToken, id: first.id, context: context) == nil)
            seen.append(page.items.map(\.kind))
            return nil
        }))]))
        setup.models.setResponses([.message(chatAssistant("done"))])
        let chat = try await openChat(setup: setup)
        _ = try await chat.root.submit(.input(content: .text("go")), context: .background).wait(context: .background)
        #expect(seen.values == [["pi.user"]])
        try await chat.harness.close(context: .background)
    }

    @Test("pages a task's conversation history by entry ID range")
    func taskPagesRawHistory() async throws {
        let pages = SessionTestLog<[EntryID]>()
        let reader = harnessOneStep("test.d6.reader") { _, runtime, context in
            let first = try await runtime.entries(.init(order: .ascending), limit: 1, context: context)
            pages.append(first.items.map(\.id))
            let rest = try await runtime.entries(.init(order: .ascending), limit: 1, cursor: first.next, context: context)
            pages.append(rest.items.map(\.id))
            let secondID = try #require(rest.items.first?.id)
            let bounded = try await runtime.entries(.init(minEntryId: secondID, maxEntryId: secondID), limit: 10, context: context)
            pages.append(bounded.items.map(\.id))
            try await runtime.commit({ _, _ in .terminal(outcome: .completed(result: .number(1))) }, context: context)
        }
        let setup = HarnessChatSetup()
        try setup.registry.install(Extension(name: "reader", tasks: [AnyTaskDefinition(reader)]))
        setup.models.setResponses([.message(chatAssistant("done"))])
        let chat = try await openChat(setup: setup)
        _ = try await chat.root.submit(.input(content: .text("go")), context: .background).wait(context: .background)
        let id = try await harnessStart(chat.root, reader)
        _ = try await chat.harness.waitForTask(id: id, context: .background)
        let entries = try await allEntries(chat.root)
        #expect(entries.map(\.kind) == ["pi.user", "pi.assistant"])
        #expect(pages.values == [[entries[0].id], [entries[1].id], [entries[1].id]])
        try await chat.harness.close(context: .background)
    }
}
