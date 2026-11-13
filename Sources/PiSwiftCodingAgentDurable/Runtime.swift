import Foundation
import PiSwiftAI
import PiSwiftChord
import PiSwiftCodingAgent
import PiSwiftDurable
import PiSwiftDurableJSC
import Synchronization

/// An open durable session. Call close() to release its resources and session lock.
/// A storage failure also closes the session and releases its resources.
public final class OpenDurableResult: Sendable {
    /// The plain view. Its listeners run once per burst of changes on a private serial queue.
    @available(*, deprecated, message: "Use hostView for paged transcript and typed run state")
    public let view: any DurableViewSource
    /// Paged rows, live state, and reports for a new UI.
    public let hostView: any DurableHostViewSource
    /// Commands for the shown conversation. Failures appear as view notices.
    @available(*, deprecated, message: "Use hostController for continue and transcript commands")
    public let controller: any DurableController
    public let hostController: any DurableHostController
    /// The loaded settings, also available to a host for theme and terminal setup.
    public let settings: SettingsManager
    /// The first storage failure, if one has occurred.
    public var failure: (any Error)? { runtime.harness.failure }
    /// Waits for the final result and for environment and session lock cleanup.
    /// Cancellation of this wait does not cancel cleanup.
    public var closed: SessionCloseResult {
        get async { await runtime.waitUntilClosed() }
    }
    private let runtime: DurableRuntime
    private let commands: RuntimeController
    private let closing = Mutex<Task<Void, Never>?>(nil)
    private let options: OpenDurableOptions
    private let dependencies: OpenDurableDependencies
    private let sessionID: String

