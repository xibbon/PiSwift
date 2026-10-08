import Testing
@testable import PiSwiftAI

private func a2FauxRegistration() -> FauxProviderRegistration {
    let model = Model(id: "a2-faux", name: "Faux", api: .openAICompletions, provider: "faux",
        baseUrl: "http://localhost:0", reasoning: false, input: [.text],
        cost: ModelCost(input: 0, output: 0, cacheRead: 0, cacheWrite: 0), contextWindow: 128_000, maxTokens: 16_384)
    return FauxProviderRegistration(api: model.api, provider: model.provider, models: [model],
        sourceId: "a2-faux", minTokenSize: 3, maxTokenSize: 5, tokensPerSecond: nil)
}

private func a2FauxContext(_ texts: [String]) -> TranscriptContext {
    normalizeContext(Context(messages: texts.map { .user(UserMessage(content: .text($0), timestamp: 1)) }))
}

private func a2FauxComplete(_ registration: FauxProviderRegistration, context: TranscriptContext,
                          options: SimpleStreamOptions? = nil) async throws -> AssistantMessage {
    let model = try #require(registration.getModel())
    return await fauxStream(model: model, context: context, registration: registration, simpleOptions: options).result()
}

@Suite struct A2FauxV110Tests {
    // Upstream faux-provider.test.ts: no global provider registration is needed.
    @Test func cacheStopsAtFirstDifferenceInJoinedPrompt() async throws {
        let registration = a2FauxRegistration()
        registration.setResponses(["a", "b", "c"].map { .message(fauxAssistantMessage(content: [fauxText($0)])) })
        let options = SimpleStreamOptions(cacheRetention: .short, sessionId: "session-1")
        let first = try await a2FauxComplete(registration, context: a2FauxContext(["hello world"]), options: options)
        #expect(first.usage.input == 4)
        #expect(first.usage.cacheRead == 0)
        #expect(first.usage.cacheWrite == 4)
        #expect(first.usage.output == 1)
        #expect(first.usage.totalTokens == 9)

        let extended = try await a2FauxComplete(registration, context: a2FauxContext(["hello world", "next"]), options: options)
        #expect(extended.usage.input == 3)
        #expect(extended.usage.cacheRead == 4)
        #expect(extended.usage.cacheWrite == 3)
        #expect(extended.usage.output == 1)
        #expect(extended.usage.totalTokens == 11)

        let edited = try await a2FauxComplete(registration, context: a2FauxContext(["hello wide", "next"]), options: options)
        #expect(edited.usage.input == 4)
        #expect(edited.usage.cacheRead == 3)
        #expect(edited.usage.cacheWrite == 4)
        #expect(edited.usage.output == 1)
        #expect(edited.usage.totalTokens == 12)
    }

    @Test func cacheIsSeparateForEachSessionAndRequestsWithoutSession() async throws {
        let registration = a2FauxRegistration()
        registration.setResponses(["first", "second", "third"].map { .message(fauxAssistantMessage(content: [fauxText($0)])) })
        var context = a2FauxContext(["hello"])
        let first = try await a2FauxComplete(registration, context: context,
            options: SimpleStreamOptions(cacheRetention: .short, sessionId: "session-1"))
        #expect(first.usage.cacheWrite > 0)
        context = TranscriptContext(messages: context.messages + [.assistant(first),
            .user(UserMessage(content: .text("follow up"), timestamp: 2))])
        let second = try await a2FauxComplete(registration, context: context,
            options: SimpleStreamOptions(cacheRetention: .short, sessionId: "session-2"))
        #expect(second.usage.cacheRead == 0)
        #expect(second.usage.cacheWrite > 0)
        let third = try await a2FauxComplete(registration, context: context)
        #expect(third.usage.cacheRead == 0)
        #expect(third.usage.cacheWrite == 0)
    }

    @Test func cacheIsUsedForTheSameSession() async throws {
        let registration = a2FauxRegistration()
        registration.setResponses(["first", "second"].map { .message(fauxAssistantMessage(content: [fauxText($0)])) })
        var context = normalizeContext(Context(systemPrompt: "Be concise.", messages: [.user(UserMessage(content: .text("hello")))]))
        let options = SimpleStreamOptions(cacheRetention: .short, sessionId: "session-1")
        let first = try await a2FauxComplete(registration, context: context, options: options)
        #expect(first.usage.cacheRead == 0)
        #expect(first.usage.cacheWrite > 0)
        context = TranscriptContext(messages: context.messages + [.assistant(first),
            .user(UserMessage(content: .text("follow up")))])
        let second = try await a2FauxComplete(registration, context: context, options: options)
        #expect(second.usage.cacheRead > 0)
        #expect(second.usage.input + second.usage.cacheRead > second.usage.input)
    }

