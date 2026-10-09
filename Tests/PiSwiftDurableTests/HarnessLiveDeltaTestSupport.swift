import Foundation
import Synchronization
import Testing
import PiSwiftAI
import PiSwiftChord
@testable import PiSwiftDurable
import PiSwiftDurableTesting

final class HarnessLiveDeltaLog: Sendable {
    private let state = Mutex<[(CommitPublication, [Delta.Op], JSONObject)]>([])
    var values: [(CommitPublication, [Delta.Op], JSONObject)] { state.withLock { $0 } }
    var commits: [[Delta.Op]] { values.map { $0.1 } }
    func append(_ publication: CommitPublication) {
        for change in publication.changes {
            if case .document(let document) = change, document.record.kind == "pi.live", !document.ops.isEmpty, let value = document.value {
                state.withLock { $0.append((publication, document.ops, value)) }
            }
        }
    }
}
struct HarnessLiveDeltaDriver: Sendable {
    typealias Action = @Sendable (ToolExecutionApi, ChordContext) async throws -> Bool
    let opened: OpenChatResult
    let input: Submission
    let log: HarnessLiveDeltaLog
    let clock: TestClock
    let queue: AsyncStream<Action>.Continuation
    let subscription: SessionSubscription
    static func open(limits: OutputLimitOverrides? = nil) async throws -> Self {
        let clock = TestClock(), setup = HarnessChatSetup(clock: clock), actions = AsyncStream<Action>.makeStream()
        try installHarnessTool(harnessTestTool("drive", limits: limits, execute: { _, api, context in
            let remove = context.abortSignal?.addAbortListener { _ in actions.continuation.finish() }
            defer { if let remove { context.abortSignal?.removeAbortListener(remove) } }
            for await action in actions.stream { if try await !action(api, context) { return .init(content: []) } }
            try context.abortSignal?.throwIfAborted(); return .init(content: [])
        }), setup: setup)
        setup.models.setResponses([.message(try toolCalls([("drive", [:], "c1")])), .message(chatAssistant("done"))])
        let opened = try await openChat(setup: setup), log = HarnessLiveDeltaLog()
        let subscription = try opened.harness.subscribeCommits { publication, _ in log.append(publication) }
        let input = try await generationSubmit(opened)
        try await eventually { try await generationLive(opened)?.tools?.first?.status == .running && log.commits.contains([.set(["tools", 0, "status"], "running")]) }
        return Self(opened: opened, input: input, log: log, clock: clock, queue: actions.continuation, subscription: subscription)
    }
    func step(_ action: @escaping @Sendable (ToolExecutionApi, ChordContext) async throws -> Void) async throws -> [Delta.Op] {
        let before = log.commits.count; clock.advance(by: 1_000_000)
        queue.yield { api, context in try await action(api, context); return true }
        try await eventually { self.log.commits.count > before }
        return log.commits.last!
    }
    func output(_ text: String) async throws -> [Delta.Op] { try await step { api, _ in try api.output(.text(text), nil) } }
    func finish() async throws -> [[Delta.Op]] {
        let before = log.commits.count; queue.yield { _, _ in false }
        _ = try await input.wait(context: .background); return Array(log.commits.dropFirst(before))
    }
    func close() async throws { subscription.cancel(); queue.finish(); try await opened.harness.close(context: .background) }
}
let liveDeltaOutputPath: Delta.Path = ["tools", 0, "output"]
func liveDeltaOutputOps(_ ops: [Delta.Op]) -> [Delta.Op] { ops.filter { $0.json[1] == ["tools", 0, "output"] } }
