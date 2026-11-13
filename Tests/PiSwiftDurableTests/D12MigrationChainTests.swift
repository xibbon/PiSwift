import Foundation
import Testing
import PiSwiftAI
import PiSwiftChord
@testable import PiSwiftDurable
import PiSwiftDurableTesting

#if os(macOS)
/// One process step in a chain that starts from a frozen older-tag file.
/// The Node checker invokes all cases in one Swift process per chain position.
@Suite("PiSwiftDurableTests.D12MigrationChains", .serialized)
struct D12MigrationChainTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["PISWIFT_D12_MIGRATION_PLAN"] != nil),
          .timeLimit(.minutes(2)))
    func continuesOlderTagFiles() async throws {
        let plan = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["PISWIFT_D12_MIGRATION_PLAN"]))
        let cases = try #require(JSONValue(jsonData: Data(contentsOf: plan))["cases"]?.arrayValue)
        for item in cases {
            let path = try #require(item["path"]?.stringValue)
            let backend = try #require(item["backend"]?.stringValue)
            let step = try #require(item["step"]?.intValue)
            let storage: any DurableStorage = backend == "sqlite"
                ? try await SqliteStorage.open(path: path)
                : try await JsonlStorage.open(directory: path, fileSystem: LocalExecutionEnv(cwd: path))
            var response = chatAssistant("migration-step-\(step)")
            response.timestamp = 1_000
            response.durationMs = 0
            response.thinkingLevel = .off
            let models = FakeDurableModels(responses: Array(repeating: .message(response), count: 20),
                tagCacheAccounting: true)
            let harness = try await Harness.open(storage: storage,
                options: .init(models: models, registry: createRegistry(),
                    settings: HarnessSettingsProvider { .init(retry: .init(enabled: false)) },
                    now: { 1_000 }), context: .background)
            let conversation: Conversation
            if step == 1 {
                conversation = try await harness.createConversation(options: .init(
                    ownership: .ownerless(),
                    agent: .init(model: .set(.init(provider: "faux", modelId: "faux-1")))),
                    context: .background)
            } else {
                let page = try await storage.scanConversations(.init(order: .ascending), limit: 1_000,
                    cursor: nil, context: .background)
                let id = try #require(page.items.last?.id)
                conversation = try #require(try await harness.conversation(id: id, context: .background))
            }
            let submission = try await conversation.submit(.input(content: .text("migration-input-\(step)")),
                context: .background)
            let done = try await submission.wait(context: .background)
            #expect(done.status == "done", "\(backend) step \(step): \(done.status)")
            try await conversation.waitForIdle(context: .background)
            try await harness.close(context: .background)
        }
    }
}
#endif
