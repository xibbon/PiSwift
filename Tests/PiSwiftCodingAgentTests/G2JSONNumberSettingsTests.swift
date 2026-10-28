import Foundation
import Testing
import PiSwiftAI
@testable import PiSwiftCodingAgent

private func g2SettingsDirectory() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("g2-settings-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

private let g2SmallBudgets = #"{"compaction":{"reserveTokens":0,"keepRecentTokens":1,"modelOverrides":{"openai/gpt-4o-mini":{"reserveTokens":0,"keepRecentTokens":1}}}}"#

@Test func g2CompactionLoadsZeroAndOneFromJSON() throws {
    let root = try g2SettingsDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    try Data(g2SmallBudgets.utf8).write(to: root.appendingPathComponent("settings.json"))
    let manager = SettingsManager.create(root.path, root.path)
    #expect(manager.drainErrors().isEmpty)
    let ordinary = try manager.validatedCompactionSettings()
    #expect(ordinary.reserveTokens == 0 && ordinary.keepRecentTokens == 1)
    let overrides = try #require(manager.getCompactionSettingsOverrides().modelOverrides?["openai/gpt-4o-mini"])
    #expect(overrides.reserveTokens == 0 && overrides.keepRecentTokens == 1)
    let model = getModel(provider: .openai, modelId: "gpt-4o-mini")
    let matching = try manager.validatedCompactionSettings(model: model)
    #expect(matching.reserveTokens == 0 && matching.keepRecentTokens == 1)
    #expect(manager.getCompactionSettings(model: model).reserveTokens == 0)
    #expect(manager.getCompactionSettings(model: model).keepRecentTokens == 1)
}

@Test func g2CompactionReloadAppliesZeroAndOne() async throws {
    let root = try g2SettingsDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let path = root.appendingPathComponent("settings.json")
    try Data(#"{"compaction":{"reserveTokens":7000,"keepRecentTokens":9000,"modelOverrides":{"openai/gpt-4o-mini":{"reserveTokens":3000,"keepRecentTokens":4000}}}}"#.utf8).write(to: path)
    let manager = SettingsManager.create(root.path, root.path)
    #expect(manager.getCompactionSettings().reserveTokens == 7000)
    let model = getModel(provider: .openai, modelId: "gpt-4o-mini")
    #expect(manager.getCompactionSettings(model: model).keepRecentTokens == 4000)
    try Data(g2SmallBudgets.utf8).write(to: path)
    await manager.reload()
    #expect(manager.drainErrors().isEmpty)
    let ordinary = try manager.validatedCompactionSettings()
    let matching = try manager.validatedCompactionSettings(model: model)
    #expect(ordinary.reserveTokens == 0 && ordinary.keepRecentTokens == 1)
    #expect(matching.reserveTokens == 0 && matching.keepRecentTokens == 1)
}

@Test func g2CompactionRejectsInvalidJSONBudgets() async throws {
    let root = try g2SettingsDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let path = root.appendingPathComponent("settings.json")
    for value in ["true", "false", "-1", "1.5", #""1""#, "9007199254740992"] {
        for field in ["reserveTokens", "keepRecentTokens"] {
            for modelOverride in [false, true] {
                try Data(g2SmallBudgets.utf8).write(to: path)
                let manager = SettingsManager.create(root.path, root.path)
                let entry = "\"\(field)\":\(value)"
                let compaction = modelOverride ? "\"modelOverrides\":{\"openai/gpt-4o-mini\":{\(entry)}}" : entry
                try Data("{\"compaction\":{\(compaction)}}".utf8).write(to: path)
                let invalid = SettingsManager.create(root.path, root.path)
                #expect(invalid.drainErrors().contains { $0.message.contains(field) })
                await manager.reload()
                #expect(manager.drainErrors().contains { $0.message.contains(field) })
                let retained = try manager.validatedCompactionSettings()
                #expect(retained.reserveTokens == 0 && retained.keepRecentTokens == 1)
            }
        }
    }
}

@Test func g2ToolSearchLimitKeepsNumbersDistinctFromBooleans() async throws {
    let tool = createToolSearchToolDefinition()
    let context = CustomToolContext(sessionManager: .inMemory(),
        modelRegistry: ModelRegistry(AuthStorage(":memory:")), model: nil,
        isIdle: { true }, hasPendingMessages: { false }, abort: {},
        events: createEventBus(), sendMessage: { _, _ in })
    for text in ["0", "1", "true", "false"] {
        let raw = try JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed])
        let parameters = ["query": AnyCodable("search"), "limit": AnyCodable(raw)]
        if text == "1" {
            let result = try await tool.execute("g2", parameters, nil, context, nil)
            #expect(result.content.compactMap { if case .text(let text) = $0 { text.text } else { nil } } == ["No matching tools found."])
        } else {
            await #expect(throws: ToolSearchError.invalidLimit) {
                try await tool.execute("g2", parameters, nil, context, nil)
            }
        }
    }
}
