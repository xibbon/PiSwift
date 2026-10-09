import Foundation
import Testing
import PiSwiftChord
import PiSwiftDurable

@Suite("PiSwiftDurableTests.JsonlReclamation")
struct JsonlReclamationTests {
    @Test func appendsDeltasToReplacementSidecar() async throws {
        try await jsonlWithStorage { storage, directory, _ in
            try await jsonlRoot(storage)
            let id: DocumentID = try await storage.mintId()
            _ = try await storage.commit([jsonlCreate(id)], context: .background)
            _ = try await storage.commit([jsonlBase(id, 10)], context: .background)
            _ = try await storage.commit([jsonlDelta(id, 11)], context: .background)
            #expect(try jsonlLines(directory, jsonlDocName(id)).count == 2)
            let reopened = try await jsonlOpen(directory)
            #expect(try await reopened.document(id, at: .current, context: .background)?.value == ["count": 11])
            try await reopened.close(context: .background)
        }
    }
    @Test func keepsRewindableHistoryAfterBaseAndRetirement() async throws {
        try await jsonlWithStorage { storage, directory, _ in
            try await jsonlRoot(storage)
            let id: DocumentID = try await storage.mintId()
            let created = try await storage.commit([jsonlCreate(id, kind: "rewindable", scope: .conversation(conversationId: rootConversationID), history: .rewindable, fork: .asOf)], context: .background)
            let changed = try await storage.commit([jsonlDelta(id, 1)], context: .background)
            _ = try await storage.commit([jsonlBase(id, 2)], context: .background)
            _ = try await storage.commit([.documentRetire(id: id)], context: .background)
            #expect(try jsonlLines(directory, jsonlDocName(id)).count == 3)
            let reopened = try await jsonlOpen(directory)
            #expect(try await reopened.document(id, at: .sequence(created), context: .background)?.value == ["count": 0])
            #expect(try await reopened.document(id, at: .sequence(changed), context: .background)?.value == ["count": 1])
            #expect(try await reopened.document(id, at: .current, context: .background) == nil)
            #expect(try jsonlLines(directory, jsonlDocName(id)).count == 3)
            try await reopened.close(context: .background)
        }
    }
    @Test func reclaimsAllCurrentOnlyScopes() async throws {
        try await jsonlWithStorage { storage, directory, _ in
            try await jsonlRoot(storage)
            let task: TaskID = try await storage.mintId()
            let session: DocumentID = try await storage.mintId()
            let latest: DocumentID = try await storage.mintId()
            let taskDoc: DocumentID = try await storage.mintId()
            let created = try await storage.commit([.task(value: jsonlTask(task)), jsonlCreate(session, kind: "session", value: [:]),
                jsonlCreate(latest, kind: "latest", value: [:], scope: .conversation(conversationId: rootConversationID), history: .latest, fork: .current),
                jsonlCreate(taskDoc, kind: "task", value: [:], scope: .task(taskId: task))], context: .background)
            let retired = try await storage.commit([.documentRetire(id: session), .documentRetire(id: latest), .documentRetire(id: taskDoc), .task(value: jsonlTask(task, terminal: true))], context: .background)
            for name in [jsonlDocName(session), jsonlDocName(latest), jsonlDocName(taskDoc), jsonlTaskName(task)] { #expect(!jsonlExists(directory, name)) }
            let reopened = try await jsonlOpen(directory)
            #expect(try await reopened.task(task, context: .background) == jsonlTask(task, terminal: true))
            for id in [session, latest, taskDoc] { #expect(try await reopened.document(id, at: .current, context: .background) == nil) }
            let address = DocumentAddress(kind: "session", scope: .session())
            let found = try await reopened.findDocument(address, at: .sequence(created), context: .background)
            #expect(found?.id == session)
            #expect(found?.createdAt == created)
            #expect(found?.retiredAt == retired)
            #expect(try await reopened.findDocument(address, at: .sequence(retired), context: .background) == nil)
            try await reopened.close(context: .background)
        }
    }
}