    fileprivate init(view: RuntimeViewSource, controller: RuntimeController,
                     settings: SettingsManager, runtime: DurableRuntime,
                     options: OpenDurableOptions, dependencies: OpenDurableDependencies,
                     sessionID: String) {
        self.view = view
        self.hostView = view
        self.controller = controller
        self.hostController = controller
        self.settings = settings
        self.runtime = runtime
        commands = controller
        self.options = options
        self.dependencies = dependencies
        self.sessionID = sessionID
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

    /// Closes and stores held progress before the application is suspended.
    public func prepareForSuspension() async { await close() }

    /// Reopens a read-only snapshot. The previous snapshot is closed first.
    public func refresh() async throws -> OpenDurableResult {
        guard options.mode == .readOnly else { throw SessionError.message("Refresh requires a read-only open") }
        let retained = hostView.hostCurrent().transcript
        await close()
        let exact = OpenDurableOptions(cwd: options.cwd, continueSession: true, mode: .readOnly,
                                       transcriptMode: options.transcriptMode, storageKind: options.storageKind,
                                       sessionID: sessionID)
        return try await openDurable(exact, dependencies: dependencies, retained: retained)
    }

    /// Admits an input and the caller's entries in one storage commit.
    /// Returns the durable submission ID. A run result arrives through hostView.
    public func submitAtomically(_ text: String, whenBusy: SubmitWhenBusy,
                                 writes: [EntryDraft], requestId: String? = nil) async throws -> SubmissionID {
        try await runtime.submitAtomically(text, whenBusy: whenBusy, writes: writes, requestId: requestId)
    }

    /// Continues an idle conversation; throws ConversationBusy when active.
    public func continueRun() async throws { try await runtime.submitContinue() }
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

/// Opens the bounded transcript API without reading old pages at startup.
public func openDurablePaged(cwd: String? = nil, continueSession: Bool = false,
                             mode: DurableOpenMode = .write,
                             storageKind: DurableStorageKind = .sqlite) async throws -> OpenDurableResult {
    try await openDurable(.init(cwd: cwd, continueSession: continueSession,
                                mode: mode, transcriptMode: .paged, storageKind: storageKind))
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
    let makeStorage: @Sendable (String) async throws -> any DurableStorage
    let makeEnvs: @Sendable (String) -> ExecutionEnvs
    let clock: any DurableClock
    let registry: (any RegistryReader)?
    let modelsProvider: HarnessModelsProvider?

    init(agentDirectory: String,
         makeModels: @escaping @Sendable (String) async throws -> DurableRuntimeModels,
         makeStorage: @escaping @Sendable (String) async throws -> any DurableStorage = {
             try await SqliteStorage.open(path: $0)
         },
         makeEnvs: @escaping @Sendable (String) -> ExecutionEnvs = { ExecutionEnvs(defaultCwd: $0) },
         clock: any DurableClock = SystemDurableClock(),
         registry: (any RegistryReader)? = nil,
         modelsProvider: HarnessModelsProvider? = nil) {
        self.agentDirectory = agentDirectory
        self.makeModels = makeModels
        self.makeStorage = makeStorage
        self.makeEnvs = makeEnvs
        self.clock = clock
        self.registry = registry
        self.modelsProvider = modelsProvider
    }

    static var live: Self {
        Self(agentDirectory: getAgentDir(), makeModels: { directory in
            let registry = discoverModels(authStorage: discoverAuthStorage(agentDir: directory), agentDir: directory)
            let adapter = await RegistryCodemodeModels.create(registry: registry)
            return DurableRuntimeModels(models: adapter, available: adapter.getAvailableSnapshot(), initial: {
                await findInitialAgentModel(settingsManager: $0, registry: registry)
            })
        })
    }
}

internal func openDurable(_ options: OpenDurableOptions,
                          dependencies: OpenDurableDependencies,
                          retained: TranscriptView? = nil) async throws -> OpenDurableResult {
    if options.mode == .readOnly && !options.continueSession {
        throw SessionError.message("Read-only open requires an existing session")
    }
    let location = try await selectSession(options.cwd ?? FileManager.default.currentDirectoryPath,
                                           continueSession: options.continueSession,
                                           agentDirectory: dependencies.agentDirectory,
                                           acquireLock: options.mode == .write,
                                           sessionID: options.sessionID)
    let envs = dependencies.makeEnvs(location.cwd)
    let sandbox = JSCCodemodeSandbox()
    var storage: (any DurableStorage)?
    var harness: Harness?
    var runtime: DurableRuntime?
    do {
        let models = try await dependencies.makeModels(dependencies.agentDirectory)
        let manager = SettingsManager.create(location.cwd, dependencies.agentDirectory)
        let settings = harnessSettings(from: manager)
        let reports = RuntimeReports()
        let registry: any RegistryReader
        if let override = dependencies.registry { registry = override }
        else {
            registry = try createCodingRegistry(settingsManager: manager, cwd: location.cwd,
                                                 agentDirectory: dependencies.agentDirectory,
                                                 sandbox: sandbox, onReport: { error, info in reports.report(error, info: info) })
        }
        let selectedStorage: any DurableStorage
        switch options.storageKind {
        case .sqlite: selectedStorage = try await dependencies.makeStorage(location.database)
        case .jsonl:
            selectedStorage = try await JsonlStorage.open(directory: location.directory,
                options: .init(readOnly: options.mode == .readOnly), context: .background)
        }
        storage = selectedStorage
        let opened = try await Harness.open(storage: selectedStorage,
            options: HarnessOptions(models: { try dependencies.modelsProvider?() ?? models.models },
                                    registry: registry, identity: getCodingAgentClientIdentity(manager),
                                    readOnly: options.mode == .readOnly, settings: settings,
                                    env: envs.factory, clock: dependencies.clock,
                                    onReport: { (report: Report) in reports.report(report) }), context: .background)
        harness = opened
        let initial = location.created ? await models.initial(manager) : nil
        let root: Conversation
        if options.mode == .readOnly {
            guard let existing = try await opened.conversation(id: rootConversationID, context: .background) else {
                throw SessionError.message("Root conversation is absent")
            }
            root = existing
        } else {
            root = try await opened.root(options: .init(agent: AgentChange(
                model: initial?.model.map { .set($0) } ?? .unchanged,
                thinkingLevel: initial?.thinkingLevel.map { .set($0) } ?? .unchanged,
                cwd: .set(location.cwd))), context: .background)
        }
        let summaries = try await runtimeSummaries(opened)
        // v1.5.2 CH3: Durable's view source is now a Chord Watch (harness/view.ts:200-218).
        let attached = try await root.watch(context: .background)
        let transcript = try ConversationTranscript({ query, limit, context in
            try await root.entries(query: query, limit: limit, context: context)
        })
        if let retained, retained.conversation.id == root.id {
            try await restoreTranscript(retained, into: transcript)
        }
        let transcriptView = try await transcript.merge(attached.value)
        // v1.5.2 D4: the library watch is bounded (harness/view.ts:277-299).
        // Until D10 adds transcript paging to the host, seed the existing full display from pages.
        let displayed = options.transcriptMode == .compatibility
            ? try await runtimeFullConversationView(root, window: attached.value) : attached.value
        let source = RuntimeViewSource(DurableView(
            session: .init(id: location.id, directory: location.directory, cwd: location.cwd),
            conversation: displayed, conversations: summaries,
            models: models.available.map {
                ModelSummary(provider: $0.provider, modelId: $0.id, name: $0.name, contextWindow: $0.contextWindow)
            }), transcript: transcriptView, openMode: options.mode, transcriptMode: options.transcriptMode)
        let live = DurableRuntime(harness: opened, envs: envs, location: location,
                                  sandbox: sandbox, models: models.models, source: source,
                                  current: root, conversation: attached, transcript: transcript,
                                  transcriptMode: options.transcriptMode, openMode: options.mode)
        runtime = live
        try await live.attach()
        reports.attach(source)
        let controller = RuntimeController(runtime: live, source: source)
        await live.observeTermination { [weak controller] in controller?.seal() }
        let saved = try decodeAgentOf(source.current().conversation).model
        if let saved {
            if models.models.getModel(provider: saved.provider, modelId: saved.modelId) == nil {
                source.notice(.warning, "Saved model is unavailable: \(saved.provider)/\(saved.modelId)")
            }
        } else {
            source.notice(.warning, "No model configured; select one with /model.")
        }
        if let message = initial?.fallbackMessage { source.notice(.info, message) }
        await controller.toggleTasks()
        if options.mode == .write { try opened.resume() }
        return OpenDurableResult(view: source, controller: controller, settings: manager,
                                 runtime: live, options: options, dependencies: dependencies,
                                 sessionID: location.id)
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
                await sandbox.close()
                await envs.cleanup(context: .background)
                location.release()
            }
        }.value
        throw error
    }
}

