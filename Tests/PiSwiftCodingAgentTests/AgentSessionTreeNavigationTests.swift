import Testing
import PiSwiftCodingAgent

@Test func navigateToUserMessagePutsTextInEditor() async throws {
    guard API_KEY != nil else { return }

    let ctx = createTestSession(options: TestSessionOptions(systemPrompt: "You are a helpful assistant. Reply with just a few words."))
    defer { ctx.cleanup() }

    try await ctx.session.prompt("First message")
    await ctx.session.agent.waitForIdle()
    try await ctx.session.prompt("Second message")
    await ctx.session.agent.waitForIdle()

    let tree = ctx.session.sessionManager.getTree()
    #expect(tree.count == 1)

    let root = tree[0]
    let result = await ctx.session.navigateTree(root.entry.id, summarize: false)

    #expect(result.cancelled == false)
    #expect(result.editorText == "First message")
    #expect(ctx.session.sessionManager.getLeafId() == nil)
}

@Test func navigateToAssistantMessageNoEditorText() async throws {
    guard API_KEY != nil else { return }

    let ctx = createTestSession()
    defer { ctx.cleanup() }

    try await ctx.session.prompt("Hello")
    await ctx.session.agent.waitForIdle()

    let entries = ctx.session.sessionManager.getEntries()
    let assistantEntry = entries.first { entry in
        if case .message(let message) = entry, message.message.role == "assistant" {
            return true
        }
        return false
    }
    #expect(assistantEntry != nil)

    let result = await ctx.session.navigateTree(assistantEntry!.id, summarize: false)
    #expect(result.cancelled == false)
    #expect(result.editorText == nil)
    #expect(ctx.session.sessionManager.getLeafId() == assistantEntry!.id)
}

@Test func navigateCreatesBranchSummary() async throws {
    guard API_KEY != nil else { return }

    let ctx = createTestSession()
    defer { ctx.cleanup() }

    try await ctx.session.prompt("What is 2+2?")
    await ctx.session.agent.waitForIdle()
    try await ctx.session.prompt("What is 3+3?")
    await ctx.session.agent.waitForIdle()

    let tree = ctx.session.sessionManager.getTree()
    let root = tree[0]

    let result = await ctx.session.navigateTree(root.entry.id, summarize: true)

    #expect(result.cancelled == false)
    #expect(result.editorText == "What is 2+2?")
    #expect(result.summaryEntry != nil)
    #expect(result.summaryEntry?.summary.isEmpty == false)
    #expect(result.summaryEntry?.parentId == nil)
    #expect(ctx.session.sessionManager.getLeafId() == result.summaryEntry?.id)
}

@Test func summaryAttachesToParentWhenNavigatingNestedUserMessage() async throws {
    guard API_KEY != nil else { return }

    let ctx = createTestSession()
    defer { ctx.cleanup() }

    try await ctx.session.prompt("Message one")
    await ctx.session.agent.waitForIdle()
    try await ctx.session.prompt("Message two")
    await ctx.session.agent.waitForIdle()
    try await ctx.session.prompt("Message three")
    await ctx.session.agent.waitForIdle()

    let entries = ctx.session.sessionManager.getEntries()
    let userEntries = entries.filter { entry in
        if case .message(let message) = entry, message.message.role == "user" {
            return true
        }
        return false
    }
    #expect(userEntries.count == 3)

    let u2 = userEntries[1]
    let parent = entries.first { $0.id == u2.parentId }

    let result = await ctx.session.navigateTree(u2.id, summarize: true)
    #expect(result.cancelled == false)
    #expect(result.editorText == "Message two")
    #expect(result.summaryEntry?.parentId == parent?.id)

    if let parentId = parent?.id {
        let children = ctx.session.sessionManager.getChildren(parentId)
        let types = children.map { $0.type }.sorted()
        #expect(types.contains("branch_summary"))
        #expect(types.contains("message"))
    }
}

@Test func summaryAttachesToAssistantEntry() async throws {
    guard API_KEY != nil else { return }

    let ctx = createTestSession()
    defer { ctx.cleanup() }

    try await ctx.session.prompt("Hello")
    await ctx.session.agent.waitForIdle()
    try await ctx.session.prompt("Goodbye")
    await ctx.session.agent.waitForIdle()

    let entries = ctx.session.sessionManager.getEntries()
    let assistantEntries = entries.filter { entry in
        if case .message(let message) = entry, message.message.role == "assistant" {
            return true
        }
        return false
    }
    let a1 = assistantEntries.first
    #expect(a1 != nil)

    let result = await ctx.session.navigateTree(a1!.id, summarize: true)
    #expect(result.cancelled == false)
    #expect(result.editorText == nil)
    #expect(result.summaryEntry?.parentId == a1!.id)
    #expect(ctx.session.sessionManager.getLeafId() == result.summaryEntry?.id)
}

