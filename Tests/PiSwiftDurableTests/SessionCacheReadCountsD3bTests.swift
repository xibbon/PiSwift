import Testing
import PiSwiftChord
@testable import PiSwiftDurable
import PiSwiftDurableTesting

@Suite("PiSwiftDurableTests.SessionCacheReadCountsD3b", .timeLimit(.minutes(1)))
struct SessionCacheReadCountsD3bTests {
    @Test("faux-model conversation fixture counts storage record reads")
    func fauxConversation() async throws {
        let backend = ControlledStorage()
        let setup = HarnessChatSetup()
        setup.models.setResponses([.message(chatAssistant("one")), .message(chatAssistant("two"))])
        let opened = try await openChat(storage: backend, setup: setup)
        for text in ["first", "second"] {
            let submission = try await generationSubmit(opened, text)
            #expect(try await submission.wait(context: .background).status == "done")
        }
        print("D3B-FAUX conversations=\(await backend.conversationReadCount) tasks=\(await backend.taskReadCount) submissions=\(await backend.submissionReadCount) entryScans=\(await backend.entryScanCount) markers=\(await backend.headMarkerReadCount)")
        try await opened.harness.close(context: .background)
    }
}
