import Foundation
import Testing
import PiSwiftAI
@testable import PiSwiftCodemodeRuntime

private let deterministicStartedAt = 1_768_471_200_000.0

private struct DeterministicCall: Sendable, Equatable {
    var id: Int
    var target: String
    var name: String
    var arguments: AnyCodable?
}

private struct DeterministicIdle: Sendable, Equatable {
    var seq: Int
    var issued: Int
}

private struct DeterministicEvidence: Sendable {
    var calls: [DeterministicCall] = []
    var idles: [DeterministicIdle] = []
    var events: [String] = []
    var fingerprint: String?
    var replySequence = 0
    var deliveryErrors: [String] = []
}

private struct DeterministicRecorded: Sendable {
    let run: CodemodeRuntimeRun
    let evidence: LockedState<DeterministicEvidence>

    var snapshot: DeterministicEvidence { evidence.withLock { $0 } }
}

private func deterministicJSON(_ text: String) throws -> AnyCodable {
    try JSONDecoder().decode(AnyCodable.self, from: Data(text.utf8))
}

private func deterministicNumber(_ value: Any) -> Double? {
    (value as? NSNumber)?.doubleValue
}

private func deterministicText(_ result: CodemodeRuntimeResult) -> [String] {
    result.execution.output.compactMap {
        if case .text(let text, _) = $0 { return text }
        return nil
    }
}

private func deterministicStart(
    _ code: String,
    forceWatchdog: Bool,
    startedAt: Double = deterministicStartedAt,
    seed: UInt32 = 1,
    tools: [CodemodeRuntimeTool] = [.init(name: "echo"), .init(name: "wait")],
    globals: [CodemodeRuntimeGlobal] = [],
    store: [String: AnyCodable] = [:],
    signal: CancellationToken? = nil,
    name: String = "codemode.js",
    answer: @escaping @Sendable (CodemodeRuntimeCall) -> CodemodeRuntimeOutcome = { .success(json: $0.argsJSON) }
) async throws -> DeterministicRecorded {
    let evidence = LockedState(DeterministicEvidence())
    let options = CodemodeRuntimeStartOptions(
        startedAt: startedAt, seed: seed, tools: tools, globals: globals, store: store,
        timeoutMs: 20_000, signal: signal, forceWatchdog: forceWatchdog,
        onStarted: { fingerprint, _ in
            evidence.withLock {
                $0.fingerprint = fingerprint
                $0.events.append("started")
            }
        },
        onCall: { call, run in
            let seq = evidence.withLock { state -> Int? in
                state.calls.append(.init(id: call.id, target: call.target.rawValue, name: call.name,
                                         arguments: call.argsJSON.flatMap { try? deterministicJSON($0) }))
                state.events.append("call \(call.id)")
                guard call.name != "wait" else { return nil }
                state.replySequence += 1
                return state.replySequence
            }
            guard let seq else { return }
            let outcome = answer(call)
            Task {
                do {
                    try await run.deliver(seq: seq, now: startedAt + Double(seq) * 1000,
                                          id: call.id, outcome: outcome)
                } catch {
                    evidence.withLock { $0.deliveryErrors.append(String(describing: error)) }
                }
            }
        },
        onIdle: { seq, issued, _ in
            evidence.withLock {
                $0.idles.append(.init(seq: seq, issued: issued))
                $0.events.append("idle \(seq)")
            }
        })
    let run = try await JSCCodemodeEngine.start(code: code, name: name, options: options)
    return .init(run: run, evidence: evidence)
}

private enum DeterministicTestError: Error { case conditionNotReached }

private func deterministicWait(
    _ recorded: DeterministicRecorded,
    calls: Int,
    idles: Int = 0
) async throws {
    let deadline = ContinuousClock.now + .seconds(5)
    while recorded.snapshot.calls.count < calls || recorded.snapshot.idles.count < idles {
        guard ContinuousClock.now < deadline else {
            await recorded.run.abort(message: "Test condition was not reached")
            throw DeterministicTestError.conditionNotReached
        }
        try await Task.sleep(for: .milliseconds(5))
    }
}

