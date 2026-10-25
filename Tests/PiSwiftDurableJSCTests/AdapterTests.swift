import Foundation
import Synchronization
import Testing
import PiSwiftChord
import PiSwiftDurable
import PiSwiftCodemodeRuntime
@testable import PiSwiftDurableJSC

private let adapterPNG = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=="
private let adapterStart = 1_768_471_200_000.0
private final class AdapterLog: Sendable {
    struct State: Sendable {
        var calls: [CodemodeHostCall] = []
        var idles: [[Int]] = []
        var events: [String] = []
        var fingerprint = ""
        var seq = 0
    }
    let state = Mutex(State())
    var value: State { state.withLock { $0 } }
}
private func adapterWait(_ condition: @Sendable () async -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(10))
    while !(await condition()) {
        guard ContinuousClock.now < deadline else {
            throw CodemodeError(kind: .sandbox, message: "Test condition did not complete")
        }
        try await Task.sleep(for: .milliseconds(1))
    }
}
private func adapterRun(_ code: String, watchdog: Bool, seed: UInt32 = 1, startedAt: Double = adapterStart,
                        tools: [CodemodeDeclaredTool] = [.init(name: "echo"), .init(name: "wait")],
                        globals: [CodemodeDeclaredGlobal] = [], store: JSONObject = [:],
                        answer: @escaping @Sendable (CodemodeHostCall) -> CodemodeOutcome = { .success($0.args) }) async throws -> (any CodemodeRun, AdapterLog) {
    let log = AdapterLog()
    let run = try await JSCCodemodeSandbox(forceWatchdog: watchdog).start(source: code, name: "adapter-case.js", options: .init(
        startedAt: startedAt, seed: seed, tools: tools, globals: globals, store: store, timeoutMs: 10_000,
        onStarted: { fingerprint, _ in
            log.state.withLock { $0.fingerprint = fingerprint; $0.events.append("started") }
        }, onCall: { call, run in
            let seq = log.state.withLock { state in
                state.calls.append(call); state.events.append("call \(call.id)")
                if call.name == "wait" { return Optional<Int>.none }
                state.seq += 1; return state.seq
            }
            if let seq {
                do { try await run.deliver(seq: seq, now: startedAt + Double(seq) * 1000, id: call.id, outcome: answer(call)) }
                catch { Issue.record("Delivery failed: \(error)") }
            }
        }, onIdle: { seq, issued, _ in
            log.state.withLock { $0.idles.append([seq, issued]); $0.events.append("idle \(seq)") }
        }))
    return (run, log)
}
private func adapterTimeless(_ input: CodemodeResult) -> CodemodeResult {
    var result = input
    result.calls = input.calls.map { .init(name: $0.name, status: $0.status) }
    return result
}

@Suite(.serialized, .timeLimit(.minutes(1)))
struct CodemodeAdapterTests {
    // E10 appendix / deterministic.test.ts:108.
    @Test(arguments: [false, true]) func sameStartHasSameCallsAndJavaScriptOutput(_ watchdog: Bool) async throws {
        let code = """
        const first = await tools.echo([Date.now(), performance.now(), Math.random(), Math.random(), new Date().toISOString()]);
        text(JSON.stringify([Date.now(), performance.now(), Math.random()]));
        return await tools.echo(first.concat(Math.random()));
        """
        let (one, a) = try await adapterRun(code, watchdog: watchdog)
        let (two, b) = try await adapterRun(code, watchdog: watchdog)
        #expect(adapterTimeless(await one.result) == adapterTimeless(await two.result))
        #expect(a.value.calls == b.value.calls)
        #expect(a.value.calls[0].args?[0] == .number(adapterStart))
        #expect(a.value.calls[0].args?[1] == 0)
        #expect(a.value.calls[0].args?[2] == .number(0.6270739405881613))
        #expect(a.value.calls[0].args?[4] == "2026-01-15T10:00:00.000Z")
        let result = await one.result
        let text = { if case .text(let text, _) = result.output[0] { return text }; return "null" }()
        let printed = try JSONValue(jsonText: text)
        #expect(printed[0] == .number(adapterStart + 1000))
        #expect(printed[1] == 1000)
        let (later, laterLog) = try await adapterRun(code, watchdog: watchdog, startedAt: adapterStart + 5000)
        let (other, otherLog) = try await adapterRun(code, watchdog: watchdog, seed: 2)
        _ = await later.result; _ = await other.result
        #expect(laterLog.value.calls[0].args?[2] == a.value.calls[0].args?[2])
        #expect(otherLog.value.calls[0].args?[2] != a.value.calls[0].args?[2])
        let (zero, _) = try await adapterRun("return [Math.random(), Math.random()]", watchdog: watchdog, seed: 0)
        #expect(await zero.result.value == [0.26642920868471265, 0.0003297457005828619])
    }

