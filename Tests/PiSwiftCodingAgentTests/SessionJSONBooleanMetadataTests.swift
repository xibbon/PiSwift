import Testing
import PiSwiftCodingAgent

private func booleanSessionEntry(type: String, field: String, literal: String) throws -> SessionEntry {
    let content = """
        {"type":"session","id":"session","timestamp":"2026-01-01T00:00:00Z","cwd":"/tmp","version":3}
        {"type":"\(type)","id":"entry","parentId":null,"timestamp":"2026-01-01T00:00:00Z","\(field)":\(literal)}
        """
    let entries = parseSessionEntries(content)
    #expect(entries.count == 2)
    guard case .entry(let entry) = try #require(entries.last) else {
        throw BooleanSessionEntryError.missingEntry
    }
    return entry
}

private enum BooleanSessionEntryError: Error { case missingEntry }

@Suite struct SessionJSONBooleanMetadataTests {
    @Test func compactionFromHookRequiresBoolean() throws {
        for literal in ["0", "1", "false", "true"] {
            guard case .compaction(let entry) = try booleanSessionEntry(type: "compaction", field: "fromHook", literal: literal) else {
                Issue.record("Expected compaction entry")
                return
            }
            let expected: Bool? = literal == "true" ? true : literal == "false" ? false : nil
            #expect(entry.fromHook == expected)
        }
    }

    @Test func branchSummaryFromHookRequiresBoolean() throws {
        for literal in ["0", "1", "false", "true"] {
            guard case .branchSummary(let entry) = try booleanSessionEntry(type: "branch_summary", field: "fromHook", literal: literal) else {
                Issue.record("Expected branch summary entry")
                return
            }
            let expected: Bool? = literal == "true" ? true : literal == "false" ? false : nil
            #expect(entry.fromHook == expected)
        }
    }

    @Test func customMessageDisplayRequiresBoolean() throws {
        for literal in ["0", "1", "false", "true"] {
            guard case .customMessage(let entry) = try booleanSessionEntry(type: "custom_message", field: "display", literal: literal) else {
                Issue.record("Expected custom message entry")
                return
            }
            #expect(entry.display == (literal != "false"))
        }
    }
}
