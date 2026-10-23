import Foundation
import PiSwiftChord
@testable import PiSwiftCodingAgentDurable
import PiSwiftDurable
import PiSwiftDurableTesting
import Testing

@Suite struct DurableAgentSelectionTests {
    @Test func modelFilterSurvivesHostViewCoding() throws {
        for filter: ModelToolSelection in [.exact(["probe"]), .edit(add: ["loaded"], remove: ["bash"])] {
            let agent = PiSwiftDurable.AgentState(modelTools: filter, cwd: "/repo")
            let document = try #require(JSONValue(encoding: agent).objectValue)
            let view = DurableView(session: .init(id: "session", directory: "/session", cwd: "/repo"),
                conversation: .init(conversation: .init(id: rootConversationID), entries: [], docs: ["pi.agent": document]),
                conversations: [], models: [])
            let decoded = try JSONValue(encoding: view).decode(DurableView.self)
            #expect(try decodeAgentOf(decoded.conversation) == agent)
            #expect(agentOf(decoded.conversation) == agent)
        }
    }

    @Test func strictHostDecodeReportsMalformedModelFilters() {
        let view = ConversationView(conversation: .init(id: rootConversationID), entries: [],
            docs: ["pi.agent": ["modelTools": ["remove": .bool(false)]]])
        #expect(throws: (any Error).self) { try decodeAgentOf(view) }
    }

    @Test func absentDocumentHasNoAgentOverrides() throws {
        let view = ConversationView(conversation: .init(id: rootConversationID), entries: [], docs: [:])
        #expect(try decodeAgentOf(view) == PiSwiftDurable.AgentState())
    }
    @Test func continuedRuntimeRejectsMalformedModelFilterAndReleasesLock() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let cwd = directory.appendingPathComponent("cwd").path
        let agentDirectory = directory.appendingPathComponent("agent").path
        try FileManager.default.createDirectory(atPath: cwd, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: agentDirectory, withIntermediateDirectories: true)
        defer { do { try FileManager.default.removeItem(at: directory) } catch { Issue.record(error) } }
        let models = FakeDurableModels()
        let location = try await selectSession(cwd, continueSession: false, agentDirectory: agentDirectory)
        let harness = try await Harness.open(storage: SqliteStorage.open(path: location.database),
            options: .init(models: models, registry: createRegistry()), context: .background)
        let root = try await harness.root(context: .background)
        try await root.commit({ tx in
            let agent = try await tx.doc(AgentDoc, conversationId: root.id)
            try agent.set("modelTools", [1])
        }, context: .background)
        try await harness.close(context: .background)
        location.release()
        let dependencies = OpenDurableDependencies(agentDirectory: agentDirectory, makeModels: { _ in
            .init(models: models, available: models.models, initial: { _ in .init(model: nil) })
        })
        await #expect(throws: (any Error).self) {
            _ = try await openDurable(.init(cwd: cwd, continueSession: true), dependencies: dependencies)
        }
        let reopened = try await selectSession(cwd, continueSession: true, agentDirectory: agentDirectory)
        #expect(!reopened.created)
        reopened.release()
    }

}
