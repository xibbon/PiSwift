import Foundation
import Testing
import PiSwiftAI
import PiSwiftAgent
@testable import PiSwiftCodingAgent

@Test func systemMessageSessionJSONKeepsTwelveSectionNames() throws {
    let names = ["zeta", "beta", "omega", "alpha", "ten", "three", "seven", "delta", "kappa", "gamma", "epsilon", "theta"]
    let sections = SystemPromptSections(names.enumerated().map { (name: $0.element, value: $0.offset == 5 ? nil : "v\($0.offset)") })
    let system = SystemMessage(content: .text("base"), sections: sections,
        toolsAdded: [AITool(name: "one", description: "One", parameters: ["type": AnyCodable("object")])],
        toolsRemoved: [ToolReference(name: "old")], timestamp: 123)
    let exactMessage = encodeAgentMessageJSON(.system(system)).serialized()
    #expect(exactMessage == #"{"role":"system","content":"base","sections":{"zeta":"v0","beta":"v1","omega":"v2","alpha":"v3","ten":"v4","three":null,"seven":"v6","delta":"v7","kappa":"v8","gamma":"v9","epsilon":"v10","theta":"v11"},"toolsAdded":[{"name":"one","description":"One","parameters":{"type":"object"}}],"toolsRemoved":[{"name":"old"}],"timestamp":123}"#)

    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("transcript-session-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let manager = SessionManager.create(directory.path, directory.path)
    let file = try #require(manager.newSession(NewSessionOptions(id: "transcript-test")))
    manager.appendMessage(.system(system))
    manager.appendMessage(.assistant(AssistantMessage(content: [.text(TextContent(text: "done"))],
        api: .openAICompletions, provider: "test", model: "test",
        usage: Usage(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0), stopReason: .stop)))
    let content = try String(contentsOfFile: file, encoding: .utf8)
    #expect(content.contains(exactMessage))
    let reopened = SessionManager.open(file)
    let first = try #require(reopened.getEntries().first)
    guard case .message(let entry) = first, case .system(let restored) = entry.message else {
        Issue.record("Expected system message")
        return
    }
    #expect(restored.sections?.entries.map(\.name) == names)
    #expect(restored.sections?.entries[5].value == nil)
    #expect(encodeAgentMessageJSON(.system(restored)).serialized() == exactMessage)
}

@Test func compactionEstimateCountsSystemToolDeclarationJSON() {
    let tool = AITool(name: "lookup", description: "Lookup", parameters: ["schema": AnyCodable(["long": String(repeating: "x", count: 80)])])
    let system = SystemMessage(content: .text("abcd"), sections: SystemPromptSections([("z", "efgh")]), toolsAdded: [tool])
    let toolsJSON = systemMessageToOrderedJSON(system)["toolsAdded"]!.serialized()
    let expected = (8 + toolsJSON.utf16.count + 3) / 4
    #expect(estimateTokens(.system(system)) == expected)
}
