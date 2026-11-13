import Foundation
import PiSwiftChord
import PiSwiftCodingAgentDurable
import PiSwiftDurable
import PiSwiftDurableTesting
import Testing

@Test func hostJsonlViewerSetsBothReadOnlySwitchesAndKeepsBytes() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("piswift-d9-host-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let writer = try await JsonlStorage.open(directory: directory.path)
    _ = try await writer.commit([.conversation(value: .init(id: rootConversationID))], context: .background)
    try await writer.close(context: .background)
    let main = directory.appendingPathComponent("main.jsonl")
    let before = try Data(contentsOf: main)
    let setup = HarnessChatSetup()
    let viewer = try await openDurableJsonlViewer(directory: directory.path,
        options: .init(models: setup.models, registry: setup.registry))
    #expect(try await viewer.root(context: .background).id == rootConversationID)
    #expect(throws: ReadOnlySession.self) { try viewer.resume() }
    try await viewer.close(context: .background)
    #expect(try Data(contentsOf: main) == before)
}