@Test func abortDuringSummarization() async throws {
    guard API_KEY != nil else { return }

    let ctx = createTestSession()
    defer { ctx.cleanup() }

    try await ctx.session.prompt("Tell me about something")
    await ctx.session.agent.waitForIdle()
    try await ctx.session.prompt("Continue")
    await ctx.session.agent.waitForIdle()

    let entriesBefore = ctx.session.sessionManager.getEntries()
    let leafBefore = ctx.session.sessionManager.getLeafId()

    let tree = ctx.session.sessionManager.getTree()
    let root = tree[0]

    let session = ctx.session
    let task = Task {
        await session.navigateTree(root.entry.id, summarize: true)
    }

    try? await Task.sleep(nanoseconds: 100_000_000)
    session.abortBranchSummary()

    let result = await task.value
    #expect(result.cancelled == true)
    #expect(result.aborted == true)
    #expect(result.summaryEntry == nil)

    let entriesAfter = ctx.session.sessionManager.getEntries()
    #expect(entriesAfter.count == entriesBefore.count)
    #expect(ctx.session.sessionManager.getLeafId() == leafBefore)
}

@Test func navigateWithoutSummarizeCreatesNoSummary() async throws {
    guard API_KEY != nil else { return }

    let ctx = createTestSession()
    defer { ctx.cleanup() }

    try await ctx.session.prompt("First")
    await ctx.session.agent.waitForIdle()
    try await ctx.session.prompt("Second")
    await ctx.session.agent.waitForIdle()

    let entriesBefore = ctx.session.sessionManager.getEntries().count
    let tree = ctx.session.sessionManager.getTree()

    _ = await ctx.session.navigateTree(tree[0].entry.id, summarize: false)

    let entriesAfter = ctx.session.sessionManager.getEntries().count
    #expect(entriesAfter == entriesBefore)
    let summaries = ctx.session.sessionManager.getEntries().filter { $0.type == "branch_summary" }
    #expect(summaries.isEmpty)
}

@Test func navigateToSamePositionNoOp() async throws {
    guard API_KEY != nil else { return }

    let ctx = createTestSession()
    defer { ctx.cleanup() }

    try await ctx.session.prompt("Hello")
    await ctx.session.agent.waitForIdle()

    let leafBefore = ctx.session.sessionManager.getLeafId()
    let entriesBefore = ctx.session.sessionManager.getEntries().count

    if let leafBefore {
        let result = await ctx.session.navigateTree(leafBefore, summarize: false)
        #expect(result.cancelled == false)
        #expect(ctx.session.sessionManager.getLeafId() == leafBefore)
        #expect(ctx.session.sessionManager.getEntries().count == entriesBefore)
    }
}

@Test func navigationSupportsCustomInstructions() async throws {
    guard API_KEY != nil else { return }

    let ctx = createTestSession()
    defer { ctx.cleanup() }

    try await ctx.session.prompt("What is TypeScript?")
    await ctx.session.agent.waitForIdle()

    let tree = ctx.session.sessionManager.getTree()
    let result = await ctx.session.navigateTree(tree[0].entry.id, summarize: true, customInstructions: "Summarize in exactly 3 words.")

    #expect(result.summaryEntry != nil)
    if let summary = result.summaryEntry?.summary {
        #expect(summary.split(whereSeparator: { $0.isWhitespace }).count < 20)
    }
}

@Test func navigateAcrossBranchesSummarizesPreviousBranch() async throws {
    guard API_KEY != nil else { return }

    let ctx = createTestSession(options: TestSessionOptions(systemPrompt: "You are a helpful assistant. Reply with just a few words."))
    defer { ctx.cleanup() }

    try await ctx.session.prompt("Main branch start")
    await ctx.session.agent.waitForIdle()
    try await ctx.session.prompt("Main branch continue")
    await ctx.session.agent.waitForIdle()

    let entries = ctx.session.sessionManager.getEntries()
    let a1 = entries.first { entry in
        if case .message(let message) = entry, message.message.role == "assistant" {
            return true
        }
        return false
    }
    #expect(a1 != nil)

    if let a1 {
        try ctx.session.sessionManager.branch(a1.id)
        try await ctx.session.prompt("Branch path")
        await ctx.session.agent.waitForIdle()
    }

    let userEntries = entries.filter { entry in
        if case .message(let message) = entry, message.message.role == "user" {
            return true
        }
        return false
    }
    if userEntries.count > 1 {
        let u2 = userEntries[1]
        let result = await ctx.session.navigateTree(u2.id, summarize: true)
        #expect(result.cancelled == false)
        #expect(result.editorText == "Main branch continue")
        #expect(result.summaryEntry?.summary.isEmpty == false)
    }
}
