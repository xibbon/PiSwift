import Foundation
import Testing
import PiSwiftCodingAgent

@Test(.timeLimit(.minutes(1))) func forkFromSingleMessage() async throws {
    guard API_KEY != nil else { return }

    let ctx = createTestSession()
    defer { ctx.cleanup() }

    try await ctx.session.prompt("Say hello")
    await ctx.session.agent.waitForIdle()

    let userMessages = ctx.session.getUserMessagesForForking()
    #expect(userMessages.count == 1)
    #expect(userMessages[0].text == "Say hello")

    let result = try await ctx.session.fork(userMessages[0].entryId)
    #expect(result.selectedText == "Say hello")
    #expect(result.cancelled == false)

    #expect(ctx.session.messages.isEmpty)

    if let sessionFile = ctx.session.sessionFile {
        #expect(FileManager.default.fileExists(atPath: sessionFile))
    } else {
        #expect(Bool(false), "Expected session file to exist")
    }
}

@Test(.timeLimit(.minutes(1))) func forkInMemory() async throws {
    guard API_KEY != nil else { return }

    let ctx = createTestSession(options: TestSessionOptions(inMemory: true))
    defer { ctx.cleanup() }

    #expect(ctx.session.sessionFile == nil)

    try await ctx.session.prompt("Say hi")
    await ctx.session.agent.waitForIdle()

    let userMessages = ctx.session.getUserMessagesForForking()
    #expect(userMessages.count == 1)
    #expect(ctx.session.messages.count > 0)

    let result = try await ctx.session.fork(userMessages[0].entryId)
    #expect(result.selectedText == "Say hi")
    #expect(result.cancelled == false)

    #expect(ctx.session.messages.isEmpty)
    #expect(ctx.session.sessionFile == nil)
}

@Test(.timeLimit(.minutes(1))) func forkFromMiddleOfConversation() async throws {
    guard API_KEY != nil else { return }

    let ctx = createTestSession()
    defer { ctx.cleanup() }

    try await ctx.session.prompt("Say one")
    await ctx.session.agent.waitForIdle()
    try await ctx.session.prompt("Say two")
    await ctx.session.agent.waitForIdle()
    try await ctx.session.prompt("Say three")
    await ctx.session.agent.waitForIdle()

    let userMessages = ctx.session.getUserMessagesForForking()
    #expect(userMessages.count == 3)

    let secondMessage = userMessages[1]
    let result = try await ctx.session.fork(secondMessage.entryId)
    #expect(result.selectedText == "Say two")

    #expect(ctx.session.messages.count == 2)
    #expect(ctx.session.messages.first?.role == "user")
    #expect(ctx.session.messages.last?.role == "assistant")
}
