import Testing
import PiSwiftChord
import PiSwiftDurable

private enum InjectedCommitFailure: Error, Equatable { case expected }

extension PiSwiftDurableTests {
    @Test func controlledStorageCommitGateAndBatches() async throws {
        let storage = ControlledStorage()
        let gate = await storage.holdCommits()
        let writes: [StorageWrite] = [.conversation(value: ConversationRecord(id: rootConversationID))]
        let held = Task { try await storage.commit(writes, context: .background) }
        await gate.waitUntilEntered()
        #expect(await storage.admittedCommits == [writes])
        #expect(await storage.commits == [writes])
        #expect(try await storage.conversation(rootConversationID, context: .background) == nil)
        await gate.release()
        await gate.release()
        #expect(try await held.value == Seq(1))
        #expect(try await storage.conversation(rootConversationID, context: .background)?.id == rootConversationID)
        #expect(try await storage.commit([], context: .background) == Seq(2))
        #expect(await storage.admittedCommits == [writes, []])
        #expect(await storage.commits == [writes, []])
    }

    @Test func controlledStorageFindGate() async throws {
        let storage = ControlledStorage()
        let address = DocumentAddress(kind: "held", scope: .session())
        let gate = await storage.holdFindDocument()
        let held = Task { try await storage.findDocument(address, at: .current, context: .background) }
        await gate.waitUntilEntered()
        let documentID = try DocumentID(2)
        _ = try await storage.commit([
            .documentCreate(record: DocumentCreate(id: documentID, kind: "held", scope: .session()), content: DocumentBaseContent(version: 1, value: ["count": 1])),
        ], context: .background)
        await gate.release()
        await gate.release()
        #expect(try await held.value?.id == documentID)
        #expect(try await storage.findDocument(address, at: .current, context: .background)?.id == documentID)
        #expect(await storage.documentReadCount == 0)
    }

    @Test func controlledStorageMintAndDocumentCounters() async throws {
        let storage = ControlledStorage()
        #expect(await storage.mintCount == 0)
        #expect(await storage.documentReadCount == 0)
        let first: EntryID = try await storage.mintId()
        let second: TaskID = try await storage.mintId()
        #expect(second.rawValue == first.rawValue + 1)
        #expect(await storage.mintCount == 2)
        #expect(try await storage.document(DocumentID(20), at: .current, context: .background) == nil)
        #expect(try await storage.document(DocumentID(21), at: .current, context: .background) == nil)
        #expect(await storage.documentReadCount == 2)
    }

    @Test func controlledStorageFailureIsOneShot() async throws {
        let storage = ControlledStorage()
        let writes: [StorageWrite] = [.conversation(value: ConversationRecord(id: rootConversationID))]
        let gate = await storage.holdCommits()
        let held = Task { try await storage.commit(writes, context: .background) }
        await gate.waitUntilEntered()
        // Upstream reads the injected error after the commit gate opens.
        await storage.failNextCommit(InjectedCommitFailure.expected)
        await gate.release()
        do {
            _ = try await held.value
            Issue.record("The commit did not throw the injected error")
        } catch {
            #expect(error as? InjectedCommitFailure == .expected)
        }
        #expect(try await storage.conversation(rootConversationID, context: .background) == nil)
        #expect(await storage.admittedCommits == [writes])
        #expect(await storage.commits == [writes])
        #expect(try await storage.commit(writes, context: .background) == Seq(1))
        #expect(await storage.commits == [writes, writes])
    }

    @Test func controlledStorageCrashAndReplacedGate() async throws {
        let storage = ControlledStorage()
        let crashedGate = await storage.holdCommits()
        let held = Task { try await storage.commit([], context: .background) }
        await crashedGate.waitUntilEntered()
        await storage.crash()
        #expect(try await storage.commit([], context: .background) == Seq(1))
        let nextGate = await storage.holdCommits()
        let nextHeld = Task { try await storage.commit([], context: .background) }
        await nextGate.waitUntilEntered()
        // Releasing the old gate must not clear a replacement gate.
        await crashedGate.release()
        #expect(try await held.value == Seq(2))
        await nextGate.release()
        #expect(try await nextHeld.value == Seq(3))
        #expect(await storage.admittedCommits == [[], [], []])
        #expect(await storage.commits == [[], [], []])
    }
}
