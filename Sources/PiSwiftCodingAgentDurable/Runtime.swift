import Foundation
import PiSwiftAI
import PiSwiftChord
import PiSwiftCodingAgent
import PiSwiftDurable
import Synchronization

/// An open durable session. Call close() to release its resources and session lock.
public final class OpenDurableResult: Sendable {
    /// The plain view. Its listeners run once per burst of changes on a private serial queue.
    public let view: any DurableViewSource
    /// Commands for the shown conversation. Failures appear as view notices.
    public let controller: any DurableController
    /// The loaded settings, also available to a host for theme and terminal setup.
    public let settings: SettingsManager
    private let runtime: DurableRuntime
    private let commands: RuntimeController
    private let closing = Mutex<Task<Void, Never>?>(nil)

    fileprivate init(view: RuntimeViewSource, controller: RuntimeController,
                     settings: SettingsManager, runtime: DurableRuntime) {
        self.view = view
        self.controller = controller
        self.settings = settings
        self.runtime = runtime
        commands = controller
    }

    /// Closes once. Concurrent and later calls wait for the same close operation.
    public func close() async {
        let task = closing.withLock { closing in
            if let closing { return closing }
            commands.seal()
            let task = Task { await runtime.close() }
            closing = task
            return task
        }
        await task.value
    }
}

/// Opens a durable coding session and starts restored work after view setup.
/// A new session uses the loaded default model and thinking level.
/// A continued session keeps its saved agent configuration.
/// The agent directory supplies settings, credentials, models, and the session root.
/// Throws on setup or session selection failure. Failed setup releases its resources.
/// Call `close()` on the result to release storage, environments, and the session lock.
/// This function uses local execution environments. It has no environment override.
public func openDurable(_ options: OpenDurableOptions = .init()) async throws -> OpenDurableResult {
    try await openDurable(options, dependencies: .live)
}

/// The test seam replaces model loading, the catalog, and initial-model selection.
internal struct DurableRuntimeModels: Sendable {
    let models: any DurableModels
    let available: [Model]
    let initial: @Sendable (SettingsManager) async -> InitialAgentModel
}

/// The agent directory also controls session, settings, auth, and prompt resource paths.
internal struct OpenDurableDependencies: Sendable {
    let agentDirectory: String
    let makeModels: @Sendable (String) async throws -> DurableRuntimeModels

    static var live: Self {
        Self(agentDirectory: getAgentDir(), makeModels: { directory in
            let registry = discoverModels(authStorage: discoverAuthStorage(agentDir: directory), agentDir: directory)
            let adapter = await RegistryDurableModels.create(registry: registry)
            return DurableRuntimeModels(models: adapter, available: adapter.getAvailableSnapshot(), initial: {
                await findInitialAgentModel(settingsManager: $0, registry: registry)
            })
        })
    }
}

