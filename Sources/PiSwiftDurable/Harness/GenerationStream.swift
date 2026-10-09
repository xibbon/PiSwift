import PiSwiftAI
import PiSwiftChord

/// One trailing partial write at a time. Stop joins the in-flight write before classification.
private actor GenerationPartialThrottle {
    let runtime: TaskRuntime
    let attempt: Int
    let interval: Int64
    let context: PiSwiftChord.Context
    var pending: JSONValue?
    var timer: Task<Void, Never>?
    var inFlight: Task<Void, Never>?
    var stopped = false
    init(runtime: TaskRuntime, attempt: Int, context: PiSwiftChord.Context) {
        self.runtime = runtime; self.attempt = attempt; self.context = context
        interval = runtime.settings.progress.partialIntervalMs
    }
    func offer(_ message: AssistantMessage) throws {
        guard !stopped, !message.content.isEmpty else { return }
        pending = try EntryRecord.encodeMessages([.assistant(message)])[0]
        schedule()
    }
    private func schedule() {
        guard !stopped, timer == nil, inFlight == nil, pending != nil else { return }
        let deadline = runtime.scheduler.clock.now() + interval
        timer = Task {
            do { try await runtime.scheduler.clock.sleep(until: deadline) } catch { return }
            flush()
        }
    }
    private func flush() {
        timer = nil
        guard !stopped, let partial = pending else { return }
        pending = nil
        let runtime = self.runtime, attempt = self.attempt, context = self.context
        inFlight = Task {
            do {
                try await runtime.commit({ tx, _ in
                    let live = try await tx.doc(LiveDoc, conversationId: runtime.conversationId)
                    if try live.child("generation") == nil { try live.set("generation", .object(["attempt": .number(Double(attempt))])) }
                    try assignJSON(target: live.child("generation")!, key: "message", value: partial)
                    return nil
                }, context: context)
            } catch { if !runtime.signal.aborted { runtime.scheduler.report(error) } }
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
                      attempt: Int, context: PiSwiftChord.Context) async throws -> AssistantMessage {
    let throttle = GenerationPartialThrottle(runtime: runtime, attempt: attempt, context: context)
    do {
        let events = runtime.models.streamSimple(model: model, context: PiSwiftAI.Context(messages: messages), options: options)
        for await event in events {
            let partial: AssistantMessage?
            switch event {
            case .done, .error: partial = nil
            case .start(let message), .textStart(_, let message), .textDelta(_, _, let message), .textEnd(_, _, let message),
                 .thinkingStart(_, let message), .thinkingDelta(_, _, let message), .thinkingEnd(_, _, let message),
                 .toolCallStart(_, let message), .toolCallDelta(_, _, let message), .toolCallEnd(_, _, let message): partial = message
            }
            if let partial { try await throttle.offer(partial) }
        }
        let message = await events.result()
        await throttle.stop()
        return message
    } catch {
        await throttle.stop()
        throw error
    }
}
