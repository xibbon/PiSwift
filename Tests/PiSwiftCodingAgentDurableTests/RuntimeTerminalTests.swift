import Darwin
import Foundation
import PiSwiftAI
import PiSwiftChord
@testable import PiSwiftCodingAgentDurable
import PiSwiftDurable
import PiSwiftDurableTesting
import Synchronization
import Testing

private final class HostFailure: Error, Sendable, LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

private struct HostDirectory: Sendable {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent("host-terminal-" + UUID().uuidString)
    var cwd: String { base.appendingPathComponent("cwd").path }
    var realCwd: String { URL(fileURLWithPath: cwd).resolvingSymlinksInPath().path }
    var agent: String { base.appendingPathComponent("agent").path }
    init() throws {
        try FileManager.default.createDirectory(atPath: cwd, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: agent, withIntermediateDirectories: true)
        try Data("{\"retry\":{\"enabled\":false},\"compaction\":{\"enabled\":false}}".utf8)
            .write(to: URL(fileURLWithPath: agent).appendingPathComponent("settings.json"))
    }
    func remove() { try? FileManager.default.removeItem(at: base) }
    func dependencies(models: FakeDurableModels, storage: HostFailureStorage,
                      envs: ExecutionEnvs) -> OpenDurableDependencies {
        .init(agentDirectory: agent, makeModels: { _ in
            .init(models: models, available: models.models, initial: { _ in
                .init(model: .init(provider: "faux", modelId: "faux-1"))
            })
        }, makeStorage: { _ in storage }, makeEnvs: { _ in envs })
    }
}

@Suite(.timeLimit(.minutes(1))) struct RuntimeTerminalTests {
    @Test func backendFailureClosesTheHostWithoutAnExplicitClose() async throws {
        let directory = try HostDirectory()
        defer { directory.remove() }
        let original = HostFailure("The backend failed")
        let storage = HostFailureStorage(closeFailure: HostFailure("A later close failed"))
        let model = HarnessGatedResponse(message: chatAssistant("answer"))
        let models = FakeDurableModels(responses: [model.step])
        let cleanupReached = HarnessChatSignal(), cleanupRelease = HarnessChatSignal()
        let cleanups = Mutex<[String]>([])
        let envs = ExecutionEnvs(defaultCwd: directory.realCwd, cleanup: { env, context in
            cleanups.withLock { $0.append(env.cwd) }
            cleanupReached.signal()
            await cleanupRelease.wait()
            await env.cleanup(context: context)
        })
        let result = try await openDurable(.init(cwd: directory.cwd), dependencies:
            directory.dependencies(models: models, storage: storage, envs: envs))
        await result.controller.submit("start", whenBusy: .steer)
        try await eventually { model.reached.isSignalled }
        storage.failNextCommit(original)
        model.release()
        // No close call or terminal wait starts cleanup in this test.
        do { try await eventually { cleanupReached.isSignalled } }
        catch { cleanupRelease.signal(); await result.close(); throw error }
        #expect((result.failure as? HostFailure) === original)
        #expect(result.view.current().terminal == .failed(message: original.message))
        let commits = storage.commitCount
        let snapshot = result.view.current()
        await result.controller.submit("rejected", whenBusy: .steer)
        await result.controller.toggleTasks()
        await result.controller.abort()
        #expect(storage.commitCount == commits)
        #expect(result.view.current() == snapshot)
        let descriptor = open(snapshot.session.directory + "/session.lock", O_RDWR)
        #expect(descriptor >= 0)
        if descriptor >= 0 {
            #expect(flock(descriptor, LOCK_EX | LOCK_NB) == -1)
            #expect(errno == EWOULDBLOCK)
            _ = Darwin.close(descriptor)
        }
        let closing = settled { await result.close() }
        let terminal = Task { await result.closed }
        terminal.cancel()
        #expect(!closing.isSettled)
        cleanupRelease.signal()
        guard case .failed(let cause) = await terminal.value else {
            Issue.record("Expected the first backend failure")
            await result.close()
            return
        }
        #expect((cause as? HostFailure) === original)
        await result.close()
        try await eventually { closing.isSettled }
        #expect(cleanups.withLock { $0 } == [snapshot.session.cwd])
        #expect(storage.closeCount == 1)
        #expect(result.view.current().notices.filter { $0.level == .error }.map(\.message) == [original.message])
        let reopened = try await selectSession(directory.cwd, continueSession: true, agentDirectory: directory.agent)
        reopened.release()
    }

    @Test func commandFailureShowsOneCauseAndReleasesTheLock() async throws {
        let directory = try HostDirectory()
        defer { directory.remove() }
        let storage = HostFailureStorage()
        let original = HostFailure("Cannot commit the input")
        let envs = ExecutionEnvs(defaultCwd: directory.cwd)
        let result = try await openDurable(.init(cwd: directory.cwd), dependencies:
            directory.dependencies(models: FakeDurableModels(), storage: storage, envs: envs))
        storage.failNextCommit(original)
        await result.controller.submit("fail", whenBusy: .steer)
        guard case .failed(let cause) = await result.closed else {
            Issue.record("Expected the command to fail the session")
            await result.close()
            return
        }
        #expect((cause as? HostFailure) === original)
        #expect(result.view.current().terminal == .failed(message: original.message))
        #expect(result.view.current().notices.filter { $0.level == .error }.map(\.message) == [original.message])
        await result.close()
        #expect(storage.closeCount == 1)
        let reopened = try await selectSession(directory.cwd, continueSession: true, agentDirectory: directory.agent)
        reopened.release()
    }

    @Test func normalCloseHasAPublicTerminalResult() async throws {
        let directory = try HostDirectory()
        defer { directory.remove() }
        let storage = HostFailureStorage()
        let envs = ExecutionEnvs(defaultCwd: directory.cwd)
        let result = try await openDurable(.init(cwd: directory.cwd), dependencies:
            directory.dependencies(models: FakeDurableModels(), storage: storage, envs: envs))
        async let first: Void = result.close()
        async let second: Void = result.close()
        _ = await (first, second)
        guard case .closed = await result.closed else { Issue.record("Expected a normal close"); return }
        #expect(result.failure == nil)
        #expect(result.view.current().terminal == .closed)
        #expect(storage.closeCount == 1)
    }
}