    // :148. Avoid a process-wide TZ mutation; explicit local constructors must use UTC.
    @Test(arguments: [false, true]) func UTCDateAndNoWeakGlobals(_ watchdog: Bool) async throws {
        let (run, _) = try await adapterRun("return [new Date(0).getHours(), new Date(0).getTimezoneOffset(), typeof WeakRef, typeof FinalizationRegistry, new Date(2026,0,15,10).toISOString()]", watchdog: watchdog)
        #expect(await run.result.value == [0, 0, "undefined", "undefined", "2026-01-15T10:00:00.000Z"])
    }

    // :159 and369. Model a transport that delays result 1 past result 2.
    @Test(arguments: [false, true]) func outOfOrderDeliveryOrdersPromiseContinuations(_ watchdog: Bool) async throws {
        let (run, log) = try await adapterRun("const order=[]; await Promise.all([tools.wait('a').then(()=>order.push('a')),tools.wait('b').then(()=>order.push('b'))]); return order", watchdog: watchdog)
        try await adapterWait { log.value.idles.count == 1 }
        try await run.deliver(seq: 2, now: adapterStart + 2000, id: 1, outcome: .success(.null))
        try await run.deliver(seq: 1, now: adapterStart + 1000, id: 2, outcome: .success(.null))
        #expect(await run.result.value == ["b", "a"])
        #expect(log.value.idles == [[0, 2], [1, 2]])
        #expect(await run.result.during == .init(seq: 2, issued: 2))
        #expect(await run.result.calls.map(\.status) == [.ok, .ok])
    }

    // :369. The host sends 1 then 2, but a transport delays 1 at the boundary.
    @Test(arguments: [false, true]) func delayedTransportPreservesSentSequence(_ watchdog: Bool) async throws {
        let (run, log) = try await adapterRun("const order=[];await Promise.all([tools.wait('a').then(v=>order.push(v)),tools.wait('b').then(v=>order.push(v))]);return order", watchdog: watchdog)
        try await adapterWait { log.value.idles.count == 1 }
        let (release, gate) = AsyncStream<Void>.makeStream()
        defer { gate.finish() }
        let delayed = Task {
            for await _ in release {}
            try await Task.sleep(for: .milliseconds(30))
            try await run.deliver(seq: 1, now: adapterStart + 1000, id: 1, outcome: .success("a"))
        }
        try await run.deliver(seq: 2, now: adapterStart + 2000, id: 2, outcome: .success("b"))
        // A later accepted reply cannot resume its promise before the missing reply.
        #expect(await !run.finished)
        gate.finish()
        try await delayed.value
        #expect(await run.result.value == ["a", "b"])
    }

    // :180. JSC fingerprints identify the engine and interruption configuration.
    @Test(arguments: [false, true]) func fingerprintPrecedesEffectsAndIdleCountsAreExact(_ watchdog: Bool) async throws {
        let (run, log) = try await adapterRun("await tools.echo(1); await Promise.all([tools.echo(2),tools.echo(3)])", watchdog: watchdog)
        #expect(await run.result.ok)
        #expect(Array(log.value.events.prefix(3)) == ["started", "call 1", "idle 0"])
        #expect(log.value.idles == [[0, 1], [1, 3], [2, 3]])
        #expect(log.value.fingerprint.hasPrefix("JavaScriptCore "))
        #expect(log.value.fingerprint.contains("scheduler 1, seed mulberry32-v1"))
        let (same, sameLog) = try await adapterRun("return 1", watchdog: watchdog, seed: 7)
        _ = await same.result
        #expect(sameLog.value.fingerprint == log.value.fingerprint)
        let (other, otherLog) = try await adapterRun("return 1", watchdog: !watchdog)
        _ = await other.result
        #if os(macOS)
        #expect(otherLog.value.fingerprint != log.value.fingerprint)
        #endif
    }

