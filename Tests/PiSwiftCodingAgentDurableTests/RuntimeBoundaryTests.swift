import Foundation
import PiSwiftAI
import PiSwiftChord
@testable import PiSwiftCodingAgentDurable
import PiSwiftDurable
import PiSwiftDurableTesting
import Testing

private struct BoundaryFailure: Error, Equatable { }

private struct BoundaryDirectory: Sendable {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent("runtime-boundary-" + UUID().uuidString)
    var cwd: String { base.appendingPathComponent("cwd").path }
    var agent: String { base.appendingPathComponent("agent").path }
    init() throws {
        try FileManager.default.createDirectory(atPath: cwd, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: agent, withIntermediateDirectories: true)
    }
    func remove() { try? FileManager.default.removeItem(at: base) }
    func dependencies(_ models: FakeDurableModels) -> OpenDurableDependencies {
        .init(agentDirectory: agent, makeModels: { _ in
            .init(models: models, available: models.models, initial: { _ in
                .init(model: .init(provider: "faux", modelId: "faux-1"))
            })
        })
    }
}

@Suite(.timeLimit(.minutes(1))) struct RuntimeBoundaryTests {
    @Test func modelSetupFailureReleasesTheSessionLock() async throws {
        let directory = try BoundaryDirectory()
        defer { directory.remove() }
        let dependencies = OpenDurableDependencies(agentDirectory: directory.agent, makeModels: { _ in throw BoundaryFailure() })
        await #expect(throws: BoundaryFailure.self) {
            try await openDurable(.init(cwd: directory.cwd), dependencies: dependencies)
        }
        let location = try await selectSession(directory.cwd, continueSession: true, agentDirectory: directory.agent)
        #expect(!location.created)
        location.release()
    }

    @Test func cancelledOpeningClosesSQLiteBeforeReleasingTheLock() async throws {
        let directory = try BoundaryDirectory()
        defer { directory.remove() }
        let models = FakeDurableModels()
        let reached = HarnessChatSignal(), release = HarnessChatSignal()
        let dependencies = OpenDurableDependencies(agentDirectory: directory.agent, makeModels: { _ in
            .init(models: models, available: models.models, initial: { _ in
                reached.signal()
                await release.wait()
                return .init(model: .init(provider: "faux", modelId: "faux-1"))
            })
        })
        let opening = Task { try await openDurable(.init(cwd: directory.cwd), dependencies: dependencies) }
        try await eventually { reached.isSignalled }
        opening.cancel()
        release.signal()
        await #expect(throws: CancellationError.self) { try await opening.value }
        // A new SQLite handle must open at once after cancelled setup is fully closed.
        let result = try await openDurable(.init(cwd: directory.cwd, continueSession: true),
                                           dependencies: directory.dependencies(models))
        #expect(result.view.current().conversation.conversation.id == rootConversationID)
        await result.close()
    }

    @Test func startupScansAllConversationAndEntryPages() async throws {
        let directory = try BoundaryDirectory()
        defer { directory.remove() }
        let models = FakeDurableModels()
        let location = try await selectSession(directory.cwd, continueSession: false, agentDirectory: directory.agent)
        let harness = try await Harness.open(storage: SqliteStorage.open(path: location.database),
            options: .init(models: models, registry: createRegistry()), context: .background)
        let root = try await harness.root(context: .background)
        let firstChild = try await harness.commit({ tx in
            var first: ConversationID?
            for index in 0..<257 {
                let child = try await tx.createConversation(ownership: .ownerless())
                if index == 0 {
                    first = child.id
                    for message in 0..<260 {
                        _ = try await tx.appendEntry(child.id, value: EntryDraft(kind: "pi.user", model: [
                            .object(["role": .string("user"), "content": .string(message == 0 ? "  oldest\n task  " : "later \(message)")])
                        ]))
                    }
                }
            }
            return first
        }, context: .background)
        #expect(root.id == rootConversationID)
        try await harness.close(context: .background)
        location.release()
        let result = try await openDurable(.init(cwd: directory.cwd, continueSession: true),
                                           dependencies: directory.dependencies(models))
        #expect(result.view.current().conversations.count == 258)
        #expect(result.view.current().conversations.first { $0.id == firstChild }?.title == "oldest task")
        await result.close()
    }

    @Test func concurrentCloseCallsWaitForOneCloseAndRejectLaterCommands() async throws {
        let directory = try BoundaryDirectory()
        defer { directory.remove() }
        let hold = HarnessUnanswered()
        let models = FakeDurableModels(responses: [hold.step])
        let result = try await openDurable(.init(cwd: directory.cwd), dependencies: directory.dependencies(models))
        await result.controller.submit("hold", whenBusy: .steer)
        try await eventually { hold.reached.isSignalled }
        async let first: Void = result.close()
        async let second: Void = result.close()
        _ = await (first, second)
        let snapshot = result.view.current()
        await result.controller.toggleTasks()
        await result.controller.submit("closed", whenBusy: .steer)
        #expect(result.view.current() == snapshot)
        let location = try await selectSession(directory.cwd, continueSession: true, agentDirectory: directory.agent)
        location.release()
    }

    @Test func compactionTerminalErrorsUseTheUpstreamText() throws {
        let fault = try runtimeCompactionNotice(.faulted(error: .init(message: "broken")), submissionStatus: nil)
        #expect(fault.level == .error)
        #expect(fault.message == "Compaction faulted: broken")
        let orphan = try runtimeCompactionNotice(.orphaned(reason: "missing definition"), submissionStatus: nil)
        #expect(orphan.level == .error)
        #expect(orphan.message == "Compaction orphaned: missing definition")
        let done = try runtimeCompactionNotice(.completed(result: JSONValue(encoding: CompactionResult(submissionId: SubmissionID(2)))), submissionStatus: "done")
        #expect(done.level == .info)
        #expect(done.message == "Compacted.")
        #expect(throws: (any Error).self) {
            try runtimeCompactionNotice(.completed(result: .string("invalid result")), submissionStatus: nil)
        }
    }
}