    @Test func cacheRetentionNoneDisablesCache() async throws {
        let registration = a2FauxRegistration()
        registration.setResponses(["first", "second"].map { .message(fauxAssistantMessage(content: [fauxText($0)])) })
        var context = a2FauxContext(["hello"])
        let options = SimpleStreamOptions(cacheRetention: CacheRetention.none, sessionId: "session-1")
        _ = try await a2FauxComplete(registration, context: context, options: options)
        context = TranscriptContext(messages: context.messages + [.assistant(fauxAssistantMessage(content: [fauxText("first")])),
            .user(UserMessage(content: .text("follow up")))])
        let second = try await a2FauxComplete(registration, context: context, options: options)
        #expect(second.usage.cacheRead == 0)
        #expect(second.usage.cacheWrite == 0)
    }

    @Test func keepsNilRetentionAndCharacterCounting() async throws {
        let registration = a2FauxRegistration()
        registration.setResponses(["😀", "😀"].map { .message(fauxAssistantMessage(content: [fauxText($0)])) })
        let context = a2FauxContext(["😀😀😀😀"])
        #expect(serializeFauxContext(context) == "user:😀😀😀😀")
        let options = SimpleStreamOptions(sessionId: "session-1")
        for _ in 0..<2 {
            let message = try await a2FauxComplete(registration, context: context, options: options)
            #expect(message.usage.input == 3) // ceil(9 Characters / 4)
            #expect(message.usage.output == 1)
            #expect(message.usage.cacheRead == 0)
            #expect(message.usage.cacheWrite == 0)
        }
    }

    @Test func handlesEqualPromptsAndShorterMessageLists() async throws {
        let registration = a2FauxRegistration()
        registration.setResponses((0..<3).map { _ in .message(fauxAssistantMessage(content: [fauxText("a")])) })
        let options = SimpleStreamOptions(cacheRetention: .short, sessionId: "session-1")
        _ = try await a2FauxComplete(registration, context: a2FauxContext(["hello world", "next"]), options: options)
        let equal = try await a2FauxComplete(registration, context: a2FauxContext(["hello world", "next"]), options: options)
        #expect(equal.usage.cacheRead == 7)
        #expect(equal.usage.cacheWrite == 0)
        #expect(equal.usage.input == 0)
        let shorter = try await a2FauxComplete(registration, context: a2FauxContext(["hello world"]), options: options)
        #expect(shorter.usage.cacheRead == 4)
        #expect(shorter.usage.cacheWrite == 0)
        #expect(shorter.usage.input == 0)
    }

    @Test func registrationStateSupportsConcurrentAccess() async {
        let registration = a2FauxRegistration()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<100 {
                group.addTask {
                    registration.appendResponses([.message(fauxAssistantMessage(content: [fauxText("a")]))])
                    _ = registration.state()
                    _ = registration.pendingResponseCount()
                }
            }
        }
        #expect(registration.pendingResponseCount() == 100)
        #expect(registration.state().callCount == 0)
    }

    @Test func keepsJoinedCharacterCountsAtCarriageReturnBoundaries() async throws {
        let registration = a2FauxRegistration()
        registration.setResponses((0..<5).map { _ in .message(fauxAssistantMessage(content: [fauxText("a")])) })
        let uncached = try await a2FauxComplete(registration, context: a2FauxContext(["\r", "xxxx"]))
        #expect(uncached.usage.input == 4) // The joined prompt has 16 Characters, with one CRLF.
        let options = SimpleStreamOptions(cacheRetention: .short, sessionId: "session-1")
        _ = try await a2FauxComplete(registration, context: a2FauxContext(["\r"]), options: options)
        let extended = try await a2FauxComplete(registration, context: a2FauxContext(["\r", "xxxx"]), options: options)
        #expect(extended.usage.input == 2)
        #expect(extended.usage.cacheRead == 2) // "user:" is the common Character prefix.
        #expect(extended.usage.cacheWrite == 3)
        let edited = try await a2FauxComplete(registration, context: a2FauxContext(["\r", "yyyy"]), options: options)
        #expect(edited.usage.input == 1)
        #expect(edited.usage.cacheRead == 3)
        #expect(edited.usage.cacheWrite == 1)
        let shorter = try await a2FauxComplete(registration, context: a2FauxContext(["\r"]), options: options)
        #expect(shorter.usage.input == 0)
        #expect(shorter.usage.cacheRead == 2)
        #expect(shorter.usage.cacheWrite == 1)
    }
}
