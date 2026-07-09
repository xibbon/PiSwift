import Testing
import PiSwiftCodingAgent
import PiSwiftAI
import PiSwiftAgent

@Test func appendMessageParentChain() {
    let session = SessionManager.inMemory()
    let id1 = session.appendMessage(userMsg("first"))
    let id2 = session.appendMessage(assistantMsg("second"))
    let id3 = session.appendMessage(userMsg("third"))

    let entries = session.getEntries()
    #expect(entries.count == 3)
    #expect(entries[0].id == id1)
    #expect(entries[0].parentId == nil)
    #expect(entries[1].id == id2)
    #expect(entries[1].parentId == id1)
    #expect(entries[2].id == id3)
    #expect(entries[2].parentId == id2)
}

@Test func appendThinkingLevelChangeTree() {
    let session = SessionManager.inMemory()
    let msgId = session.appendMessage(userMsg("hello"))
    let thinkingId = session.appendThinkingLevelChange("high")
    _ = session.appendMessage(assistantMsg("response"))

    let entries = session.getEntries()
    let thinkingEntry = entries.first { $0.type == "thinking_level_change" }
    #expect(thinkingEntry?.id == thinkingId)
    #expect(thinkingEntry?.parentId == msgId)
    #expect(entries.last?.parentId == thinkingId)
}

@Test func appendModelChangeTree() {
    let session = SessionManager.inMemory()
    let msgId = session.appendMessage(userMsg("hello"))
    let modelId = session.appendModelChange("openai", "gpt-4")
    _ = session.appendMessage(assistantMsg("response"))

    let entries = session.getEntries()
    let modelEntry = entries.first { $0.type == "model_change" }
    #expect(modelEntry?.id == modelId)
    #expect(modelEntry?.parentId == msgId)
    #expect(entries.last?.parentId == modelId)
}

@Test func appendCompactionTree() {
    let session = SessionManager.inMemory()
    let id1 = session.appendMessage(userMsg("1"))
    _ = session.appendMessage(assistantMsg("2"))
    let compactionId = session.appendCompaction("summary", id1, 1000)
    _ = session.appendMessage(userMsg("3"))

    let entries = session.getEntries()
    let compactionEntry = entries.first { $0.type == "compaction" }
    #expect(compactionEntry?.id == compactionId)
    #expect(compactionEntry?.parentId == entries[1].id)
    #expect(entries.last?.parentId == compactionId)
}

@Test func appendCustomEntryTree() {
    let session = SessionManager.inMemory()
    let msgId = session.appendMessage(userMsg("hello"))
    let customId = session.appendCustomEntry("my_hook", ["key": "value"])
    _ = session.appendMessage(assistantMsg("response"))

    let entries = session.getEntries()
    let customEntry = entries.first { $0.type == "custom" }
    if case .custom(let entry) = customEntry {
        #expect(entry.id == customId)
        #expect(entry.parentId == msgId)
        #expect(entry.customType == "my_hook")
        #expect((entry.data?.value as? [String: Any])?["key"] as? String == "value")
    } else {
        #expect(Bool(false), "Expected custom entry")
    }
    #expect(entries.last?.parentId == customId)
}

@Test func leafPointerAdvances() {
    let session = SessionManager.inMemory()
    #expect(session.getLeafId() == nil)
    let id1 = session.appendMessage(userMsg("1"))
    #expect(session.getLeafId() == id1)
    let id2 = session.appendMessage(assistantMsg("2"))
    #expect(session.getLeafId() == id2)
    let id3 = session.appendThinkingLevelChange("high")
    #expect(session.getLeafId() == id3)
}

@Test func getBranchPaths() {
    let session = SessionManager.inMemory()
    #expect(session.getBranch().isEmpty)
    let id1 = session.appendMessage(userMsg("1"))
    let id2 = session.appendMessage(assistantMsg("2"))
    let id3 = session.appendMessage(userMsg("3"))
    let path = session.getBranch()
    #expect(path.map(\.id) == [id1, id2, id3])
    let subPath = session.getBranch(id2)
    #expect(subPath.map(\.id) == [id1, id2])
}

@Test func getTreeLinear() {
    let session = SessionManager.inMemory()
    let id1 = session.appendMessage(userMsg("1"))
    let id2 = session.appendMessage(assistantMsg("2"))
    let id3 = session.appendMessage(userMsg("3"))

    let tree = session.getTree()
    #expect(tree.count == 1)
    #expect(tree[0].entry.id == id1)
    #expect(tree[0].children.first?.entry.id == id2)
    #expect(tree[0].children.first?.children.first?.entry.id == id3)
}

@Test func getTreeWithBranches() throws {
    let session = SessionManager.inMemory()
    let id1 = session.appendMessage(userMsg("1"))
    let id2 = session.appendMessage(assistantMsg("2"))
    let id3 = session.appendMessage(userMsg("3"))

    try session.branch(id2)
    let id4 = session.appendMessage(userMsg("4-branch"))

    let tree = session.getTree()
    let node2 = tree[0].children[0]
    let childIds = node2.children.map { $0.entry.id }.sorted()
    #expect(tree[0].entry.id == id1)
    #expect(node2.entry.id == id2)
    #expect(childIds == [id3, id4].sorted())
}

@Test func getTreeMultipleBranches() throws {
    let session = SessionManager.inMemory()
    _ = session.appendMessage(userMsg("root"))
    let id2 = session.appendMessage(assistantMsg("response"))

    try session.branch(id2)
    let idA = session.appendMessage(userMsg("branch-A"))
    try session.branch(id2)
    let idB = session.appendMessage(userMsg("branch-B"))
    try session.branch(id2)
    let idC = session.appendMessage(userMsg("branch-C"))

    let tree = session.getTree()
    let node2 = tree[0].children[0]
    let ids = node2.children.map { $0.entry.id }.sorted()
    #expect(ids == [idA, idB, idC].sorted())
}

@Test func branchMissingEntryThrowsInsteadOfCrashing() {
    let session = SessionManager.inMemory()

    do {
        try session.branch("missing-entry")
        #expect(Bool(false), "Expected missing branch entry to throw")
    } catch {
        #expect(error.localizedDescription == "Entry missing-entry not found")
    }
}

@Test func branchWithSummaryMissingEntryThrowsInsteadOfCrashing() {
    let session = SessionManager.inMemory()

    do {
        _ = try session.branchWithSummary("missing-entry", "summary")
        #expect(Bool(false), "Expected missing summary branch entry to throw")
    } catch {
        #expect(error.localizedDescription == "Entry missing-entry not found")
    }
}

@Test func createBranchedSessionMissingEntryReturnsNil() {
    let session = SessionManager.inMemory()

    #expect(session.createBranchedSession("missing-entry") == nil)
}

@Test func saveCustomEntry() {
    let session = SessionManager.inMemory()
    let msgId = session.appendMessage(userMsg("hello"))
    let customId = session.appendCustomEntry("my_hook", ["foo": "bar"])
    let msg2Id = session.appendMessage(assistantMsg("hi"))

    let entries = session.getEntries()
    #expect(entries.count == 3)
    let customEntry = entries.first { $0.type == "custom" }
    if case .custom(let entry) = customEntry {
        #expect(entry.customType == "my_hook")
        #expect(entry.id == customId)
        #expect(entry.parentId == msgId)
    } else {
        #expect(Bool(false), "Expected custom entry")
    }

    let path = session.getBranch()
    #expect(path.map(\.id) == [msgId, customId, msg2Id])

    let ctx = session.buildSessionContext()
    #expect(ctx.messages.count == 2)
}
