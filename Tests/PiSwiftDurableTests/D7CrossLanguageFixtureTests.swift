import Foundation
import Testing
import PiSwiftChord
@testable import PiSwiftDurable
import PiSwiftDurableTesting

#if os(macOS)
/// Export the same six fake-clock scripts that the tagged Node fixture runs.
@Suite("PiSwiftDurableTests.D7CrossLanguageFixtures", .serialized, .timeLimit(.minutes(3)))
struct D7CrossLanguageFixtureTests {
    private let scenarios = ["text", "thinking", "arguments", "output", "crash", "close"]

    private func openStorage(_ backend: String, path: String) async throws -> any DurableStorage {
        if backend == "sqlite" { return try await SqliteStorage.open(path: path) }
        return try await JsonlStorage.open(directory: path)
    }

    private func openSession(_ storage: ControlledStorage, clock: TestClock,
                             publications: SessionTestLog<CommitPublication>) async throws -> Session {
        let session = try await Session.open(storage: storage, now: { clock.now() },
            documentRetentionMs: 600_000,
            documentTimer: .init(now: { clock.now() }, sleep: { try await clock.sleep(until: $0) }),
            persistWithinMs: { 100 }, context: .background)
        _ = try session.subscribeCommits { publication, _ in publications.append(publication) }
        return session
    }

    private func run(_ scenario: String, backend: String, directory: URL) async throws -> JSONValue {
        let path = directory.appendingPathComponent("\(scenario)-\(backend)").path
        let clock = TestClock(now: 1_000)
        let publications = SessionTestLog<CommitPublication>()
        var wrappers: [ControlledStorage] = []
        func reopen() async throws -> (Session, ControlledStorage) {
            let controlled = ControlledStorage(try await openStorage(backend, path: path))
            wrappers.append(controlled)
            return (try await openSession(controlled, clock: clock, publications: publications), controlled)
        }
        let initial: JSONObject = ["text": "", "thinking": "",
            "tools": [["arguments": "", "output": ""]]]
        let token = try ConversationDocToken<JSONObject>(kind: "pi.live", version: 3, fork: .initial,
            initial: { initial }, checkpointWhen: { value, _, _ in value["base"] == .bool(true) })
        var (session, storage) = try await reopen()
        let id = try await createConversation(session)
        try await session.commit({ tx in _ = try await tx.doc(token, conversationId: id) }, context: .background)
        let baselineBatches = await storage.commitBatches.flatMap { $0 }.count
        let baselinePublications = publications.count
        var reopenStates: [JSONValue] = []

        func append(_ field: String, _ part: String, within: Double? = nil) async throws {
            try await session.commit({ tx in
                let live = try await tx.doc(token, conversationId: id)
                if field == "text" || field == "thinking" { try live.appendText(field, part) }
                else { try #require(try live.child("tools")?.child(0)).appendText(field, part) }
            }, context: .background, persistence: .deferred(withinMs: within))
        }
        func storedValue() async throws -> JSONValue {
            let reader = try await openStorage(backend, path: path)
            let address = DocumentAddress(kind: token.definition.kind, scope: .conversation(conversationId: id))
            let record = try #require(try await reader.findDocument(address, at: .current, context: .background))
            let value = try #require(try await reader.document(record.id, at: .current, context: .background))
            try await reader.close(context: .background)
            return .object(value.value)
        }
        switch scenario {
        case "text":
            try await append("text", "abcd", within: 100)
            try await append("text", "efgh", within: 200)
            clock.advance(by: 100)
            let activeStorage = storage
            try await eventually { await activeStorage.commitBatches.flatMap { $0 }.count == baselineBatches + 1 }
            try await append("text", "ijkl", within: .infinity)
            try await session.commit({ tx in
                _ = try await tx.doc(token, conversationId: id).get("text")
                _ = try await tx.appendEntry(id, value: EntryDraft(kind: "derived"))
            }, context: .background)
        case "thinking":
            try await append("thinking", "why ")
            try await append("thinking", "now")
            try await session.commit({ tx in try await tx.doc(token, conversationId: id).set("base", true) }, context: .background)
        case "arguments":
            try await append("arguments", "{\"x\":")
            try await append("arguments", "1}")
        case "output":
            try await append("output", "one\n", within: 50)
            try await append("output", "two\n", within: 200)
            clock.advance(by: 50)
            let activeStorage = storage
            try await eventually { await activeStorage.commitBatches.flatMap { $0 }.count == baselineBatches + 1 }
        case "crash":
            try await append("text", "lost", within: .infinity)
            session.fail(SessionError.message("fixture crash"))
            _ = await session.closed
            reopenStates.append(try await storedValue())
            (session, storage) = try await reopen()
            try await append("text", "kept", within: 25)
            clock.advance(by: 25)
            let activeStorage = storage
            try await eventually { await activeStorage.commitBatches.flatMap { $0 }.count == 1 }
            try await append("text", "lost-again", within: .infinity)
            session.fail(SessionError.message("fixture crash"))
            _ = await session.closed
            reopenStates.append(try await storedValue())
            (session, storage) = try await reopen()
            try await append("text", "-resumed", within: .infinity)
        case "close":
            try await append("text", "closed", within: .infinity)
        default: Issue.record("Unknown D7 fixture scenario \(scenario)")
        }
        try await session.close(context: .background)
        let final = try await storedValue()
        var batches: [[StorageWrite]] = []
        for wrapper in wrappers { batches += await wrapper.commitBatches.flatMap { $0 } }
        batches.removeFirst(baselineBatches)
        let stored = Array(publications.values.dropFirst(baselinePublications))
        #expect(stored.count == batches.count)
        let commits: [JSONValue] = try zip(stored, batches).map { publication, writes in
            let documents: [JSONValue] = try writes.compactMap { write in
                guard case .documentChange(let id, let content, _) = write else { return nil }
                return ["id": try JSONValue(encoding: id), "content": try JSONValue(encoding: content)]
            }
            return ["seq": try JSONValue(encoding: publication.seq), "documents": .array(documents)]
        }
        return ["commits": .array(commits), "reopens": .array(reopenStates), "final": final]
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["PISWIFT_D7_FIXTURE_EXPORT"] != nil),
          .timeLimit(.minutes(3)))
    func exportsSixScriptsOnSQLiteAndJSONL() async throws {
        let destination = try #require(ProcessInfo.processInfo.environment["PISWIFT_D7_FIXTURE_EXPORT"])
        let directory = URL(fileURLWithPath: destination)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var cases: JSONObject = [:]
        for scenario in scenarios {
            for backend in ["sqlite", "jsonl"] {
                cases["\(scenario)-\(backend)"] = try await run(scenario, backend: backend, directory: directory)
            }
        }
        let manifest: JSONValue = ["tag": "v1.5.2", "cases": .object(cases)]
        try (manifest.jsonText() + "\n").write(to: directory.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
    }
}
#endif
