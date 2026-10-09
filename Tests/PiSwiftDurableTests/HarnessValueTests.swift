import Testing
import PiSwiftAI
import PiSwiftChord
import PiSwiftDurable

@Suite struct HarnessValueTests {
    @Test func typedEntryData() throws {
        let remarks = ToolResultEntryData(diagnostics: [.init(severity: .warn, message: "trimmed", code: "truncate")])
        let record = EntryRecord(id: try EntryID(2), conversationId: rootConversationID, kind: "pi.tool-result", data: try JSONValue(encoding: remarks))
        #expect(try toolResultEntry.data(from: record) == remarks)
        #expect(try compactionEntry.data(from: record) == nil)
        let summary = EntryRecord(id: try EntryID(3), conversationId: rootConversationID, kind: "pi.compaction", data: try JSONValue(encoding: CompactionEntryData(reason: .overflow)))
        #expect(try compactionEntry.data(from: summary)?.reason == .overflow)
    }
    @Test func usageAddsOptionalCountersAndSpecialNames() {
        var sum = UsageState(tools: ["__proto__": Usage(input: 1, output: 2, cacheRead: 3, cacheWrite: 4, reasoning: 5, totalTokens: 10, cost: UsageCost(total: 1))])
        addUsageState(sum: &sum, state: UsageState(tools: ["__proto__": Usage(input: 10, output: 20, cacheRead: 30, cacheWrite: 40, cacheWrite1h: 7, totalTokens: 100, cost: UsageCost(total: 2))]))
        #expect(sum.tools["__proto__"]?.input == 11)
        #expect(sum.tools["__proto__"]?.output == 22)
        #expect(sum.tools["__proto__"]?.cacheRead == 33)
        #expect(sum.tools["__proto__"]?.cacheWrite == 44)
        #expect(sum.tools["__proto__"]?.totalTokens == 110)
        #expect(sum.tools["__proto__"]?.cacheWrite1h == 7)
        #expect(sum.tools["__proto__"]?.reasoning == 5)
        #expect(sum.tools["__proto__"]?.cost.total == 3)
    }
    @Test func leafAssignmentKeepsRetainedOrder() {
        var target: JSONValue = ["a": ["old": true, "kept": "x"], "b": [1,2]]
        assignJSON(target: &target, value: ["b": [1,2,3], "a": ["kept": "xy", "new": false]])
        #expect(target.objectValue?.keys == ["a", "b"])
        #expect(target["a"]?.objectValue?.keys == ["kept", "new"])
        #expect(target["b"] == [1,2,3])
        assignJSON(target: &target, value: [1])
        #expect(target == [1])
    }
    @Test func scanPagesInOrder() async throws {
        let items: [Int] = try await scanAll { cursor in
            if cursor == nil { return Page(items: [1, 2], next: ["page": 2]) }
            return Page(items: [3])
        }
        #expect(items == [1, 2, 3])
        #expect(closedError().description == "Harness is closed")
    }
    @Test func providerIdentity() throws {
        let first = try ProviderState.fresh(timestampMs: 1)
        let second = try ProviderState.fresh(timestampMs: 1)
        #expect(first.sessionId != second.sessionId)
        #expect(first.sessionId.count == 36)
    }
}