@Suite(.serialized, .timeLimit(.minutes(1)))
struct DeterministicTests {
    @Test(arguments: [false, true])
    func sameInputsGiveSameCallsAndOutput(forceWatchdog: Bool) async throws {
        let code = """
        const values = [Date.now(), performance.now(), Math.random(), Math.random(), new Date().toISOString()];
        const first = await tools.echo(values);
        text(JSON.stringify([Date.now(), performance.now(), Math.random()]));
        return await tools.echo(first.concat(Math.random()));
        """
        let one = try await deterministicStart(code, forceWatchdog: forceWatchdog)
        let two = try await deterministicStart(code, forceWatchdog: forceWatchdog)
        let a = await one.run.result
        let b = await two.run.result
        #expect(a.execution.failure == nil)
        #expect(b.execution.failure == nil)
        #expect(a.execution.returnedValue == b.execution.returnedValue)
        #expect(deterministicText(a) == deterministicText(b))
        #expect(a.storeWrites.set == b.storeWrites.set)
        #expect(a.storeWrites.delete == b.storeWrites.delete)
        #expect(a.during == b.during)
        #expect(one.snapshot.calls == two.snapshot.calls)
        #expect(one.snapshot.deliveryErrors.isEmpty)
        #expect(two.snapshot.deliveryErrors.isEmpty)
        let first = try #require(one.snapshot.calls.first?.arguments?.value as? [Any])
        #expect(deterministicNumber(first[0]) == deterministicStartedAt)
        #expect(deterministicNumber(first[1]) == 0)
        #expect(deterministicNumber(first[2]) == 0.6270739405881613)
        #expect(first[4] as? String == "2026-01-15T10:00:00.000Z")
        let printed = try deterministicJSON(try #require(deterministicText(a).first))
        let printedValues = try JSONDecoder().decode([Double].self, from: JSONEncoder().encode(printed))
        #expect(Array(printedValues.prefix(2)) == [deterministicStartedAt + 1000, 1000])

        let later = try await deterministicStart(code, forceWatchdog: forceWatchdog,
                                                 startedAt: deterministicStartedAt + 5000)
        let reseeded = try await deterministicStart(code, forceWatchdog: forceWatchdog, seed: 2)
        _ = await later.run.result
        _ = await reseeded.run.result
        let laterValues = try #require(later.snapshot.calls.first?.arguments?.value as? [Any])
        #expect(deterministicNumber(laterValues[2]) == deterministicNumber(first[2]))
        let reseededValues = try #require(reseeded.snapshot.calls.first?.arguments?.value as? [Any])
        #expect(deterministicNumber(reseededValues[2]) != deterministicNumber(first[2]))
        let zero = try await deterministicStart("return [Math.random(), Math.random()]",
                                               forceWatchdog: forceWatchdog, seed: 0)
        let zeroResult = await zero.run.result
        #expect(zeroResult.execution.returnedValue == AnyCodable([0.26642920868471265, 0.0003297457005828619]))
        #expect(zero.snapshot.fingerprint == one.snapshot.fingerprint)
    }

    @Test(arguments: [false, true])
    func dateUsesUTCAndWeakGlobalsAreAbsent(forceWatchdog: Bool) async throws {
        let recorded = try await deterministicStart("""
        return [new Date(0).getHours(), new Date(0).getTimezoneOffset(),
          typeof WeakRef, typeof FinalizationRegistry, Date(),
          new Date(2026, 0, 15, 10).toISOString(), Date.parse('2026-01-15T10:00:00'),
          new Date().getHours(), typeof Temporal];
        """, forceWatchdog: forceWatchdog)
        let result = await recorded.run.result
        let values = try #require(result.execution.returnedValue?.value as? [Any])
        #expect(values[0] as? Int == 0)
        #expect(values[1] as? Int == 0)
        #expect(values[2] as? String == "undefined")
        #expect(values[3] as? String == "undefined")
        #expect((values[4] as? String)?.contains("GMT+0000") == true)
        #expect(values[5] as? String == "2026-01-15T10:00:00.000Z")
        #expect(deterministicNumber(values[6]) == deterministicStartedAt)
        #expect(values[7] as? Int == 10)
        #expect(values[8] as? String == "undefined")
    }

    @Test(arguments: [false, true])
    func repliesUseSequenceOrder(forceWatchdog: Bool) async throws {
        let recorded = try await deterministicStart("""
        const order = [];
        await Promise.all([tools.wait('a').then(() => order.push('a')),
          tools.wait('b').then(() => order.push('b'))]);
        return order;
        """, forceWatchdog: forceWatchdog)
        try await deterministicWait(recorded, calls: 2, idles: 1)
        try await recorded.run.deliver(seq: 2, now: deterministicStartedAt + 2000,
                                        id: 1, outcome: .success(json: "null"))
        try await recorded.run.deliver(seq: 1, now: deterministicStartedAt + 1000,
                                        id: 2, outcome: .success(json: "null"))
        let result = await recorded.run.result
        #expect(result.execution.returnedValue == AnyCodable(["b", "a"]))
        #expect(recorded.snapshot.idles == [.init(seq: 0, issued: 2), .init(seq: 1, issued: 2)])
    }

    @Test(arguments: [false, true])
    func fingerprintPrecedesCallsAndIdleReportsIssuedCount(forceWatchdog: Bool) async throws {
        let recorded = try await deterministicStart(
            "await tools.echo(1); await Promise.all([tools.echo(2), tools.echo(3)]);",
            forceWatchdog: forceWatchdog)
        let result = await recorded.run.result
        #expect(result.execution.failure == nil)
        #expect(Array(recorded.snapshot.events.prefix(3)) == ["started", "call 1", "idle 0"])
        #expect(recorded.snapshot.idles == [.init(seq: 0, issued: 1), .init(seq: 1, issued: 3), .init(seq: 2, issued: 3)])
        #expect(recorded.snapshot.calls == [
            .init(id: 1, target: "tool", name: "echo", arguments: AnyCodable(1)),
            .init(id: 2, target: "tool", name: "echo", arguments: AnyCodable(2)),
            .init(id: 3, target: "tool", name: "echo", arguments: AnyCodable(3))])
        let fingerprint = try #require(recorded.snapshot.fingerprint)
        #expect(fingerprint.lowercased().contains("javascriptcore"))
        #expect(fingerprint.lowercased().contains("prelude"))
        #expect(fingerprint.lowercased().contains("scheduler"))
        #expect(fingerprint.lowercased().contains("mulberry32"))
        #expect(!fingerprint.lowercased().contains("quickjs"))
        let same = try await deterministicStart("return 1", forceWatchdog: forceWatchdog)
        _ = await same.run.result
        #expect(same.snapshot.fingerprint == fingerprint)
        #expect(recorded.snapshot.deliveryErrors.isEmpty)
    }

    @Test(arguments: [false, true])
    func toolsAndGlobalsShareIDsAndErrorsReject(forceWatchdog: Bool) async throws {
        let recorded = try await deterministicStart("""
        const found = await search('x', 2);
        try { await tools.echo('fail'); } catch (error) { text(error.message); }
        return found;
        """, forceWatchdog: forceWatchdog, globals: [.init(name: "search", spread: true)], answer: { call in
            call.name == "search" ? .success(json: "[\"found\"]") : .failure(message: "no")
        })
        let result = await recorded.run.result
        #expect(recorded.snapshot.calls == [
            .init(id: 1, target: "global", name: "search", arguments: AnyCodable(["x", 2] as [Any])),
            .init(id: 2, target: "tool", name: "echo", arguments: AnyCodable("fail"))])
        #expect(result.execution.returnedValue == AnyCodable(["found"]))
        #expect(deterministicText(result) == ["no"])
        #expect(Array(recorded.snapshot.idles.prefix(2)) == [.init(seq: 0, issued: 1), .init(seq: 1, issued: 2)])
    }

    @Test(arguments: [false, true])
    func virtualClockIsFiniteAndMonotonic(forceWatchdog: Bool) async throws {
        let recorded = try await deterministicStart(
            "const before = Date.now(); await tools.wait(1); return [before, Date.now(), performance.now()]",
            forceWatchdog: forceWatchdog)
        try await deterministicWait(recorded, calls: 1)
        for time in [Double.nan, .infinity, -.infinity] {
            await #expect(throws: CodemodeRuntimeProtocolError.invalidClock) {
                try await recorded.run.deliver(seq: 1, now: time, id: 1, outcome: .success(json: "null"))
            }
        }
        try await recorded.run.deliver(seq: 1, now: deterministicStartedAt - 2000,
                                        id: 1, outcome: .success(json: "null"))
        let result = await recorded.run.result
        #expect(result.execution.returnedValue == AnyCodable([Int(deterministicStartedAt), Int(deterministicStartedAt), 0]))
        let resumed = try await deterministicStart("""
        await tools.wait(1); const first = Date.now();
        await tools.wait(2); return [first, Date.now(), performance.now()];
        """, forceWatchdog: forceWatchdog)
        try await deterministicWait(resumed, calls: 1)
        try await resumed.run.deliver(seq: 1, now: deterministicStartedAt + 1000,
                                      id: 1, outcome: .success(json: nil))
        try await deterministicWait(resumed, calls: 2)
        try await resumed.run.deliver(seq: 2, now: deterministicStartedAt + 500,
                                      id: 2, outcome: .success(json: nil))
        let resumedResult = await resumed.run.result
        #expect(resumedResult.execution.returnedValue == AnyCodable(
            [Int(deterministicStartedAt + 1000), Int(deterministicStartedAt + 1000), 1000]))
        for time in [Double.nan, .infinity, -.infinity, -1] {
            await #expect(throws: CodemodeRuntimeProtocolError.invalidClock) {
                _ = try await deterministicStart("return 1", forceWatchdog: forceWatchdog, startedAt: time)
            }
        }
    }

    @Test(arguments: [false, true])
    func outcomeReportsDrainSequenceAndIssuedCalls(forceWatchdog: Bool) async throws {
        let returned = try await deterministicStart("await tools.echo(1); return await tools.echo(2)", forceWatchdog: forceWatchdog)
        let thrown = try await deterministicStart("""
        await tools.echo(1); await Promise.all([tools.echo(2), tools.echo(3)]); throw new Error('x')
        """, forceWatchdog: forceWatchdog)
        let first = try await deterministicStart("return 1", forceWatchdog: forceWatchdog)
        let returnedResult = await returned.run.result
        let thrownResult = await thrown.run.result
        let firstResult = await first.run.result
        #expect(returnedResult.execution.returnedValue == AnyCodable(2))
        #expect(returnedResult.during == .init(seq: 2, issued: 2))
        #expect(thrownResult.execution.failure?.message == "x")
        #expect(thrownResult.during == .init(seq: 3, issued: 3))
        #expect(firstResult.during == .init(seq: 0, issued: 0))
        let ordinary = await JSCCodemodeEngine.execute(code: "return 1", tools: [], forceWatchdog: forceWatchdog) { _ in .init(ok: true) }
        #expect(ordinary.during == nil)
    }

    @Test(arguments: [false, true])
    func invalidJSONDoesNotConsumeCallOrSequence(forceWatchdog: Bool) async throws {
        let recorded = try await deterministicStart("return await tools.wait(1)", forceWatchdog: forceWatchdog)
        try await deterministicWait(recorded, calls: 1)
        for json in ["1n", "{", "undefined", "NaN", "1 2", "[1,]", "{\"x\":1,}",
                     "01", "+1", ".1", "1.", "1e", "--1", "\"line\nbreak\""] {
            await #expect(throws: CodemodeRuntimeProtocolError.invalidJSON) {
                try await recorded.run.deliver(seq: 1, now: deterministicStartedAt, id: 1, outcome: .success(json: json))
            }
        }
        await #expect(throws: CodemodeRuntimeProtocolError.invalidJSON) {
            try await recorded.run.deliver(seq: 1, now: deterministicStartedAt, id: 1,
                                            outcome: .failure(message: "x", propertiesJSON: "{\"big\":1n}"))
        }
        try await recorded.run.deliver(seq: 1, now: deterministicStartedAt, id: 1, outcome: .success(json: "\"fine\""))
        let result = await recorded.run.result
        #expect(result.execution.returnedValue == AnyCodable("fine"))
    }

    @Test(arguments: [false, true])
    func rejectionHasOwnPropertiesAndKeepsErrorIdentity(forceWatchdog: Bool) async throws {
        let recorded = try await deterministicStart("""
        try { await tools.echo(1); } catch (e) {
          return [e instanceof Error, e.message, e.name, e.structuredOutput,
            Object.hasOwn(e, '__proto__'), e.__proto__, Object.hasOwn(e, 'constructor'),
            e.constructor, e.stack === 'ignored', Object.getPrototypeOf(e) === Error.prototype];
        }
        """, forceWatchdog: forceWatchdog, answer: { _ in
            .failure(message: "denied", propertiesJSON: #"{"structuredOutput":{"code":7},"name":"Ignored","message":"ignored","stack":"ignored","__proto__":{"safe":true},"constructor":"own"}"#)
        })
        let result = await recorded.run.result
        #expect(result.execution.returnedValue == (try deterministicJSON(
            #"[true,"denied","Error",{"code":7},true,{"safe":true},true,"own",false,true]"#)))
    }

    @Test(arguments: [false, true])
    func invalidPropertiesDoNotConsumeCallAndDuplicateNamesReject(forceWatchdog: Bool) async throws {
        let recorded = try await deterministicStart("return await tools.wait(1)", forceWatchdog: forceWatchdog)
        try await deterministicWait(recorded, calls: 1)
        for properties in ["null", "[1]", "1", "true", "\"x\""] {
            await #expect(throws: CodemodeRuntimeProtocolError.invalidProperties) {
                try await recorded.run.deliver(seq: 1, now: deterministicStartedAt, id: 1,
                                                outcome: .failure(message: "x", propertiesJSON: properties))
            }
        }
        try await recorded.run.deliver(seq: 1, now: deterministicStartedAt, id: 1, outcome: .success(json: "1"))
        let result = await recorded.run.result
        #expect(result.execution.returnedValue == AnyCodable(1))
        await #expect(throws: CodemodeRuntimeProtocolError.self) {
            _ = try await deterministicStart("", forceWatchdog: forceWatchdog,
                                             tools: [.init(name: "a-b"), .init(name: "a_b")])
        }
        await #expect(throws: CodemodeRuntimeProtocolError.self) {
            _ = try await deterministicStart("", forceWatchdog: forceWatchdog,
                                             globals: [.init(name: "search"), .init(name: "search")])
        }
    }

    @Test(arguments: [false, true])
    func explicitToolAndSourceNamesAreUsed(forceWatchdog: Bool) async throws {
        var renamed = CodemodeRuntimeTool(name: "my-tool")
        renamed.jsName = "renamed"
        let recorded = try await deterministicStart(
            "return [typeof tools.renamed, Object.keys(tools), ALL_TOOLS.map(tool => tool.name)]",
            forceWatchdog: forceWatchdog, tools: [renamed], name: "replay-step.js")
        let result = await recorded.run.result
        #expect(result.execution.returnedValue == (try deterministicJSON(#"["function",["renamed","my-tool"],["renamed"]]"#)))
        let failing = try await deterministicStart("throw new Error('named')", forceWatchdog: forceWatchdog,
                                                  name: "replay-step.js")
        let failure = await failing.run.result
        #expect(failure.execution.failure?.stack?.contains("replay-step.js") == true)
        #expect(failure.execution.failure?.stack?.contains("codemode-prelude.js") == false)
        #expect(failure.execution.failure?.stack?.contains("/replay-step.js") == true)
        #expect(failure.execution.failure?.stack?.contains("/Users/") == false)
        #expect(failure.execution.failure?.stack?.contains("/private/var/") == false)
        await #expect(throws: CodemodeRuntimeProtocolError.invalidSourceName) {
            _ = try await deterministicStart("", forceWatchdog: forceWatchdog, name: "")
        }
    }

    @Test(arguments: [false, true])
    func abortCannotBeCaught(forceWatchdog: Bool) async throws {
        let recorded = try await deterministicStart("""
        try { await tools.wait(1); } catch { text('caught'); }
        text('after');
        """, forceWatchdog: forceWatchdog)
        try await deterministicWait(recorded, calls: 1)
        await recorded.run.abort(message: "diverged")
        let result = await recorded.run.result
        #expect(result.execution.failure?.kind == .aborted)
        #expect(result.execution.failure?.message == "diverged")
        #expect(result.execution.output.isEmpty)
        try await recorded.run.deliver(seq: 1, now: deterministicStartedAt, id: 1, outcome: .success(json: "null"))

        let signal = CancellationToken()
        let signalled = try await deterministicStart("try { await tools.wait(1); } catch { text('caught'); } text('after')",
                                                    forceWatchdog: forceWatchdog, signal: signal)
        try await deterministicWait(signalled, calls: 1)
        signal.cancel()
        let signalledResult = await signalled.run.result
        #expect(signalledResult.execution.failure?.kind == .aborted)
        #expect(signalledResult.execution.output.isEmpty)
    }

    @Test(arguments: [false, true])
    func finishedIsSetBeforeResultWaitersResume(forceWatchdog: Bool) async throws {
        let recorded = try await deterministicStart("await tools.wait(1); return 2", forceWatchdog: forceWatchdog)
        try await deterministicWait(recorded, calls: 1)
        #expect(await recorded.run.finished == false)
        let first = Task {
            _ = await recorded.run.result
            return await recorded.run.finished
        }
        let second = Task {
            _ = await recorded.run.result
            return await recorded.run.finished
        }
        try await recorded.run.deliver(seq: 1, now: deterministicStartedAt, id: 1, outcome: .success(json: "null"))
        #expect(await first.value)
        #expect(await second.value)
        #expect(await recorded.run.finished)
    }

    @Test(arguments: [false, true])
    func invalidCallAndReusedSequenceReject(forceWatchdog: Bool) async throws {
        let recorded = try await deterministicStart("await Promise.all([tools.wait(1), tools.wait(2)])",
                                                   forceWatchdog: forceWatchdog)
        try await deterministicWait(recorded, calls: 2)
        await #expect(throws: CodemodeRuntimeProtocolError.callNotWaiting(99)) {
            try await recorded.run.deliver(seq: 1, now: deterministicStartedAt, id: 99, outcome: .success(json: "null"))
        }
        try await recorded.run.deliver(seq: 1, now: deterministicStartedAt, id: 1, outcome: .success(json: "null"))
        for seq in [1, 0, -1] {
            await #expect(throws: CodemodeRuntimeProtocolError.invalidSequence(seq)) {
                try await recorded.run.deliver(seq: seq, now: deterministicStartedAt, id: 2, outcome: .success(json: "null"))
            }
        }
        await #expect(throws: CodemodeRuntimeProtocolError.callNotWaiting(1)) {
            try await recorded.run.deliver(seq: 2, now: deterministicStartedAt, id: 1, outcome: .success(json: "null"))
        }
        try await recorded.run.deliver(seq: 2, now: deterministicStartedAt, id: 2, outcome: .success(json: "null"))
        let result = await recorded.run.result
        #expect(result.execution.failure == nil)
    }

    @Test(arguments: [false, true])
    func boundaryCanReorderRepliesSentInOrder(forceWatchdog: Bool) async throws {
        let recorded = try await deterministicStart("""
        const order = [];
        await Promise.all([tools.wait('a').then(() => order.push('a')),
          tools.wait('b').then(() => order.push('b'))]);
        return order;
        """, forceWatchdog: forceWatchdog)
        try await deterministicWait(recorded, calls: 2)
        let firstTransportReply = Task {
            try await Task.sleep(for: .milliseconds(30))
            try await recorded.run.deliver(seq: 1, now: deterministicStartedAt + 1000,
                                            id: 1, outcome: .success(json: "null"))
        }
        try await recorded.run.deliver(seq: 2, now: deterministicStartedAt + 2000,
                                        id: 2, outcome: .success(json: "null"))
        try await firstTransportReply.value
        let result = await recorded.run.result
        #expect(result.execution.returnedValue == AnyCodable(["a", "b"]))
    }

    @Test(arguments: [false, true])
    func ordinaryExecuteUsesRealTimeAndRandomness(forceWatchdog: Bool) async throws {
        let before = Date().timeIntervalSince1970 * 1000
        let code = "return [Date.now(), Math.random(), typeof WeakRef, typeof FinalizationRegistry]"
        let first = await JSCCodemodeEngine.execute(code: code, tools: [], forceWatchdog: forceWatchdog) { _ in .init(ok: true) }
        let second = await JSCCodemodeEngine.execute(code: code, tools: [], forceWatchdog: forceWatchdog) { _ in .init(ok: true) }
        let after = Date().timeIntervalSince1970 * 1000
        let one = try #require(first.execution.returnedValue?.value as? [Any])
        let two = try #require(second.execution.returnedValue?.value as? [Any])
        let now = try #require(deterministicNumber(one[0]))
        #expect(now >= floor(before))
        #expect(now <= after)
        #expect(one[1] as? Double != two[1] as? Double)
        #expect(one[2] as? String == "function")
        #expect(one[3] as? String == "function")
        #expect(first.during == nil)
    }

    @Test(arguments: [false, true])
    func timeoutStopsScriptThatNeverYields(forceWatchdog: Bool) async throws {
        let started = ContinuousClock.now
        let run = try await JSCCodemodeEngine.start(code: "while (true) {}", options: .init(
            startedAt: deterministicStartedAt, seed: 1, timeoutMs: 100,
            forceWatchdog: forceWatchdog, onCall: { _, _ in }))
        let result = await run.result
        #expect(result.execution.failure?.kind == .timeout)
        #expect(await run.finished)
        #expect(result.usedWatchdog == !JSCCodemodeEngine.usesTimeLimit(forceWatchdog: forceWatchdog))
        #expect(ContinuousClock.now - started < .seconds(5))
    }

    @Test(arguments: [false, true])
    func timeoutStopsInfiniteMicrotaskLoop(forceWatchdog: Bool) async throws {
        let started = ContinuousClock.now
        let run = try await JSCCodemodeEngine.start(code: "while (true) { await Promise.resolve(); }", options: .init(
            startedAt: deterministicStartedAt, seed: 1, timeoutMs: 100,
            forceWatchdog: forceWatchdog, onCall: { _, _ in }))
        let result = await run.result
        #expect(result.execution.failure?.kind == .timeout)
        #expect(await run.finished)
        #expect(result.usedWatchdog == !JSCCodemodeEngine.usesTimeLimit(forceWatchdog: forceWatchdog))
        #expect(ContinuousClock.now - started < .seconds(5))
    }

    @Test(arguments: [false, true])
    func startCallbackCompletesBeforeCalls(forceWatchdog: Bool) async throws {
        let events = LockedState<[String]>([])
        let run = try await JSCCodemodeEngine.start(code: "return await tools.echo(7)", options: .init(
            startedAt: deterministicStartedAt, seed: 1, tools: [.init(name: "echo")],
            timeoutMs: 5000, forceWatchdog: forceWatchdog,
            onStarted: { _, _ in
                events.withLock { $0.append("start entered") }
                try? await Task.sleep(for: .milliseconds(25))
                events.withLock { $0.append("start completed") }
            }, onCall: { call, run in
                events.withLock { $0.append("call") }
                do {
                    try await run.deliver(seq: 1, now: deterministicStartedAt, id: call.id,
                                          outcome: .success(json: call.argsJSON))
                } catch { Issue.record("Reply failed: \(error)") }
            }))
        let result = await run.result
        #expect(result.execution.returnedValue == AnyCodable(7))
        #expect(events.withLock { $0 } == ["start entered", "start completed", "call"])
    }

    @Test(arguments: [false, true])
    func abortDuringStartPreventsWorkerEvents(forceWatchdog: Bool) async throws {
        let events = LockedState<[String]>([])
        let finishedInCallback = LockedState(false)
        let run = try await JSCCodemodeEngine.start(code: "text('ran'); return await tools.echo(1)", options: .init(
            startedAt: deterministicStartedAt, seed: 1, tools: [.init(name: "echo")],
            timeoutMs: 5000, forceWatchdog: forceWatchdog,
            onStarted: { _, run in
                events.withLock { $0.append("started") }
                await run.abort(message: "stopped before worker")
                let finished = await run.finished
                finishedInCallback.withLock { $0 = finished }
                await Task.yield()
            }, onCall: { _, _ in events.withLock { $0.append("call") } },
            onIdle: { _, _, _ in events.withLock { $0.append("idle") } }))
        let result = await run.result
        #expect(finishedInCallback.withLock { $0 })
        #expect(await run.finished)
        #expect(result.execution.failure?.kind == .aborted)
        #expect(result.execution.failure?.message == "stopped before worker")
        #expect(result.execution.output.isEmpty)
        #expect(result.unfinishedCalls.isEmpty)
        #expect(result.during == nil)
        #expect(events.withLock { $0 } == ["started"])
    }

    @Test(arguments: [false, true])
    func cancelledSignalPreventsStartCallbackAndWorker(forceWatchdog: Bool) async throws {
        let signal = CancellationToken()
        signal.cancel()
        let events = LockedState<[String]>([])
        let run = try await JSCCodemodeEngine.start(code: "text('ran'); return await tools.echo(1)", options: .init(
            startedAt: deterministicStartedAt, seed: 1, tools: [.init(name: "echo")],
            timeoutMs: 5000, signal: signal, forceWatchdog: forceWatchdog,
            onStarted: { _, _ in events.withLock { $0.append("started") } },
            onCall: { _, _ in events.withLock { $0.append("call") } },
            onIdle: { _, _, _ in events.withLock { $0.append("idle") } }))
        let result = await run.result
        #expect(await run.finished)
        #expect(result.execution.failure?.kind == .aborted)
        #expect(result.execution.output.isEmpty)
        #expect(events.withLock { $0.isEmpty })
    }

    @Test(arguments: [false, true])
    func terminalOutcomeSurvivesLaterAbortAndInvalidDelivery(forceWatchdog: Bool) async throws {
        let recorded = try await deterministicStart("text('complete'); return 7", forceWatchdog: forceWatchdog)
        let first = await recorded.run.result
        await recorded.run.abort(message: "too late")
        try await recorded.run.deliver(seq: -1, now: .nan, id: -1, outcome: .success(json: "not JSON"))
        try await recorded.run.deliver(seq: 0, now: .infinity, id: 99,
                                        outcome: .failure(message: "too late", propertiesJSON: "[1]"))
        let later = await recorded.run.result
        #expect(first.execution.failure == nil)
        #expect(later.execution.failure == nil)
        #expect(later.execution.returnedValue == AnyCodable(7))
        #expect(deterministicText(later) == ["complete"])
        #expect(later.during == first.during)
        #expect(await recorded.run.finished)
    }

    @Test(arguments: [false, true])
    func duplicateOriginalNamesRejectEvenWithDistinctScriptNames(forceWatchdog: Bool) async throws {
        var first = CodemodeRuntimeTool(name: "same")
        first.jsName = "first"
        var second = CodemodeRuntimeTool(name: "same")
        second.jsName = "second"
        let duplicateOriginals = [first, second]
        await #expect(throws: CodemodeRuntimeProtocolError.invalidToolName("same")) {
            _ = try await deterministicStart("", forceWatchdog: forceWatchdog, tools: duplicateOriginals)
        }
        var other = CodemodeRuntimeTool(name: "other")
        other.jsName = "first"
        let duplicateScripts = [first, other]
        await #expect(throws: CodemodeRuntimeProtocolError.invalidToolName("other")) {
            _ = try await deterministicStart("", forceWatchdog: forceWatchdog, tools: duplicateScripts)
        }
    }

    @Test(arguments: [false, true])
    func nonfiniteStoreValuesRejectBeforeStart(forceWatchdog: Bool) async throws {
        let callbacks = LockedState(0)
        for number in [Double.nan, .infinity, -.infinity] {
            await #expect(throws: CodemodeRuntimeProtocolError.invalidJSON) {
                _ = try await JSCCodemodeEngine.start(code: "return 1", options: .init(
                    startedAt: deterministicStartedAt, seed: 1,
                    store: ["bad": AnyCodable(number)], forceWatchdog: forceWatchdog,
                    onStarted: { _, _ in callbacks.withLock { $0 += 1 } },
                    onCall: { _, _ in callbacks.withLock { $0 += 1 } }))
            }
        }
        #expect(callbacks.withLock { $0 } == 0)
    }

    @Test(arguments: [false, true])
    func bufferedReplyConsumesItsCallBeforeEarlierReplyArrives(forceWatchdog: Bool) async throws {
        let recorded = try await deterministicStart("""
        const order = [];
        await Promise.all([tools.wait('a').then(() => order.push('a')),
          tools.wait('b').then(() => order.push('b'))]); return order;
        """, forceWatchdog: forceWatchdog)
        try await deterministicWait(recorded, calls: 2, idles: 1)
        try await recorded.run.deliver(seq: 2, now: deterministicStartedAt + 2000,
                                        id: 1, outcome: .success(json: "null"))
        #expect(await recorded.run.finished == false)
        await #expect(throws: CodemodeRuntimeProtocolError.callNotWaiting(1)) {
            try await recorded.run.deliver(seq: 3, now: deterministicStartedAt, id: 1,
                                            outcome: .success(json: "null"))
        }
        await #expect(throws: CodemodeRuntimeProtocolError.invalidSequence(2)) {
            try await recorded.run.deliver(seq: 2, now: deterministicStartedAt, id: 2,
                                            outcome: .success(json: "null"))
        }
        try await recorded.run.deliver(seq: 1, now: deterministicStartedAt + 1000,
                                        id: 2, outcome: .success(json: "null"))
        let result = await recorded.run.result
        #expect(result.execution.returnedValue == AnyCodable(["b", "a"]))
    }

    @Test(arguments: [false, true])
    func terminalWorkerCancelsUnawaitedCalls(forceWatchdog: Bool) async throws {
        let calls = LockedState<[CodemodeRuntimeCall]>([])
        let run = try await JSCCodemodeEngine.start(code: "tools.wait('unawaited'); return 'done'", options: .init(
            startedAt: deterministicStartedAt, seed: 1, tools: [.init(name: "wait")],
            timeoutMs: 5000, forceWatchdog: forceWatchdog,
            onCall: { call, _ in calls.withLock { $0.append(call) } }))
        let result = await run.result
        #expect(result.execution.returnedValue == AnyCodable("done"))
        let call = try #require(calls.withLock { $0.first })
        #expect(call.signal.isCancelled)
        #expect(result.unfinishedCalls.count == 1)
        let unfinished = try #require(result.unfinishedCalls.first)
        #expect(unfinished.id == call.id)
        #expect(unfinished.name == "wait")
        #expect(unfinished.argsJSON == "\"unawaited\"")
        #expect(unfinished.signal === call.signal)
        #expect(unfinished.signal.isCancelled)
        #expect(result.during == .init(seq: 0, issued: 1))
    }

    @Test(arguments: [false, true])
    func deterministicStoreLoadAndOutputWorkTogether(forceWatchdog: Bool) async throws {
        let code = """
        const count = load('count') + 1;
        const answer = await tools.echo({count, now: Date.now(), random: Math.random()});
        store('count', count); store('answer', answer); store('remove', undefined);
        text(JSON.stringify(answer)); text(Date.now());
        return [load('count'), load('answer'), load('remove') === undefined];
        """
        let initial = ["count": AnyCodable(2), "remove": AnyCodable("old")]
        let first = try await deterministicStart(code, forceWatchdog: forceWatchdog, store: initial)
        let second = try await deterministicStart(code, forceWatchdog: forceWatchdog, store: initial)
        let one = await first.run.result
        let two = await second.run.result
        #expect(one.execution.failure == nil)
        #expect(one.execution.returnedValue == two.execution.returnedValue)
        #expect(deterministicText(one) == deterministicText(two))
        let answer = try deterministicJSON(#"{"count":3,"now":1768471200000,"random":0.6270739405881613}"#)
        #expect(one.storeWrites.set == ["count": AnyCodable(3), "answer": answer])
        #expect(one.storeWrites.delete == ["remove"])
        #expect(two.storeWrites.set == one.storeWrites.set)
        #expect(two.storeWrites.delete == one.storeWrites.delete)
        let output = deterministicText(one)
        #expect(output.count == 2)
        #expect(try deterministicJSON(try #require(output.first)) == answer)
        #expect(output.last == "1768471201000")
        #expect(one.execution.returnedValue == AnyCodable([3, answer.value, true] as [Any]))
    }

    @Test(arguments: [false, true])
    func dateConstructionAndLocalMethodsUseUTC(forceWatchdog: Bool) async throws {
        let recorded = try await deterministicStart("""
        class DerivedDate extends Date {}
        const original = new Date('2026-01-15T10:00:00');
        const clone = new Date(original);
        const derived = new DerivedDate();
        const suffixes = ['FullYear','Month','Date','Day','Hours','Minutes','Seconds','Milliseconds'];
        const gettersMatch = suffixes.every(s => original['get' + s]() === original['getUTC' + s]());
        const setters = [['FullYear',[2030,2,3]],['Month',[6,7]],['Date',[8]],
          ['Hours',[9,10,11,12]],['Minutes',[13,14,15]],['Seconds',[16,17]],['Milliseconds',[18]]];
        const settersMatch = setters.every(([suffix,args]) => {
          const local = new Date(original), utc = new Date(original);
          return local['set' + suffix](...args) === utc['setUTC' + suffix](...args)
            && local.getTime() === utc.getTime();
        });
        const legacy = new Date(0); legacy.setYear(99);
        return [Date.prototype.constructor.now() === Date.now(), clone.getTime() === original.getTime(),
          clone !== original, derived instanceof DerivedDate, derived instanceof Date,
          derived.getTime() === Date.now(), gettersMatch, settersMatch,
          legacy.getYear() === 99 && legacy.getUTCFullYear() === 1999,
          original.toDateString() === 'Thu Jan 15 2026',
          original.toTimeString() === '10:00:00 GMT+0000 (Coordinated Universal Time)',
          original.toString() === 'Thu Jan 15 2026 10:00:00 GMT+0000 (Coordinated Universal Time)',
          Date() === new Date().toString(),
          Number.isNaN(Date.parse('January 15, 2026 10:00:00')),
          new Date('January 15, 2026 10:00:00').toString() === 'Invalid Date',
          Number.isNaN(Date.parse('01-01-2026')),
          Number.isNaN(Date.parse('Jan 01 2026 (GMT )')),
          Date.parse(original.toString()) === original.getTime(),
          Date.parse(original.toUTCString()) === original.getTime()];
        """, forceWatchdog: forceWatchdog)
        let result = await recorded.run.result
        #expect(result.execution.failure == nil)
        #expect(result.execution.returnedValue == AnyCodable(Array(repeating: true, count: 19)))
    }

    @Test(arguments: [false, true])
    func intlDefaultsToUTCAndVirtualTime(forceWatchdog: Bool) async throws {
        let recorded = try await deterministicStart("""
        const options = {hour:'2-digit', minute:'2-digit', second:'2-digit', hourCycle:'h23'};
        const formatter = new Intl.DateTimeFormat('en-US', options);
        const zone = new Intl.DateTimeFormat('en-US', {...options, timeZone:'Asia/Kolkata'});
        const before = formatter.format();
        const partsMatch = JSON.stringify(formatter.formatToParts()) === JSON.stringify(formatter.formatToParts(Date.now()));
        const explicitMatches = formatter.format() === formatter.format(Date.now());
        const locale = new Date().toLocaleTimeString('en-US', options);
        await tools.echo(1);
        return [formatter.resolvedOptions().timeZone, before, formatter.format(),
          zone.format(), partsMatch, explicitMatches, locale,
          formatter.format() === formatter.format(Date.now())];
        """, forceWatchdog: forceWatchdog)
        let result = await recorded.run.result
        #expect(result.execution.failure == nil)
        #expect(result.execution.returnedValue == (try deterministicJSON(
            #"["UTC","10:00:00","10:00:01","15:30:01",true,true,"10:00:00",true]"#)))
    }

    @Test(arguments: [false, true])
    func fractionalVirtualTimesUseMathRound(forceWatchdog: Bool) async throws {
        let recorded = try await deterministicStart("""
        const before = [Date.now(), performance.now(), new Date().getTime()];
        await tools.wait(1);
        return [before, [Date.now(), performance.now(), new Date().getTime()]];
        """, forceWatchdog: forceWatchdog, startedAt: deterministicStartedAt + 0.4)
        try await deterministicWait(recorded, calls: 1)
        try await recorded.run.deliver(seq: 1, now: deterministicStartedAt + 1000.6,
                                        id: 1, outcome: .success(json: "null"))
        let result = await recorded.run.result
        #expect(result.execution.returnedValue == AnyCodable([
            [Int(deterministicStartedAt), 0, Int(deterministicStartedAt)],
            [Int(deterministicStartedAt + 1001), 1000, Int(deterministicStartedAt + 1001)]]))
    }

    @Test(arguments: [false, true])
    func localeDefaultsAreStableAndSupportedLocalesRemainAvailable(forceWatchdog: Bool) async throws {
        let recorded = try await deterministicStart("""
        return [new Intl.DateTimeFormat([]).resolvedOptions().locale,
          new Intl.DateTimeFormat(['zz']).resolvedOptions().locale,
          new Intl.DateTimeFormat([]).resolvedOptions().timeZone,
          new Intl.NumberFormat(['zz']).resolvedOptions().locale,
          (1234567.89).toLocaleString([]),
          new Intl.NumberFormat(['zz']).format(1234567.89),
          'i'.toLocaleUpperCase([]), 'i'.toLocaleUpperCase(['zz']),
          'i'.toLocaleUpperCase('tr'), 'İ'.toLocaleLowerCase([]),
          'İ'.toLocaleLowerCase('tr'),
          new Intl.DateTimeFormat('fr-FR').resolvedOptions().locale,
          new Intl.NumberFormat('de-DE').format(1234567.89),
          new Intl.DateTimeFormat(['zz','de-DE']).resolvedOptions().locale];
        """, forceWatchdog: forceWatchdog)
        let result = await recorded.run.result
        #expect(result.execution.failure == nil)
        #expect(result.execution.returnedValue == (try deterministicJSON(
            #"["en-US","en-US","UTC","en-US","1,234,567.89","1,234,567.89","I","I","İ","i̇","i","fr-FR","1.234.567,89","de-DE"]"#)))
    }
    @Test(arguments: [false, true])
    func rawJSONRepliesKeepNestedValuesAndEscapes(forceWatchdog: Bool) async throws {
        let recorded = try await deterministicStart("return await tools.wait()", forceWatchdog: forceWatchdog)
        try await deterministicWait(recorded, calls: 1)
        let json = #"{"empty":[],"object":{},"unicode":"é😀","text":"\"\\\/\b\f\n\r\t\u0041","numbers":[-0,1,-2,1.25,1e3,1E-2,2e+2],"values":[true,false,null]}"#
        try await recorded.run.deliver(seq: 1, now: deterministicStartedAt, id: 1, outcome: .success(json: json))
        let result = await recorded.run.result
        #expect(result.execution.failure == nil)
        #expect(result.execution.returnedValue == (try deterministicJSON(json)))
    }

    @Test(arguments: [false, true])
    func rawJSONCanCarryLoneSurrogatesThroughCallsAndReplies(forceWatchdog: Bool) async throws {
        let arguments = LockedState<String?>(nil)
        let run = try await JSCCodemodeEngine.start(code: """
        const value = await tools.echo(String.fromCharCode(0xd800));
        return [value.charCodeAt(0), value.length];
        """, options: .init(startedAt: deterministicStartedAt, seed: 1,
                            tools: [.init(name: "echo")], timeoutMs: 5000, forceWatchdog: forceWatchdog,
                            onCall: { call, run in
            arguments.withLock { $0 = call.argsJSON }
            do {
                try await run.deliver(seq: 1, now: deterministicStartedAt, id: call.id,
                                      outcome: .success(json: call.argsJSON))
            } catch { Issue.record("Reply failed: \(error)") }
        }))
        let result = await run.result
        #expect(arguments.withLock { $0 } == #""\ud800""#)
        #expect(result.execution.failure == nil)
        #expect(result.execution.returnedValue == AnyCodable([0xd800, 1]))

        let rejected = try await deterministicStart("""
        try { await tools.echo(1); } catch (error) {
          return [error.value.charCodeAt(0), error.value.length];
        }
        """, forceWatchdog: forceWatchdog, answer: { _ in
            .failure(message: "x", propertiesJSON: #"{"value":"\ud800"}"#)
        })
        let rejectionResult = await rejected.run.result
        #expect(rejectionResult.execution.failure == nil)
        #expect(rejectionResult.execution.returnedValue == AnyCodable([0xd800, 1]))
    }

}