internal func openDurable(_ options: OpenDurableOptions,
                          dependencies: OpenDurableDependencies) async throws -> OpenDurableResult {
    let location = try await selectSession(options.cwd ?? FileManager.default.currentDirectoryPath,
                                           continueSession: options.continueSession,
                                           agentDirectory: dependencies.agentDirectory)
    let envs = ExecutionEnvs(defaultCwd: location.cwd)
    var storage: SqliteStorage?
    var harness: Harness?
    var runtime: DurableRuntime?
    do {
        let models = try await dependencies.makeModels(dependencies.agentDirectory)
        let manager = SettingsManager.create(location.cwd, dependencies.agentDirectory)
        let settings = harnessSettings(from: manager)
        let registry = try createCodingRegistry(settingsManager: manager, cwd: location.cwd,
                                                 agentDirectory: dependencies.agentDirectory)
        try registry.install(try subagentExtension())
        let reports = RuntimeReports()
        let sqlite = try await SqliteStorage.open(path: location.database)
        storage = sqlite
        let opened = try await Harness.open(storage: sqlite,
            options: HarnessOptions(models: models.models, registry: registry, settings: settings,
                                    env: envs.factory, onReport: { reports.report($0) }), context: .background)
        harness = opened
        let initial = location.created ? await models.initial(manager) : nil
        let root = try await opened.root(options: .init(agent: AgentChange(
            model: initial?.model.map { .set($0) } ?? .unchanged,
            thinkingLevel: initial?.thinkingLevel.map { .set($0) } ?? .unchanged,
            cwd: .set(location.cwd))), context: .background)
        let summaries = try await runtimeSummaries(opened)
        let attached = try await root.viewState(context: .background)
        let source = RuntimeViewSource(DurableView(
            session: .init(id: location.id, directory: location.directory, cwd: location.cwd),
            conversation: attached.value, conversations: summaries,
            models: models.available.map {
                ModelSummary(provider: $0.provider, modelId: $0.id, name: $0.name, contextWindow: $0.contextWindow)
            }))
        let live = DurableRuntime(harness: opened, envs: envs, location: location,
                                  models: models.models, source: source, current: root, conversation: attached)
        runtime = live
        try await live.attach()
        reports.attach(source)
        let controller = RuntimeController(runtime: live, source: source)
        let saved = agentOf(source.current().conversation).model
        if let saved {
            if models.models.getModel(provider: saved.provider, modelId: saved.modelId) == nil {
                source.notice(.warning, "Saved model is unavailable: \(saved.provider)/\(saved.modelId)")
            }
        } else {
            source.notice(.warning, "No model configured; select one with /model.")
        }
        if let message = initial?.fallbackMessage { source.notice(.info, message) }
        await controller.toggleTasks()
        try opened.resume()
        return OpenDurableResult(view: source, controller: controller, settings: manager, runtime: live)
    } catch {
        let openedRuntime = runtime
        let openedHarness = harness
        let openedStorage = storage
        // Opening can be cancelled. Cleanup must finish before the lock is released.
        await Task {
            if let openedRuntime {
                await openedRuntime.close()
            } else {
                if let openedHarness { try? await openedHarness.close(context: .background) }
                else { try? await openedStorage?.close(context: .background) }
                await envs.cleanup(context: .background)
                location.release()
            }
        }.value
        throw error
    }
}

private func runtimeSummaries(_ harness: Harness) async throws -> [ConversationSummary] {
    var summaries: [ConversationSummary] = []
    var cursor: Cursor?
    repeat {
        let pageCursor = cursor
        let page = try await harness.commit({ tx in
            try await tx.scanConversations(.init(), limit: 256, cursor: pageCursor)
        }, context: .background)
        for record in page.items {
            var title: String?
            if record.id != rootConversationID,
               let conversation = try await harness.conversation(id: record.id, context: .background) {
                var entriesCursor: Cursor?
                var first: EntryRecord?
                repeat {
                    let entries = try await conversation.entries(limit: 256, cursor: entriesCursor, context: .background)
                    first = entries.items.last { $0.kind == "pi.user" } ?? first
                    entriesCursor = entries.next
                } while entriesCursor != nil
                title = first.flatMap { runtimeTitle(of: $0) }
            }
            summaries.append(.init(id: record.id,
                label: record.id == rootConversationID ? "main" : "subagent \(record.id.rawValue)", title: title))
        }
        cursor = page.next
    } while cursor != nil
    return summaries
}

/// Admission is synchronous under this lock. Each operation waits for its predecessor.
private final class RuntimeController: DurableController {
    private struct Queue: Sendable {
        var tail: Task<Void, Never>?
        var sealed = false
    }
    private let queue = Mutex(Queue())
    private let runtime: DurableRuntime
    private let source: RuntimeViewSource
    init(runtime: DurableRuntime, source: RuntimeViewSource) { self.runtime = runtime; self.source = source }
    func seal() { queue.withLock { $0.sealed = true } }
    private func command(_ operation: @escaping @Sendable (DurableRuntime) async throws -> Void) async {
        let task = queue.withLock { queue -> Task<Void, Never>? in
            guard !queue.sealed else { return nil }
            let previous = queue.tail
            let task = Task {
                await previous?.value
                do { try await operation(runtime) }
                catch { source.fail(error) }
            }
            queue.tail = task
            return task
        }
        await task?.value
    }
    func submit(_ text: String, whenBusy: SubmitWhenBusy) async {
        await command { try await $0.submit(text, whenBusy: whenBusy) }
    }
    func compact(instructions: String?) async { await command { try await $0.compact(instructions: instructions) } }
    func abort() async {
        do { try await runtime.abort() }
        catch { source.fail(error) }
    }
    func cycleThinking() async { await command { try await $0.cycleThinking() } }
    func setModel(_ model: ModelRef) async { await command { try await $0.setModel(model) } }
    func toggleTasks() async { await command { try await $0.toggleTasks() } }
    func switchConversation(_ id: ConversationID) async { await command { try await $0.switchConversation(id) } }
}