/// Replays only ranges the previous viewer held; each gap remains uncovered.
private func restoreTranscript(_ previous: TranscriptView, into transcript: ConversationTranscript) async throws {
    var group: [EntryRecord] = []
    var needsEarlier = false
    func mergeGroup(_ group: [EntryRecord], needsEarlier: Bool) async throws {
        guard let first = group.first else { return }
        let before = needsEarlier ? try EntryID(max(0, first.id.rawValue - 1)) : nil
        _ = try await transcript.merge(.init(conversation: previous.conversation,
                                             entries: group, before: before, docs: previous.docs))
    }
    for item in previous.items {
        switch item {
        case .earlier: needsEarlier = true
        case .gap:
            try await mergeGroup(group, needsEarlier: needsEarlier)
            group = []
            needsEarlier = true
        case .entry(let entry): group.append(entry)
        }
    }
    try await mergeGroup(group, needsEarlier: needsEarlier)
}

/// Seeds this host's existing full transcript display from storage pages.
private func runtimeFullConversationView(_ conversation: Conversation, window: ConversationView) async throws -> ConversationView {
    var entries: [EntryRecord] = []
    var cursor: Cursor?
    repeat {
        let page = try await conversation.entries(limit: 256, cursor: cursor, context: .background)
        entries += page.items
        cursor = page.next
    } while cursor != nil
    entries.reverse()
    return ConversationView(conversation: window.conversation, entries: entries, docs: window.docs)
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
                    let entries = try await conversation.entries(order: .ascending, limit: 256,
                                                                 cursor: entriesCursor, context: .background)
                    first = entries.items.first { runtimeTitle(of: $0) != nil }
                    entriesCursor = entries.next
                } while entriesCursor != nil && first == nil
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
private final class RuntimeController: DurableHostController {
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
            guard !queue.sealed, runtime.harness.failure == nil else { return nil }
            let previous = queue.tail
            let task = Task {
                await previous?.value
                do { try await operation(runtime) }
                catch { report(error) }
            }
            queue.tail = task
            return task
        }
        await task?.value
    }
    func submit(_ text: String, whenBusy: SubmitWhenBusy) async {
        await command { try await $0.submit(text, whenBusy: whenBusy) }
    }
    func continueRun() async { await command { try await $0.submitContinue() } }
    func loadEarlier() async { await command { try await $0.loadEarlier() } }
    func fillGap(_ gap: TranscriptGap) async { await command { try await $0.fillGap(gap) } }
    func setMaxTurns(_ value: Int?) async { await command { try await $0.setMaxTurns(value) } }
    func setCompactionPolicy(_ value: CompactionPolicyOverrides?) async {
        await command { try await $0.setCompactionPolicy(value) }
    }
    func compact(instructions: String?) async { await command { try await $0.compact(instructions: instructions) } }
    func abort() async {
        guard queue.withLock({ !$0.sealed }), runtime.harness.failure == nil else { return }
        do { try await runtime.abort() }
        catch { report(error) }
    }
    func abortTask(_ id: TaskID) async {
        guard queue.withLock({ !$0.sealed }), runtime.harness.failure == nil else { return }
        do { try await runtime.abortTask(id) }
        catch { report(error) }
    }
    private func report(_ error: any Error) {
        if let cause = runtime.harness.failure {
            seal()
            source.terminate(.failed(cause))
        } else { source.fail(error) }
    }
    func cycleThinking() async { await command { try await $0.cycleThinking() } }
    func setModel(_ model: ModelRef) async { await command { try await $0.setModel(model) } }
    func toggleTasks() async { await command { try await $0.toggleTasks() } }
    func switchConversation(_ id: ConversationID) async { await command { try await $0.switchConversation(id) } }
}