    // :209 and275. A rejection must keep Error identity and own JSON properties.
    @Test(arguments: [false, true]) func globalsShareIDsAndErrorsHaveOwnProperties(_ watchdog: Bool) async throws {
        let (run, log) = try await adapterRun("""
        const found = await search('x',2);
        try { await tools.echo('fail'); } catch(e) {
          text(e.message);
          return [found,e instanceof Error,e.name,e.message,e.structuredOutput,Object.hasOwn(e,'__proto__'),e.__proto__,e.constructor,Object.getPrototypeOf(e)===Error.prototype];
        }
        """, watchdog: watchdog, globals: [.init(name: "search", spread: true)], answer: { call in
            call.target == .global ? .success(["found"]) : .failure(message: "denied", properties: [
                "name": "Fake", "message": "replace", "stack": "replace", "structuredOutput": ["code": 7], "__proto__": ["safe": true], "constructor": "own"])
        })
        #expect(await run.result.value == [["found"], true, "Error", "denied", ["code": 7], true, ["safe": true], "own", true])
        #expect(log.value.calls[0] == .init(id: 1, target: .global, name: "search", args: ["x", 2]))
        #expect(log.value.calls[1].id == 2)
        #expect(await run.result.calls.map(\.status) == [.error])
        #expect(await run.result.output == [.text("denied")])
    }

    // :236,263,353. Invalid deliveries leave both the call and sequence usable.
    @Test(arguments: [false, true]) func invalidDeliveryDoesNotConsumeWaitingCall(_ watchdog: Bool) async throws {
        let (run, log) = try await adapterRun("const before=Date.now(); await tools.wait(1); return [before,Date.now(),performance.now()]", watchdog: watchdog)
        try await adapterWait { log.value.calls.count == 1 }
        await #expect(throws: CodemodeProtocolError.invalidClock) { try await run.deliver(seq: 1, now: .nan, id: 1, outcome: .success(nil)) }
        await #expect(throws: CodemodeProtocolError.invalidSequence(0)) { try await run.deliver(seq: 0, now: adapterStart, id: 1, outcome: .success(nil)) }
        await #expect(throws: CodemodeProtocolError.callNotWaiting(99)) { try await run.deliver(seq: 1, now: adapterStart, id: 99, outcome: .success(nil)) }
        await #expect(throws: CodemodeProtocolError.invalidJSON) { try await run.deliver(seq: 1, now: adapterStart, id: 1, outcome: .success(.number(.infinity))) }
        await #expect(throws: CodemodeProtocolError.invalidJSON) { try await run.deliver(seq: 1, now: adapterStart, id: 1, outcome: .failure(message: "x", properties: ["bad": .number(.nan)])) }
        try await run.deliver(seq: 1, now: adapterStart - 2000, id: 1, outcome: .success(.null))
        #expect(await run.result.value == [.number(adapterStart), .number(adapterStart), 0])
        try await run.deliver(seq: -1, now: .nan, id: 99, outcome: .success(.number(.nan)))
    }

