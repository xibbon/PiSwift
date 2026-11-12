import Foundation
import Testing
import PiSwiftChord
import PiSwiftDurable
import PiSwiftDurableTesting
@testable import PiSwiftCodingAgentDurable

@Test(.enabled(if: ProcessInfo.processInfo.environment["PI_D4_SMOKE_SEED"] == "1"),
      .timeLimit(.minutes(1)))
func seedD4SmokeSessionWithTwoHundredEntries() async throws {
    let environment = ProcessInfo.processInfo.environment
    let cwd = try #require(environment["PI_D4_SMOKE_CWD"])
    let agent = try #require(environment["PI_D4_SMOKE_AGENT"])
    try FileManager.default.createDirectory(atPath: cwd, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(atPath: agent, withIntermediateDirectories: true)
    let location = try await selectSession(cwd, continueSession: false, agentDirectory: agent)
    defer { location.release() }
    let storage = try await SqliteStorage.open(path: location.database)
    let harness = try await Harness.open(storage: storage,
        options: .init(models: FakeDurableModels(), registry: createRegistry()), context: .background)
    let root = try await harness.root(context: .background)
    let written = try await root.commit({ tx in
        var ids: [EntryID] = []
        for number in 1...200 {
            let entry = try await tx.appendEntry(root.id,
                value: .init(kind: "pi.user", model: [
                    .object(["role": "user", "content": .string("smoke entry \(number)")])
                ]))
            ids.append(entry.id)
        }
        return ids
    }, context: .background)
    #expect(written.count == 200)
    try await harness.close(context: .background)
    print("D4-SMOKE-SEEDED entries=200 directory=\(location.directory)")
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["PI_D4_SMOKE_VERIFY"] == "1"),
      .timeLimit(.minutes(1)))
func verifyD4HostShowsTwoHundredEntries() async throws {
    let environment = ProcessInfo.processInfo.environment
    let cwd = try #require(environment["PI_D4_SMOKE_CWD"])
    let agent = try #require(environment["PI_D4_SMOKE_AGENT"])
    let result = try await openDurable(.init(cwd: cwd, continueSession: true), dependencies: .init(
        agentDirectory: agent,
        makeModels: { _ in DurableRuntimeModels(models: FakeDurableModels(), available: [],
                                                initial: { _ in .init(model: nil, thinkingLevel: nil) }) }))
    #expect(result.view.current().conversation.entries.count == 200)
    #expect(result.view.current().conversation.entries.first?.model?.first?.objectValue?["content"] == "smoke entry 1")
    #expect(result.view.current().conversation.entries.last?.model?.first?.objectValue?["content"] == "smoke entry 200")
    print("D4-SMOKE-HOST entries=\(result.view.current().conversation.entries.count)")
    await result.close()
}