private actor DurableRuntime {
    let harness: Harness
    let envs: ExecutionEnvs
    let sandbox: JSCCodemodeSandbox
    let location: SessionLocation
    let models: any DurableModels
    let source: RuntimeViewSource
    var current: Conversation
    var conversation: ConversationWatch
    var transcript: ConversationTranscript
    let transcriptMode: DurableTranscriptMode
    let openMode: DurableOpenMode
    var commits: CommitObservation?
    var tasks: TaskGraphWatch?
    var tasksVisible = false
    var conversationGeneration = 0
    var taskGeneration = 0
    var watches: [UUID: Task<Void, Never>] = [:]
    var closed = false
    var closing: Task<Void, Never>?
    var terminalObserver: Task<Void, Never>?

    init(harness: Harness, envs: ExecutionEnvs, location: SessionLocation,
         sandbox: JSCCodemodeSandbox, models: any DurableModels, source: RuntimeViewSource, current: Conversation,
         conversation: ConversationWatch, transcript: ConversationTranscript,
         transcriptMode: DurableTranscriptMode, openMode: DurableOpenMode) {
        self.harness = harness; self.envs = envs; self.location = location
        self.sandbox = sandbox
        self.models = models; self.source = source; self.current = current; self.conversation = conversation
        self.transcript = transcript; self.transcriptMode = transcriptMode; self.openMode = openMode
    }
    func attach() async throws {
        try await attachConversation()
        // v1.5.2 CH3: The task graph also emits tagged Chord Watch calls (harness/task-graph.ts:272).
        let graph = try await harness.watchTaskGraph(context: .background)
        guard !closed else { _ = await graph.stop(); return }
        tasks = graph
        commits = try harness.observeCommits(CommitObserver(
            // The graph watch is the single source of graph state. A commit callback
            // can run after a newer watch delivery while `graph.value` is older.
            advance: { [source] publication, _ in source.record(publication) },
            end: { _ in }))
        for node in graph.value.tasks.values.sorted(by: { $0.id < $1.id }) {
            if let record = try await harness.getTask(id: node.id, context: .background) {
                source.recordRestarts(record)
            }
        }
        source.updateTasks(graph.value, visible: tasksVisible)
        let generation = taskGeneration
        try graph.start { [weak self] call, _ in
            await self?.receiveTasks(call, generation: generation)
        }
    }
    func observeTermination(seal: @escaping @Sendable () -> Void) {
        terminalObserver = Task { [weak self, harness] in
            let result = await harness.closed
            seal()
            await self?.backendClosed(result)
        }
    }
    private func backendClosed(_ result: SessionCloseResult) async {
        source.terminate(result)
        await close()
    }
    func waitUntilClosed() async -> SessionCloseResult {
        let result = await harness.closed
        await backendClosed(result)
        return result
    }
    private func assertOpen() throws {
        if let failure = harness.failure { throw SessionFailed(failure) }
        if closed { throw SessionError.message("Durable session is closed") }
    }
    private func assertWritable() throws {
        try assertOpen()
        if openMode == .readOnly { throw ReadOnlySession("running tasks") }
    }
    private func attachConversation() async throws {
        let generation = conversationGeneration
        let state = conversation
        source.updateConversation(state.value, transcript: try await transcript.merge(state.value))
        try state.start { [weak self] call, _ in
            await self?.receiveConversation(call, generation: generation)
        }
    }
    private func receiveConversation(_ call: WatchCall<ConversationView>, generation: Int) async {
        guard !closed, generation == conversationGeneration else { return }
        if case .value(let value, _, _) = call {
            do {
                let merged = try await transcript.merge(value)
                guard !closed, generation == conversationGeneration else { return }
                source.updateConversation(value, transcript: merged)
            } catch { source.fail(error) }
        }
    }
    private func receiveTasks(_ call: WatchCall<TaskGraph>, generation: Int) {
        guard !closed, generation == taskGeneration else { return }
        if case .value(let value, _, _) = call { source.updateTasks(value, visible: tasksVisible) }
    }
    func submit(_ text: String, whenBusy: SubmitWhenBusy) async throws {
        try assertWritable()
        let submission = try await current.submit(.input(content: .text(text),
            whenBusy: whenBusy == .steer ? .steer : .followUp), context: .background)
        if transcriptMode == .compatibility {
            watch { [source] in
                if let message = try runtimeUnansweredNotice(await submission.wait(context: .background)) {
                    source.unanswered(message)
                }
            }
        }
    }
    func submitAtomically(_ text: String, whenBusy: SubmitWhenBusy,
                          writes: [EntryDraft], requestId: String?) async throws -> SubmissionID {
        try assertWritable()
        let conversation = current
        let id = try await conversation.commit({ tx in
            let id = try await conversation.submit(tx, .input(content: .text(text),
                whenBusy: whenBusy == .steer ? .steer : .followUp, requestId: requestId))
            for write in writes { _ = try await tx.appendEntry(conversation.id, value: write) }
            return id
        }, context: .background)
        return id
    }
    /// Admit a context continuation while the conversation is idle.
    func submitContinue() async throws {
        try assertWritable()
        let submission = try await current.submit(.continue(), context: .background)
        if transcriptMode == .compatibility {
            watch { [source] in
                if let message = try runtimeUnansweredNotice(await submission.wait(context: .background)) {
                    source.unanswered(message)
                }
            }
        }
    }
    func loadEarlier() async throws {
        try assertOpen()
        source.updateTranscript(try await transcript.loadEarlier(context: .background))
    }
    func fillGap(_ gap: TranscriptGap) async throws {
        try assertOpen()
        source.updateTranscript(try await transcript.fillGap(gap, context: .background))
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
    private func watchFailed(_ error: any Error) {
        guard !closed else { return }
        if let cause = harness.failure { source.terminate(.failed(cause)) }
        else { source.fail(error) }
    }
    private func watchFinished(_ id: UUID) { watches.removeValue(forKey: id) }
    func compact(instructions: String?) async throws {
        try assertWritable()
        let id = try await current.compact(instructions: instructions, context: .background)
        let watched = conversation
        let transcript = transcript
        watch { [harness, source] in
            let receipt = try await harness.waitForTask(id: id, context: .background)
            var status: String?
            if case .completed(let result, _) = receipt.outcome,
               let submissionId = try result.decode(CompactionResult.self).submissionId,
               let submission = try await harness.submission(id: submissionId, context: .background) {
                status = try await submission.status(context: .background).status
            }
            let notice = try runtimeCompactionNotice(receipt.outcome, submissionStatus: status)
            // The receipt can resume before the watch handler publishes the same commit.
            // Publish that value with the notice so the UI sees its entry or inbox state.
            let value = watched.value
            if source.current().conversation.conversation.id == value.conversation.id {
                source.updateConversation(value, transcript: try await transcript.merge(value))
            }
            source.notice(notice.level, notice.message)
        }
    }
    func abort() async throws { try assertWritable(); try await current.abort(context: .background) }
    func abortTask(_ id: TaskID) async throws {
        try assertWritable()
        _ = try await harness.abortTask(id: id, context: .background)
    }
    private func agentModel() throws -> Model {
        guard let ref = try decodeAgentOf(conversation.value).model else { throw SessionError.message("No model selected") }
        guard let model = models.getModel(provider: ref.provider, modelId: ref.modelId) else {
            throw SessionError.message("Current model is unavailable")
        }
        return model
    }
    func cycleThinking() async throws {
        try assertWritable()
        let model = try agentModel()
        guard model.reasoning else { throw SessionError.message("Current model does not support thinking") }
        let levels = getSupportedThinkingLevels(model)
        let level = try decodeAgentOf(conversation.value).thinkingLevel ?? .off
        let index = levels.firstIndex(of: level).map { $0 + 1 } ?? 0
        let next = levels.isEmpty ? .off : levels[index % levels.count]
        try await current.configure(change: .init(thinkingLevel: .set(next)), context: .background)
        source.updateConversation(conversation.value)
    }
    func setModel(_ ref: ModelRef) async throws {
        try assertWritable()
        guard let model = models.getModel(provider: ref.provider, modelId: ref.modelId) else {
            throw SessionError.message("Unknown model: \(ref.provider)/\(ref.modelId)")
        }
        let level = try decodeAgentOf(conversation.value).thinkingLevel ?? .off
        try await current.configure(change: .init(model: .set(ref),
            thinkingLevel: .set(clampThinkingLevel(model: model, requested: level))), context: .background)
        source.updateConversation(conversation.value)
    }
    func setMaxTurns(_ value: Int?) async throws {
        try assertWritable()
        if let value, value < 1 { throw SessionError.message("maxTurns must be at least 1") }
        try await current.configure(change: .init(maxTurns: value.map { .set($0) } ?? .clear),
                                    context: .background)
    }
    func setCompactionPolicy(_ value: CompactionPolicyOverrides?) async throws {
        try assertWritable()
        try await current.configure(change: .init(compaction: value.map { .set($0) } ?? .clear),
                                    context: .background)
    }
    func toggleTasks() async throws {
        try assertOpen()
        tasksVisible.toggle()
        source.updateTasks(tasks?.value, visible: tasksVisible)
    }
    private func closeTasks() async {
        taskGeneration += 1
        if let tasks { _ = await tasks.stop() }
        tasks = nil
    }
    func switchConversation(_ id: ConversationID) async throws {
        try assertOpen()
        guard let next = try await harness.conversation(id: id, context: .background) else {
            throw SessionError.message("Conversation \(id.rawValue) does not exist")
        }
        let nextState = try await next.watch(context: .background)
        guard !closed else { _ = await nextState.stop(); return }
        let nextTranscript = try ConversationTranscript({ query, limit, context in
            try await next.entries(query: query, limit: limit, context: context)
        })
        let transcriptView = try await nextTranscript.merge(nextState.value)
        let displayed = transcriptMode == .compatibility
            ? try await runtimeFullConversationView(next, window: nextState.value) : nextState.value
        conversationGeneration += 1
        _ = await conversation.stop()
        current = next; conversation = nextState; transcript = nextTranscript
        source.replaceConversation(displayed, transcript: transcriptView)
        try await attachConversation()
    }
    func close() async {
        if let closing { await closing.value; return }
        closed = true
        conversationGeneration += 1
        commits?.detach(); commits = nil
        _ = await conversation.stop()
        await closeTasks()
        let pending = Array(watches.values)
        for task in pending { task.cancel() }
        let task = Task { await self.finishClose(pending: pending) }
        closing = task
        await task.value
    }
    private func finishClose(pending: [Task<Void, Never>]) async {
        do { try await harness.close(context: .background) }
        catch { /* The terminal result retains the first storage failure. */ }
        source.terminate(await harness.closed)
        await sandbox.close()
        await envs.cleanup(context: .background)
        location.release()
        for task in pending { await task.value }
        source.finish(deliverFinal: true)
        terminalObserver = nil
    }
}

internal func runtimeUnansweredNotice(_ settled: SettledSubmission) throws -> String? {
    let reason: String
    let detail: JSONValue?
    switch settled.record {
    case .input(_, _, _, .unanswered(let value, _, let data, _)),
         .write(_, _, _, .unanswered(let value, let data, _)),
         .continue(_, _, _, .unanswered(let value, let data, _)):
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