    // :249,343. Failure and success carry the terminal drain; finished precedes readiness.
    @Test(arguments: [false, true]) func terminalDrainAndFinishedAreMapped(_ watchdog: Bool) async throws {
        let (run, log) = try await adapterRun("await tools.wait({}); throw new TypeError('broken')", watchdog: watchdog)
        try await adapterWait { log.value.calls.count == 1 }
        #expect(await !run.finished)
        let waiter = Task { let result = await run.result; #expect(await run.finished); return result }
        try await run.deliver(seq: 1, now: adapterStart, id: 1, outcome: .success(nil))
        let result = await waiter.value
        #expect(result.error?.kind == .script)
        #expect(result.error?.name == "TypeError")
        #expect(result.error?.message == "broken")
        #expect(result.error?.stack?.contains("adapter-case.js") == true)
        #expect(result.during == .init(seq: 1, issued: 1))
        #expect(result.storeWrites == nil)
        await run.abort(message: "late abort")
        try await run.deliver(seq: -1, now: .nan, id: 99, outcome: .success(.number(.nan)))
        #expect(await run.result == result)
        let (immediate, _) = try await adapterRun("return 1", watchdog: watchdog)
        #expect(await immediate.result.during == .init(seq: 0, issued: 0))
        let (returned, _) = try await adapterRun("await tools.echo(1);return await tools.echo(2)", watchdog: watchdog)
        #expect(await returned.result.during == .init(seq: 2, issued: 2))
        let (thrown, _) = try await adapterRun("await tools.echo(1);await Promise.all([tools.echo(2),tools.echo(3)]);throw new Error('x')", watchdog: watchdog)
        #expect(await thrown.result.during == .init(seq: 3, issued: 3))
    }

    // :312. Exact script names and aliases survive the adapter.
    @Test(arguments: [false, true]) func toolsAndAllToolsUseExplicitScriptNames(_ watchdog: Bool) async throws {
        let (run, log) = try await adapterRun("await tools.renamed({}); return [typeof tools.renamed,Object.keys(tools),ALL_TOOLS.map(t=>t.name)]", watchdog: watchdog, tools: [.init(name: "my-tool", jsName: "renamed", description: "Exact")])
        #expect(await run.result.value == ["function", ["renamed", "my-tool"], ["renamed"]])
        #expect(log.value.calls.first?.name == "my-tool")
    }

    // :327. Host abort is outside JavaScript promise rejection.
    @Test(arguments: [false, true]) func abortCannotBeCaughtAndPendingCallsAreCancelled(_ watchdog: Bool) async throws {
        let (run, log) = try await adapterRun("try { await tools.wait({}); } catch(e) { text('caught'); } text('after')", watchdog: watchdog)
        try await adapterWait { log.value.calls.count == 1 }
        await run.abort(message: "diverged")
        let result = await run.result
        #expect(result.error?.kind == .aborted)
        #expect(result.error?.message == "diverged")
        #expect(result.output.isEmpty)
        #expect(result.calls.map(\.status) == [.cancelled])
        #expect(result.during == nil)
        try await run.deliver(seq: 1, now: adapterStart, id: 1, outcome: .success(nil))
        try await adapterWait { await (run as? JSCCodemodeRun)?.workerHasStopped == true }
    }

    @Test(arguments: [false, true]) func exactJSONKeysStoreWritesOutputAndUndefinedSurvive(_ watchdog: Bool) async throws {
        let composed = "é", decomposed = "e\u{301}"
        let initial: JSONObject = [(composed, 1), (decomposed, 2)].reduce(into: JSONObject()) { $0[$1.0] = $1.1 }
        let (run, _) = try await adapterRun("""
        const a='\u{e9}', b='e\u{301}';
        const original=[load(a),load(b)];
        store(a,{[a]:1,[b]:2}); store(b,3); store('gone');
        console.log('console');text('text');image({type:'image',data:'\(adapterPNG)',mimeType:'image/png'});
        return {original, nested:{[a]:1,[b]:2}, keys:Object.keys({z:1,'2':2,a:3,'1':4})};
        """, watchdog: watchdog, store: initial)
        let result = await run.result
        #expect(result.ok)
        #expect(result.value?["original"] == [1, 2])
        #expect(result.value?["nested"]?.objectValue?.count == 2)
        #expect(result.storeWrites?.set[composed]?.objectValue?.count == 2)
        #expect(result.storeWrites?.set[decomposed] == 3)
        #expect(result.storeWrites?.delete == ["gone"])
        #expect(result.value?["keys"] == ["1", "2", "z", "a"])
        #expect(result.output == [.text("console", console: true), .text("text"), .image(data: adapterPNG, mimeType: "image/png")])
        for (code, expected) in [("return undefined", Optional<JSONValue>.none), ("return null", Optional.some(JSONValue.null))] {
            let (value, _) = try await adapterRun(code, watchdog: watchdog)
            #expect(await value.result.value == expected)
        }
    }

    @Test(arguments: [false, true]) func bufferedReplyIsRecordedAtAcceptanceAndUnansweredCallIsCancelled(_ watchdog: Bool) async throws {
        let (run, log) = try await adapterRun("const a=tools.wait(1);tools.wait(2);tools.wait(3);return await a", watchdog: watchdog)
        try await adapterWait { log.value.idles.count == 1 }
        try await run.deliver(seq: 2, now: adapterStart, id: 2, outcome: .success(2))
        await #expect(throws: CodemodeProtocolError.invalidSequence(2)) { try await run.deliver(seq: 2, now: adapterStart, id: 3, outcome: .success(3)) }
        try await run.deliver(seq: 1, now: adapterStart, id: 1, outcome: .success(1))
        #expect(await run.result.calls.map(\.status) == [.ok, .ok, .cancelled])
        #expect(await run.result.calls.allSatisfy { $0.durationMs.isFinite && $0.durationMs >= 0 })
    }

    @Test(arguments: [false, true]) func normalAndThrownEndReleaseWorker(_ watchdog: Bool) async throws {
        for code in ["return 1", "throw new Error('done')"] {
            let (run, _) = try await adapterRun(code, watchdog: watchdog)
            _ = await run.result
            try await adapterWait { await (run as? JSCCodemodeRun)?.workerHasStopped == true }
        }
    }

    // The watchdog returns while a finite non-yielding loop still runs. It must stop when that loop ends.
    @Test(arguments: [false, true]) func deadlineForNonYieldingScriptAndWorkerLifetime(_ watchdog: Bool) async throws {
        #if os(macOS)
        let code = watchdog ? "let x=0; for(let i=0;i<400000000;i++) x=(x+i)|0; return x" : "for(;;){}"
        #else
        let code = "let x=0; for(let i=0;i<400000000;i++) x=(x+i)|0; return x"
        #endif
        let start = ContinuousClock.now
        let run = try await JSCCodemodeSandbox(forceWatchdog: watchdog).start(source: code, name: "deadline.js", options: .init(startedAt: 0, seed: 1, timeoutMs: 20))
        #expect(await run.result.error?.kind == .timeout)
        #expect(start.duration(to: .now) < .seconds(3))
        if watchdog { #expect(await (run as? JSCCodemodeRun)?.workerHasStopped == false) }
        try await adapterWait { await (run as? JSCCodemodeRun)?.workerHasStopped == true }
    }

    @Test(arguments: [false, true]) func abortOfNonYieldingScriptReleasesWorkerWhenItStops(_ watchdog: Bool) async throws {
        let issued = AdapterLog()
        #if os(macOS)
        let code = watchdog ? "tools.wait({});let x=0;for(let i=0;i<400000000;i++) x=(x+i)|0;return x" : "tools.wait({});for(;;){}"
        #else
        let code = "tools.wait({});let x=0;for(let i=0;i<400000000;i++) x=(x+i)|0;return x"
        #endif
        let run = try await JSCCodemodeSandbox(forceWatchdog: watchdog).start(source: code, name: "abort.js", options: .init(startedAt: 0, seed: 1, tools: [.init(name: "wait")], timeoutMs: 5000, onCall: { call, _ in issued.state.withLock { $0.calls.append(call) } }))
        try await adapterWait { issued.value.calls.count == 1 }
        await run.abort(message: "stop")
        #expect(await run.result.error?.message == "stop")
        try await adapterWait { await (run as? JSCCodemodeRun)?.workerHasStopped == true }
    }

    @Test(arguments: [false, true]) func closeDuringStartAbortsReservedRun(_ watchdog: Bool) async throws {
        let sandbox = JSCCodemodeSandbox(forceWatchdog: watchdog)
        let run = try await sandbox.start(source: "text('must not run')", name: "close.js", options: .init(startedAt: 0, seed: 1, onStarted: { _, _ in await sandbox.close() }))
        #expect(await run.result.error?.message == "Sandbox closed")
        #expect(await run.result.output.isEmpty)
        #expect(await (run as? JSCCodemodeRun)?.workerHasStopped == true)
        await sandbox.close()
        await #expect(throws: CodemodeError.self) { try await sandbox.start(source: "return 1", name: "later", options: .init(startedAt: 0, seed: 1)) }
    }

    @Test(arguments: [false, true]) func startValidationAndDeadlineConversion(_ watchdog: Bool) async throws {
        let sandbox = JSCCodemodeSandbox(forceWatchdog: watchdog)
        for timeout in [Double(Int.max), Double.greatestFiniteMagnitude] {
            await #expect(throws: CodemodeProtocolError.invalidClock) { try await sandbox.start(source: "return 1", name: "x", options: .init(startedAt: 0, seed: 1, timeoutMs: timeout)) }
        }
        for timeout in [Double.nan, .infinity, -.infinity] {
            let run = try await sandbox.start(source: "return 1", name: "no-deadline", options: .init(startedAt: 0, seed: 1, timeoutMs: timeout))
            #expect(await run.result.value == 1)
        }
        await #expect(throws: CodemodeProtocolError.invalidSourceName) { try await sandbox.start(source: "return 1", name: "", options: .init(startedAt: 0, seed: 1)) }
        await #expect(throws: CodemodeProtocolError.invalidToolName("a_b")) { try await sandbox.start(source: "return 1", name: "x", options: .init(startedAt: 0, seed: 1, tools: [.init(name: "a-b"), .init(name: "a_b")])) }
        await #expect(throws: CodemodeProtocolError.invalidGlobalName("tools.bad")) { try await sandbox.start(source: "return 1", name: "x", options: .init(startedAt: 0, seed: 1, globals: [.init(name: "tools.bad")])) }
        for timeout in [-1.0, 0.25] {
            let run = try await sandbox.start(source: "await tools.wait({})", name: "x", options: .init(startedAt: 0, seed: 1, tools: [.init(name: "wait")], timeoutMs: timeout))
            #expect(await run.result.error?.kind == .timeout)
        }
        await sandbox.close()
    }

    @Test(arguments: [false, true]) func unsupportedSurrogateFailsAtDurableJSONBoundary(_ watchdog: Bool) async throws {
        let (run, log) = try await adapterRun("return await tools.echo({bad:'\\ud800'})", watchdog: watchdog)
        #expect(await run.result.error?.kind == .sandbox)
        #expect(log.value.calls.isEmpty)
        #expect(await run.result.storeWrites == nil)
        try await adapterWait { await (run as? JSCCodemodeRun)?.workerHasStopped == true }
    }

    // :386. Ordinary execution stays a runtime operation; it is not part of CodemodeSandbox.
    @Test(arguments: [false, true]) func ordinaryExecuteKeepsRealTimeAndRandomness(_ watchdog: Bool) async throws {
        let before = Date().timeIntervalSince1970 * 1000
        let one = await JSCCodemodeEngine.execute(code: "return [Date.now(),Math.random(),typeof WeakRef,typeof FinalizationRegistry]", tools: [], timeoutMs: 5000, forceWatchdog: watchdog, onCall: { _ in .init(ok: true) })
        let two = await JSCCodemodeEngine.execute(code: "return Math.random()", tools: [], timeoutMs: 5000, forceWatchdog: watchdog, onCall: { _ in .init(ok: true) })
        let value = try JSONValue(jsonData: JSONEncoder().encode(one.execution.returnedValue))
        #expect((value[0]?.numberValue ?? 0) >= before - 1)
        #expect((value[0]?.numberValue ?? 0) <= Date().timeIntervalSince1970 * 1000)
        #expect(value[2] == "function")
        #expect(value[3] == "function")
        #expect(value[1] != (try JSONValue(jsonData: JSONEncoder().encode(two.execution.returnedValue))))
        #expect(one.during == nil)
    }
}