private actor DurableRuntime {
    let harness: Harness
    let envs: ExecutionEnvs
    let location: SessionLocation
    let models: any DurableModels
    let source: RuntimeViewSource
    var current: Conversation
    var conversation: AttachedReplicatedState<ConversationView>
    var conversationSubscription: ReplicatedStateSubscription?
    var commits: SessionSubscription?
    var tasks: AttachedReplicatedState<TaskGraph>?
    var taskSubscription: ReplicatedStateSubscription?
    var conversationGeneration = 0
    var taskGeneration = 0
    var watches: [UUID: Task<Void, Never>] = [:]
    var closed = false

    init(harness: Harness, envs: ExecutionEnvs, location: SessionLocation,
         models: any DurableModels, source: RuntimeViewSource, current: Conversation,
         conversation: AttachedReplicatedState<ConversationView>) {
        self.harness = harness; self.envs = envs; self.location = location
        self.models = models; self.source = source; self.current = current; self.conversation = conversation
    }
    func attach() throws {
        attachConversation()
        commits = try harness.subscribeCommits { [source] publication, _ in source.record(publication) }
    }
    private func assertOpen() throws {
        if closed { throw SessionError.message("Durable session is closed") }
    }
    private func attachConversation() {
        let generation = conversationGeneration
        let state = conversation
        source.updateConversation(state.value)
        conversationSubscription = state.subscribe { [weak self] _, _, _ in
            await self?.receiveConversation(state, generation: generation)
        }
    }
    private func receiveConversation(_ state: AttachedReplicatedState<ConversationView>, generation: Int) {
        guard !closed, generation == conversationGeneration else { return }
        source.updateConversation(state.value)
    }
    private func receiveTasks(_ graph: AttachedReplicatedState<TaskGraph>, generation: Int) {
        guard !closed, generation == taskGeneration else { return }
        source.updateTasks(graph.value)
    }
    func submit(_ text: String, whenBusy: SubmitWhenBusy) async throws {
        try assertOpen()
        let submission = try await current.submit(.input(content: .text(text),
            whenBusy: whenBusy == .steer ? .steer : .followUp), context: .background)
        watch { [source] in
            if let message = try runtimeUnansweredNotice(await submission.wait(context: .background)) {
                source.notice(.error, message)
            }
        }
    }
    private func watch(_ operation: @escaping @Sendable () async throws -> Void) {
        guard !closed else { return }
        let id = UUID()
        watches[id] = Task { [weak self] in
            do { try await operation() }
            catch { await self?.watchFailed(error) }
            await self?.watchFinished(id)
        }
    }
    private func watchFailed(_ error: any Error) { if !closed { source.fail(error) } }
    private func watchFinished(_ id: UUID) { watches.removeValue(forKey: id) }
    func compact(instructions: String?) async throws {
        try assertOpen()
        let id = try await current.compact(instructions: instructions, context: .background)
        watch { [harness, source] in
            let receipt = try await harness.waitForTask(id: id, context: .background)
            var status: String?
            if case .completed(let result, _) = receipt.outcome,
               let submissionId = try result.decode(CompactionResult.self).submissionId,
               let submission = try await harness.submission(id: submissionId, context: .background) {
                status = try await submission.status(context: .background).status
            }
            let notice = try runtimeCompactionNotice(receipt.outcome, submissionStatus: status)
            source.notice(notice.level, notice.message)
        }
    }
    func abort() async throws { try assertOpen(); try await current.abort(context: .background) }
    private func agentModel() throws -> Model {
        guard let ref = agentOf(conversation.value).model else { throw SessionError.message("No model selected") }
        guard let model = models.getModel(provider: ref.provider, modelId: ref.modelId) else {
            throw SessionError.message("Current model is unavailable")
        }
        return model
    }
    func cycleThinking() async throws {
        try assertOpen()
        let model = try agentModel()
        guard model.reasoning else { throw SessionError.message("Current model does not support thinking") }
        let levels = getSupportedThinkingLevels(model)
        let level = agentOf(conversation.value).thinkingLevel ?? .off
        let index = levels.firstIndex(of: level).map { $0 + 1 } ?? 0
        let next = levels.isEmpty ? .off : levels[index % levels.count]
        try await current.configure(change: .init(thinkingLevel: .set(next)), context: .background)
        source.updateConversation(conversation.value)
    }
    func setModel(_ ref: ModelRef) async throws {
        try assertOpen()
        guard let model = models.getModel(provider: ref.provider, modelId: ref.modelId) else {
            throw SessionError.message("Unknown model: \(ref.provider)/\(ref.modelId)")
        }
        let level = agentOf(conversation.value).thinkingLevel ?? .off
        try await current.configure(change: .init(model: .set(ref),
            thinkingLevel: .set(clampThinkingLevel(model: model, requested: level))), context: .background)
        source.updateConversation(conversation.value)
    }
    func toggleTasks() async throws {
        try assertOpen()
        if tasks != nil { closeTasks(); source.updateTasks(nil); return }
        let graph = try await harness.taskGraph(context: .background)
        guard !closed else { graph.dispose(); return }
        tasks = graph
        let generation = taskGeneration
        source.updateTasks(graph.value)
        taskSubscription = graph.subscribe { [weak self] _, _, _ in
            await self?.receiveTasks(graph, generation: generation)
        }
    }
    private func closeTasks() {
        taskGeneration += 1
        taskSubscription?.cancel(); taskSubscription = nil
        tasks?.dispose(); tasks = nil
    }
    func switchConversation(_ id: ConversationID) async throws {
        try assertOpen()
        guard let next = try await harness.conversation(id: id, context: .background) else {
            throw SessionError.message("Conversation \(id.rawValue) does not exist")
        }
        let nextState = try await next.viewState(context: .background)
        guard !closed else { nextState.dispose(); return }
        conversationGeneration += 1
        conversationSubscription?.cancel()
        conversation.dispose()
        current = next; conversation = nextState
        attachConversation()
    }
    func close() async {
        guard !closed else { return }
        closed = true
        conversationGeneration += 1
        conversationSubscription?.cancel(); conversationSubscription = nil
        commits?.cancel(); commits = nil
        conversation.dispose()
        closeTasks()
        let pending = Array(watches.values)
        for task in pending { task.cancel() }
        do { try await harness.close(context: .background) }
        catch { source.fail(error) }
        await envs.cleanup(context: .background)
        location.release()
        for task in pending { await task.value }
        source.finish()
    }
}

