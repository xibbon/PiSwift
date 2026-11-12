import PiSwiftAI
import PiSwiftChord

/// One trailing partial write at a time. Stop joins the in-flight write before classification.
private actor GenerationPartialThrottle {
    let runtime: TaskRuntime
    let attempt: Int
    let thinkingLevel: ModelThinkingLevel?
    let interval: Int64
    let context: ChordContext
    let changes = PartialChanges()
    var pending: AssistantMessage?
    var timer: Task<Void, Never>?
    var inFlight: Task<Void, Never>?
    var stopped = false
    init(runtime: TaskRuntime, attempt: Int, thinkingLevel: ModelThinkingLevel?, context: ChordContext) {
        self.runtime = runtime; self.attempt = attempt; self.thinkingLevel = thinkingLevel; self.context = context
        interval = runtime.settings.progress.partialIntervalMs
    }
    func offer(_ incoming: AssistantMessage, event: AssistantMessageEvent) async {
        var message = incoming
        if let thinkingLevel { message.thinkingLevel = thinkingLevel }
        guard !stopped, !message.content.isEmpty else { return }
        await changes.observe(event)
        pending = message
        schedule()
    }
    private func schedule() {
        guard !stopped, timer == nil, inFlight == nil, pending != nil else { return }
        let clock = InvocationClock(runtime: runtime)
        let deadline = clock.now() + interval
        timer = Task {
            do {
                repeat { try await clock.sleep(until: deadline) } while clock.now() < deadline
            } catch { return }
            flush()
        }
    }
    private func flush() {
        timer = nil
        guard !stopped, pending != nil else { return }
        pending = nil
        let runtime = self.runtime, attempt = self.attempt, context = self.context, changes = self.changes
        inFlight = Task {
            var taken: PartialCommit?
            do {
                guard let batch = try await changes.takeLatest() else { finished(); return }
                taken = batch.commit
                try await runtime.commit({ tx, _ in
                    let live = try await tx.doc(LiveDoc, conversationId: runtime.conversationId)
                    if try live.child("generation") == nil { try live.set("generation", .object(["attempt": .number(Double(attempt))])) }
                    try await changes.commit(live.child("generation")!, message: batch.message, taken: batch.commit)
                    return nil
                }, context: context)
            } catch {
                if let taken { await changes.restore(taken) }
                if !runtime.signal.aborted { runtime.reportTaskError(error) }
            }
            finished()
        }
    }
    private func finished() { inFlight = nil; schedule() }
    func stop() async {
        stopped = true; timer?.cancel(); timer = nil
        let write = inFlight
        await write?.value
        pending = nil
    }
}
func streamGeneration(runtime: TaskRuntime, model: Model, messages: [Message], options: SimpleStreamOptions,
                      attempt: Int, thinkingLevel: ModelThinkingLevel?, context: ChordContext) async throws -> AssistantMessage {
    let throttle = GenerationPartialThrottle(runtime: runtime, attempt: attempt, thinkingLevel: thinkingLevel, context: context)
    do {
        let events = try runtime.generationModels().streamSimple(model: model, context: PiSwiftAI.Context(messages: messages), options: options)
        for await event in events {
            let partial: AssistantMessage?
            switch event {
            case .done, .error: partial = nil
            case .start(let message), .textStart(_, let message), .textDelta(_, _, let message), .textEnd(_, _, let message),
                 .thinkingStart(_, let message), .thinkingDelta(_, _, let message), .thinkingEnd(_, _, let message),
                 .toolCallStart(_, let message), .toolCallDelta(_, _, let message), .toolCallEnd(_, _, let message): partial = message
            }
            if let partial { await throttle.offer(partial, event: event) }
        }
        let message = await events.result()
        await throttle.stop()
        return message
    } catch {
        await throttle.stop()
        throw error
    }
}
