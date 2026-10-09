import Testing
import Synchronization
import PiSwiftAI
import PiSwiftChord
@testable import PiSwiftDurable
import PiSwiftDurableTesting

let compactionManualPolicy = CompactionPolicy(enabled: false, reserveTokens: 1000, keepRecentTokens: 150, backgroundTokens: 0)

struct CompactionRequest: Sendable {
    let messages: [Message]
    let options: SimpleStreamOptions?
    let model: String
}

final class CompactionScript: Sendable {
    private struct State: Sendable {
        var agent: [FakeDurableResponseStep] = []
        var summaries: [FakeDurableResponseStep] = []
        var agentRequests: [CompactionRequest] = []
        var summaryRequests: [CompactionRequest] = []
    }
    private let state = Mutex(State())
    init(setup: HarnessChatSetup) {
        setup.models.setResponses((0..<500).map { _ in .factory { [self] transcript, options, usage, model in
            let request = CompactionRequest(messages: transcript.messages, options: options, model: model.id)
            let isSummary: Bool
            if case .system(let system)? = request.messages.first {
                isSummary = getSystemMessageText(system).hasPrefix("You are a context summarization assistant")
            } else { isSummary = false }
            let step = state.withLock { value -> FakeDurableResponseStep? in
                if isSummary {
                    value.summaryRequests.append(request)
                    return value.summaries.isEmpty ? nil : value.summaries.removeFirst()
                }
                value.agentRequests.append(request)
                return value.agent.isEmpty ? nil : value.agent.removeFirst()
            }
            guard let step else { throw TaskDefinitionError("No scripted \(isSummary ? "summary" : "agent") response") }
            switch step {
            case .message(let message): return message
            case .factory(let factory): return try await factory(transcript, options, usage, model)
            }
        } })
    }
    func appendAgent(_ steps: [FakeDurableResponseStep]) { state.withLock { $0.agent += steps } }
    func appendSummary(_ steps: [FakeDurableResponseStep]) { state.withLock { $0.summaries += steps } }
    var agentRequests: [CompactionRequest] { state.withLock { $0.agentRequests } }
    var summaryRequests: [CompactionRequest] { state.withLock { $0.summaryRequests } }
}

struct CompactionChat: Sendable {
    let harness: Harness
    let root: Conversation
    let setup: HarnessChatSetup
    let script: CompactionScript
    var opened: OpenChatResult { OpenChatResult(harness: harness, root: root) }
}

func compactionOpen(policy: CompactionPolicy = compactionManualPolicy, contextWindow: Int = 100_000,
                    storage: any DurableStorage = MemoryStorage(), clock: any DurableClock = TestClock(now: 1000),
                    setup supplied: HarnessChatSetup? = nil, script suppliedScript: CompactionScript? = nil,
                    resume: Bool = true) async throws -> CompactionChat {
    let setup = supplied ?? HarnessChatSetup(options: .init(models: [.init(id: "faux-1", contextWindow: contextWindow, maxTokens: 900)]), clock: clock)
    let script = suppliedScript ?? CompactionScript(setup: setup)
    if supplied == nil {
        try setup.registry.install(Extension(name: "compaction-preamble", sections: [section("preamble", tag: false) { _, _ in "You are helpful." }]))
    }
    let opened = try await openChat(storage: storage, setup: setup)
    setup.updateSettings { $0.stream = .init(cacheRetention: CacheRetention.none); $0.compaction = compactionOverrides(policy); $0.retry = .init(enabled: true, maxRetries: 2, baseDelayMs: 1) }
    if resume { try opened.harness.resume() }
    return CompactionChat(harness: opened.harness, root: opened.root, setup: setup, script: script)
}

func compactionText(_ label: String, _ tokens: Int) -> String {
    label + " " + String(repeating: "x", count: max(0, tokens * 4 - label.count - 1))
}
func compactionOverrides(_ policy: CompactionPolicy) -> CompactionPolicyOverrides {
    .init(enabled: policy.enabled, reserveTokens: policy.reserveTokens, keepRecentTokens: policy.keepRecentTokens, backgroundTokens: policy.backgroundTokens)
}
func compactionFailure(_ message: String) -> AssistantMessage { chatAssistant("", reason: .error, error: message) }
func compactionTurn(_ chat: CompactionChat, _ user: String, _ reply: String) async throws {
    chat.script.appendAgent([.message(chatAssistant(reply))])
    let submission = try await chat.root.submit(.input(content: .text(user)), context: .background)
    #expect(try await submission.wait(context: .background).status == "done")
}
func compactionHistory(_ chat: CompactionChat) async throws {
    for index in 1...3 { try await compactionTurn(chat, compactionText("u\(index)", 100), compactionText("a\(index)", 100)) }
}
func compactionOutcome(_ chat: CompactionChat, _ id: TaskID) async throws -> TaskOutcome {
    try await chat.harness.waitForTask(id: id, context: .background).outcome
}
func compactionSubmission(_ chat: CompactionChat, _ outcome: TaskOutcome) async throws -> Submission {
    guard case .completed(let result, _) = outcome else { throw TaskDefinitionError("Compaction did not complete: \(outcome.status)") }
    let value = try #require(result["submissionId"])
    let id = try value.decode(SubmissionID.self)
    return try #require(await chat.harness.submission(id: id, context: .background))
}
func compactionKinds(_ conversation: Conversation) async throws -> [String] { try await allEntries(conversation).map(\.kind) }
func compactionLive(_ chat: CompactionChat) async throws -> LiveState { try await generationLive(chat.opened) ?? LiveState() }
func compactionFirstUser(_ messages: [Message]) -> String { textOf(messages.first { $0.role == "user" }) ?? "" }
func compactionInputUsage(_ chat: CompactionChat) async throws -> Int {
    try await chat.harness.snapshot(UsageDoc, conversationId: chat.root.id, context: .background)?.models["faux/faux-1"]?.input ?? 0
}
func compactionAdvanceRetry(_ chat: CompactionChat, _ clock: TestClock) async throws {
    try await eventually { try await compactionLive(chat).compactions?.contains { $0.retry != nil } == true }
    clock.advance(by: 100_000)
}

// Test access to the flat upstream submission fields.
extension SubmissionRecord {
    var reason: String? {
        switch self {
        case .input(_, _, _, .unanswered(let reason, _, _, _)), .write(_, _, _, .unanswered(let reason, _, _)): return reason
        default: return nil
        }
    }
}
extension SettledSubmission {
    var entry: EntryID? {
        if case .write(_, _, _, .done(let entry, _)) = record { return entry }
        return nil
    }
}
