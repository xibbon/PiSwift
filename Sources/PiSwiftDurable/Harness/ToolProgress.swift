import PiSwiftChord
import Synchronization

internal struct ToolReportSnapshot: Sendable {
    let output: BoundedOutput
    let details: JSONValue?
    let diagnostics: [ToolDiagnostic]
}
private final class ToolReported: Sendable {
    struct State: Sendable {
        var details: JSONValue?
        var diagnostics: [ToolDiagnostic] = []
        var ended = false
        var pendingDetails = 0
        var markQueued = false
    }
    let state = Mutex(State())
    let output: OutputBuffer
    init(_ limits: OutputLimits) { output = OutputBuffer(limits) }
    func snapshot() -> ToolReportSnapshot {
        state.withLock { ToolReportSnapshot(output: output.snapshot(), details: $0.details, diagnostics: $0.diagnostics) }
    }
}
private actor ToolProgressWriter {
    let runtime: TaskRuntime
    let reported: ToolReported
    let context: PiSwiftChord.Context
    var writtenText = ""
    var writtenDetails: JSONValue?
    var writtenDiagnostics = 0
    init(runtime: TaskRuntime, reported: ToolReported, context: PiSwiftChord.Context) {
        self.runtime = runtime; self.reported = reported; self.context = context
    }
    func write() async throws -> Int {
        let current = reported.snapshot()
        let added = Array(current.diagnostics.dropFirst(writtenDiagnostics))
        let detailsChanged = current.details != writtenDetails
        var bytes = 0
        if current.output.text != writtenText {
            let shared = current.output.text.hasPrefix(writtenText) ? writtenText.utf16.count : Delta.overlap(writtenText, current.output.text, scan: 65_536)
            bytes += utf8ByteLength(String(decoding: Array(current.output.text.utf16).dropFirst(shared), as: UTF16.self))
        }
        if detailsChanged { bytes += utf8ByteLength(try (current.details ?? .null).jsonText()) }
        if !added.isEmpty { bytes += utf8ByteLength(try JSONValue(encoding: added).jsonText()) }
        let runtime = self.runtime
        try await runtime.commit({ tx, _ in
            let live = try await tx.doc(LiveDoc, conversationId: runtime.conversationId)
            guard let slot = try toolSlot(live: live, taskId: runtime.taskId) else { return nil }
            if try slot.get("output")?.stringValue ?? "" != current.output.text { try slot.set("output", .string(current.output.text)) }
            if current.output.droppedBytes > 0 { try slot.set("droppedBytes", .number(Double(current.output.droppedBytes))) }
            if current.output.droppedLines > 0 { try slot.set("droppedLines", .number(Double(current.output.droppedLines))) }
            if detailsChanged, let details = current.details { try assignJSON(target: slot, key: "details", value: details) }
            if !added.isEmpty {
                if try slot.child("diagnostics") == nil { try slot.set("diagnostics", .array([])) }
                try slot.child("diagnostics")!.append(contentsOf: added.map { try JSONValue(encoding: $0) })
            }
            return nil
        }, context: context)
        writtenText = current.output.text; writtenDetails = current.details; writtenDiagnostics = current.diagnostics.count
        return bytes
    }
}
/// Orders synchronous reports and waiter registration before the stop barrier.
internal final class ToolReporter: Sendable {
    private enum Event: Sendable { case mark, waiter(ProgressWaiter) }
    let limits: OutputLimits
    private let reported: ToolReported
    private let lifetime: ToolInvocationLifetime
    private let events: AsyncStream<Event>.Continuation
    private let drain: Task<[ProgressWaiter], Never>
    init(runtime: TaskRuntime, lifetime: ToolInvocationLifetime, limits: OutputLimits, context: PiSwiftChord.Context) {
        self.limits = limits; self.lifetime = lifetime
        let reported = ToolReported(limits); self.reported = reported
        let writer = ToolProgressWriter(runtime: runtime, reported: reported, context: context)
        let progress = Progress(write: { try await writer.write() }, onError: { error in
            if !runtime.signal.aborted { runtime.scheduler.report(error) }
        }, minIntervalMs: runtime.settings.progress.outputIntervalMs, clock: runtime.scheduler.clock)
        let stream = AsyncStream<Event>.makeStream()
        events = stream.continuation
        drain = Task {
            for await event in stream.stream {
                switch event {
                case .mark:
                    reported.state.withLock { $0.markQueued = false }
                    await progress.mark()
                case .waiter(let waiter): await progress.mark(waiter: waiter)
                }
            }
            return await progress.stop()
        }
    }
    func output(_ chunk: ToolOutputChunk, skipped: ShellOutputSkip?) throws {
        try reported.state.withLock { state in
            try lifetime.check()
            let changed: Bool
            switch chunk {
            case .text(let text): changed = try reported.output.push(text, skipped: skipped)
            case .bytes(let bytes): changed = try reported.output.push(bytes, skipped: skipped)
            }
            if changed && !state.markQueued { state.markQueued = true; events.yield(.mark) }
        }
    }
    func diagnostic(_ value: ToolDiagnostic) throws {
        try reported.state.withLock { state in
            try lifetime.check(); _ = try JSONValue(encoding: value)
            state.diagnostics.append(value)
            if !state.markQueued { state.markQueued = true; events.yield(.mark) }
        }
    }
    func details(_ value: JSONValue, context: PiSwiftChord.Context) async throws {
        try context.abortSignal?.throwIfAborted()
        _ = try value.jsonText()
        let waits = Waiters<Int, Void>()
        let promise = try waits.add(0, context: context)
        do {
            try reported.state.withLock { state in
                try lifetime.check(); state.details = value; state.pendingDetails += 1
                events.yield(.waiter(ProgressWaiter(notify: { [reported] result in
                    reported.state.withLock { $0.pendingDetails -= 1 }
                    switch result {
                    case .success: waits.resolve(0, value: ())
                    case .failure(let error): waits.rejectAll(error)
                    }
                })))
            }
        } catch {
            waits.rejectAll(error)
            throw error
        }
        try await promise.value()
    }
    func snapshot() -> ToolReportSnapshot { reported.snapshot() }
    var pendingDetailsCount: Int { reported.state.withLock { $0.pendingDetails } }
    func stop() async -> [ProgressWaiter] {
        reported.state.withLock { state in
            if !state.ended {
                state.ended = true; lifetime.end(); reported.output.end(); events.finish()
            }
        }
        return await drain.value
    }
}