internal func runtimeUnansweredNotice(_ settled: SettledSubmission) throws -> String? {
    let reason: String
    let detail: JSONValue?
    switch settled.record {
    case .input(_, _, _, .unanswered(let value, _, let data, _)),
         .write(_, _, _, .unanswered(let value, let data, _)):
        reason = value; detail = data
    default: return nil
    }
    guard reason != "aborted" else { return nil }
    return "No answer: \(reason)" + (try detail.map { " " + (try $0.jsonText()) } ?? "")
}

internal func runtimeCompactionNotice(_ outcome: TaskOutcome, submissionStatus: String?) throws
    -> (level: Notice.Level, message: String) {
    switch outcome {
    case .completed(let value, _):
        let result = try value.decode(CompactionResult.self)
        let message: String
        if result.entryId != nil || submissionStatus == "done" { message = "Compacted." }
        else if submissionStatus == "queued" { message = "Compaction summary queued; it is placed at the next turn boundary." }
        else if submissionStatus == "unanswered" { message = "Compaction summary dropped: the context changed under it." }
        else { message = "Nothing to compact: the context fits in the recent window that is kept verbatim." }
        return (.info, message)
    case .aborted: return (.info, "Compaction aborted.")
    case .failed(let error, _, _), .faulted(let error, _):
        return (.error, "Compaction \(outcome.status): \(error.message)")
    case .orphaned(let reason, _): return (.error, "Compaction orphaned: \(reason)")
    }
}