private func terminalView() -> DurableView {
    .init(session: .init(id: "session", directory: "/session", cwd: "/project"),
          conversation: .init(conversation: .init(id: rootConversationID), entries: [], docs: [:]),
          conversations: [.init(id: rootConversationID, label: "main")], models: [])
}

@Test func terminalViewKeepsItsFirstCauseThroughUpdatesAndCoding() throws {
    let source = RuntimeViewSource(terminalView(), schedule: { _ in })
    source.terminate(.failed(HostFailure("First cause")))
    source.terminate(.failed(HostFailure("Later cause")))
    source.terminate(.closed)
    source.updateConversation(terminalView().conversation)
    source.updateTasks(TaskGraph())
    source.record(.init(seq: try Seq(1), changes: []))
    source.notice(.info, "A notice")
    #expect(source.current().terminal == .failed(message: "First cause"))
    #expect(source.current().notices.filter { $0.level == .error }.map(\.message) == ["First cause"])
    let data = try JSONEncoder().encode(source.current())
    #expect(try JSONDecoder().decode(DurableView.self, from: data) == source.current())
    var old = try JSONValue(encoding: terminalView()).objectValue ?? [:]
    old.removeValue(forKey: "terminal")
    #expect(try JSONValue.object(old).decode(DurableView.self).terminal == nil)
}

@Test func terminalFinishDeliversTheFinalSnapshotOnTheListenerQueue() {
    let scheduled = Mutex<[@Sendable () -> Void]>([])
    let source = RuntimeViewSource(terminalView(), schedule: { callback in
        scheduled.withLock { $0.append(callback) }
    })
    let seen = Mutex<[DurableSessionTerminal?]>([])
    let subscription = source.subscribe { seen.withLock { $0.append(source.current().terminal) } }
    source.terminate(.failed(HostFailure("Backend stopped")))
    source.finish(deliverFinal: true)
    let callbacks = scheduled.withLock { $0 }
    #expect(seen.withLock { $0.isEmpty })
    for callback in callbacks { callback() }
    #expect(seen.withLock { $0 } == [.failed(message: "Backend stopped")])
    source.notice(.error, "After close")
    #expect(source.current().notices.map(\.message) == ["Backend stopped"])
    subscription.cancel()
}
