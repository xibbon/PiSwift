import Foundation
import Testing
import PiSwiftChord
import PiSwiftDurable
import PiSwiftDurableTesting

private actor CodemodeProtocolTrace {
    var events: [String] = []
    var calls: [CodemodeHostCall] = []
    var idles: [CodemodeDuring] = []
    func started(_ value: String) { events.append("started \(value)") }
    func call(_ value: CodemodeHostCall) { calls.append(value); events.append("call \(value.id)") }
    func idle(_ seq: Int, _ issued: Int) {
        idles.append(.init(seq: seq, issued: issued)); events.append("idle \(seq)")
    }
    func options(tools: [CodemodeDeclaredTool] = [.init(name: "wait")],
                 globals: [CodemodeDeclaredGlobal] = []) -> CodemodeRunOptions {
        .init(startedAt: 1000, seed: 1, tools: tools, globals: globals,
              onStarted: { value, _ in await self.started(value) },
              onCall: { call, _ in await self.call(call) },
              onIdle: { seq, issued, _ in await self.idle(seq, issued) })
    }
}

@Suite("Codemode deterministic sandbox protocol")
struct CodemodeSandboxProtocolTests {
    @Test("Applies out-of-order deliveries in sequence order")
    func orderedDelivery() async throws {
        let sandbox = DeterministicCodemodeSandbox { state in
            if state.seq == 0 {
                return .init(calls: [.init(name: "wait", args: "a"), .init(name: "wait", args: "b")])
            }
            if state.seq == 2 { return .init(result: .init(value: .array(state.deliveries.map { .number(Double($0.id)) }))) }
            return .init()
        }
        let trace = CodemodeProtocolTrace()
        let run = try await sandbox.start(source: "script", name: "ordered", options: await trace.options())
        try await run.deliver(seq: 2, now: 3000, id: 1, outcome: .success(.null))
        #expect(await trace.idles == [.init(seq: 0, issued: 2)])
        try await run.deliver(seq: 1, now: 2000, id: 2, outcome: .success(.null))
        let result = await run.result
        #expect(result.value == [2, 1])
        #expect(result.during == .init(seq: 2, issued: 2))
        #expect(await trace.idles == [.init(seq: 0, issued: 2), .init(seq: 1, issued: 2)])
        #expect(await run.finished)
    }

    @Test("Reports fingerprint first and the issued call count after each delivery")
    func fingerprintAndBatches() async throws {
        let sandbox = DeterministicCodemodeSandbox(fingerprint: "fixed-v1") { state in
            switch state.seq {
            case 0: .init(calls: [.init(name: "wait", args: 1)])
            case 1: .init(calls: [.init(name: "wait", args: 2), .init(name: "wait", args: 3)])
            case 3: .init(result: .init(value: 3))
            default: .init()
            }
        }
        let trace = CodemodeProtocolTrace()
        let run = try await sandbox.start(source: "script", name: "batch", options: await trace.options())
        #expect(await trace.events == ["started fixed-v1", "call 1", "idle 0"])
        for index in 1...3 { try await run.deliver(seq: index, now: Double(index), id: index, outcome: .success(.null)) }
        #expect(await trace.idles == [.init(seq: 0, issued: 1), .init(seq: 1, issued: 3), .init(seq: 2, issued: 3)])
        #expect(await run.result.during == .init(seq: 3, issued: 3))
    }

    @Test("Globals share call IDs and do not enter tool records")
    func globalsAndErrorProperties() async throws {
        let sandbox = DeterministicCodemodeSandbox { state in
            switch state.seq {
            case 0: .init(calls: [.init(target: .global, name: "search", args: ["x", 2])])
            case 1: .init(calls: [.init(name: "wait", args: "fail")])
            default: .init(result: .init(value: .object(state.deliveries.last!.outcome.errorProperties)))
            }
        }
        let trace = CodemodeProtocolTrace()
        let options = await trace.options(globals: [.init(name: "search", spread: true)])
        let run = try await sandbox.start(source: "script", name: "globals", options: options)
        try await run.deliver(seq: 1, now: 1000, id: 1, outcome: .success(["found"]))
        try await run.deliver(seq: 2, now: 1001, id: 2,
                              outcome: .failure(message: "denied", properties: ["structuredOutput": ["code": 7], "name": "Ignored", "message": "ignored", "stack": "ignored"]))
        let result = await run.result
        #expect(result.value == ["structuredOutput": ["code": 7]])
        #expect(result.calls == [.init(name: "wait", status: .error)])
        #expect(await trace.calls == [.init(id: 1, target: .global, name: "search", args: ["x", 2]),
                                     .init(id: 2, target: .tool, name: "wait", args: "fail")])
    }

    @Test("Keeps time monotonic and invalid JSON leaves the call waiting")
    func clockAndJSONBoundary() async throws {
        let sandbox = DeterministicCodemodeSandbox { state in
            state.seq == 0 ? .init(calls: [.init(name: "wait")]) : .init(result: .init(value: .number(state.now)))
        }
        let run = try await sandbox.start(source: "script", name: "clock", options: .init(startedAt: 1000, seed: 1, tools: [.init(name: "wait")]))
        await #expect(throws: CodemodeProtocolError.invalidClock) {
            try await run.deliver(seq: 1, now: .nan, id: 1, outcome: .success(.null))
        }
        await #expect(throws: CodemodeProtocolError.invalidJSON) {
            try await run.deliver(seq: 1, now: 1000, id: 1, outcome: .success(["bad": .number(.infinity)]))
        }
        await #expect(throws: CodemodeProtocolError.invalidJSON) {
            try await run.deliver(seq: 1, now: 1000, id: 1, outcome: .failure(message: "x", properties: ["bad": .number(.nan)]))
        }
        try await run.deliver(seq: 1, now: -1000, id: 1, outcome: .success(.null))
        #expect(await run.result.value == 1000)
    }

    @Test("Rejects duplicate sequence numbers and calls that are not waiting")
    func invalidDelivery() async throws {
        let sandbox = DeterministicCodemodeSandbox { state in
            state.seq == 0 ? .init(calls: [.init(name: "wait"), .init(name: "wait")]) :
                state.seq == 2 ? .init(result: .init()) : .init()
        }
        let run = try await sandbox.start(source: "script", name: "invalid", options: .init(startedAt: 0, seed: 1, tools: [.init(name: "wait")]))
        await #expect(throws: CodemodeProtocolError.callNotWaiting(99)) {
            try await run.deliver(seq: 1, now: 0, id: 99, outcome: .success(.null))
        }
        try await run.deliver(seq: 1, now: 0, id: 1, outcome: .success(.null))
        await #expect(throws: CodemodeProtocolError.invalidSequence(1)) {
            try await run.deliver(seq: 1, now: 0, id: 2, outcome: .success(.null))
        }
        await #expect(throws: CodemodeProtocolError.invalidSequence(0)) {
            try await run.deliver(seq: 0, now: 0, id: 2, outcome: .success(.null))
        }
        await #expect(throws: CodemodeProtocolError.callNotWaiting(1)) {
            try await run.deliver(seq: 2, now: 0, id: 1, outcome: .success(.null))
        }
        try await run.deliver(seq: 2, now: 0, id: 2, outcome: .success(.null))
        #expect(await run.result.ok)
    }

    @Test("Abort selects one result and cancels pending tool records")
    func abort() async throws {
        let sandbox = DeterministicCodemodeSandbox { _ in .init(calls: [.init(name: "wait")], output: [.text("before")]) }
        let run = try await sandbox.start(source: "script", name: "abort", options: .init(startedAt: 0, seed: 1, tools: [.init(name: "wait")]))
        #expect(await !run.finished)
        await run.abort(message: "diverged")
        #expect(await run.finished)
        let result = await run.result
        #expect(result.error == .init(kind: .aborted, message: "diverged"))
        #expect(result.output == [.text("before")])
        #expect(result.calls == [.init(name: "wait", status: .cancelled)])
        #expect(result.during == nil)
        #expect(result.storeWrites == nil)
        try await run.deliver(seq: 0, now: .nan, id: 99, outcome: .success(.null))
        await run.abort(message: "later")
        #expect(await run.result == result)
    }

    @Test("Captures stable names, source, seed, time, store, and declarations")
    func capturesStart() async throws {
        let sandbox = DeterministicCodemodeSandbox { state in
            .init(result: .init(value: state.options.store["value"], storeWrites: .init(set: ["next": 2], delete: ["old"])))
        }
        let options = CodemodeRunOptions(startedAt: 123, seed: 0, tools: [.init(name: "my-tool", jsName: "renamed", description: "Example")],
                                         globals: [.init(name: "host.search", spread: true)], store: ["value": 1], timeoutMs: 10000)
        let run = try await sandbox.start(source: "return 1", name: "stable", options: options)
        let starts = await sandbox.starts
        #expect(starts.count == 1)
        #expect(starts[0].source == "return 1")
        #expect(starts[0].name == "stable")
        #expect(starts[0].options.startedAt == 123)
        #expect(starts[0].options.seed == 0)
        #expect(starts[0].options.store == ["value": 1])
        #expect(starts[0].options.tools[0].scriptName == "renamed")
        #expect(starts[0].options.globals == options.globals)
        #expect(starts[0].options.timeoutMs == 10000)
        let result = await run.result
        #expect(result.value == 1)
        #expect(result.during == .init(seq: 0, issued: 0))
        #expect(result.storeWrites == .init(set: ["next": 2], delete: ["old"]))
    }

    @Test("Validates tool and global names before start")
    func declarationValidation() async throws {
        let sandbox = DeterministicCodemodeSandbox()
        await #expect(throws: CodemodeProtocolError.invalidToolName("a_b")) {
            _ = try await sandbox.start(source: "", name: "names", options: .init(startedAt: 0, seed: 1, tools: [.init(name: "a-b"), .init(name: "a_b")]))
        }
        for globals in [[CodemodeDeclaredGlobal(name: "text")], [.init(name: "a.b.c")], [.init(name: "a"), .init(name: "a.b")], [.init(name: "a"), .init(name: "a")]] {
            await #expect(throws: CodemodeProtocolError.self) {
                _ = try await sandbox.start(source: "", name: "names", options: .init(startedAt: 0, seed: 1, globals: globals))
            }
        }
        await #expect(throws: CodemodeProtocolError.invalidSourceName) {
            _ = try await sandbox.start(source: "", name: "", options: .init(startedAt: 0, seed: 1))
        }
        #expect(await sandbox.starts.isEmpty)
        #expect(codemodeIdentifier("1 a-😀") == "__a__")
    }

    @Test("Callbacks can deliver through the run before start returns")
    func callbackDelivery() async throws {
        let sandbox = DeterministicCodemodeSandbox { state in
            state.seq == 0 ? .init(calls: [.init(name: "echo", args: 7)]) : .init(result: .init(value: 7))
        }
        let options = CodemodeRunOptions(startedAt: 0, seed: 1, tools: [.init(name: "echo")], onCall: { call, run in
            try? await run.deliver(seq: call.id, now: 1, id: call.id, outcome: .success(call.args))
        })
        let run = try await sandbox.start(source: "script", name: "callback", options: options)
        #expect(await run.finished)
        #expect(await run.result.value == 7)
    }

    @Test("The same plan, start, and deliveries produce the same result")
    func repeatablePlan() async throws {
        let sandbox = DeterministicCodemodeSandbox { state in
            state.seq == 0 ? .init(calls: [.init(name: "wait", args: .number(Double(state.options.seed)))]) :
                .init(result: .init(value: .array([.number(state.options.startedAt), .number(state.now), state.calls[0].args ?? .null])))
        }
        let options = CodemodeRunOptions(startedAt: 100, seed: 42, tools: [.init(name: "wait")])
        let first = try await sandbox.start(source: "same", name: "same", options: options)
        let second = try await sandbox.start(source: "same", name: "same", options: options)
        try await first.deliver(seq: 1, now: 120, id: 1, outcome: .success("same"))
        try await second.deliver(seq: 1, now: 120, id: 1, outcome: .success("same"))
        #expect(await first.result == second.result)
    }

    @Test("Outcome JSON preserves undefined and null and rejects invalid rejection properties")
    func outcomeCoding() throws {
        let decoder = JSONDecoder()
        let encoder = JSONEncoder()
        let missing = try decoder.decode(CodemodeOutcome.self, from: Data(#"{"ok":true}"#.utf8))
        let null = try decoder.decode(CodemodeOutcome.self, from: Data(#"{"ok":true,"value":null}"#.utf8))
        #expect(missing == .success(nil))
        #expect(null == .success(.null))
        #expect(missing != null)
        let noArgs = try decoder.decode(CodemodeHostCall.self, from: Data(#"{"id":1,"target":"tool","name":"echo"}"#.utf8))
        let nullArgs = try decoder.decode(CodemodeHostCall.self, from: Data(#"{"id":1,"target":"tool","name":"echo","args":null}"#.utf8))
        #expect(noArgs.args == Optional<JSONValue>.none)
        #expect(nullArgs.args == Optional.some(JSONValue.null))
        let successTree = try decoder.decode(JSONValue.self, from: encoder.encode(null))
        #expect(successTree == ["ok": true, "value": .null])
        let failure = CodemodeOutcome.failure(message: "denied", properties: ["structuredOutput": ["code": 7]])
        let failureTree = try decoder.decode(JSONValue.self, from: encoder.encode(failure))
        #expect(failureTree == ["ok": false, "message": "denied", "properties": ["structuredOutput": ["code": 7]]])
        #expect(try decoder.decode(CodemodeOutcome.self, from: encoder.encode(failure)) == failure)
        for properties in ["null", "[1]", "7", "true", #""text""#] {
            let input = "{\"ok\":false,\"message\":\"x\",\"properties\":\(properties)}"
            #expect(throws: (any Error).self) { try decoder.decode(CodemodeOutcome.self, from: Data(input.utf8)) }
        }
    }

    @Test("Script failure reports during, keeps output, and discards writes")
    func scriptFailureDuring() async throws {
        let sandbox = DeterministicCodemodeSandbox { state in
            if state.seq == 0 { return .init(calls: [.init(name: "wait")], output: [.text("before", console: true)]) }
            return .init(result: .init(error: .init(kind: .script, name: "Error", message: "x", stack: "script:2"),
                                       storeWrites: .init(set: ["discard": 1])))
        }
        let run = try await sandbox.start(source: "script", name: "throw", options: .init(startedAt: 0, seed: 1, tools: [.init(name: "wait")]))
        try await run.deliver(seq: 1, now: 1, id: 1, outcome: .success(nil))
        let result = await run.result
        #expect(result.error == .init(kind: .script, name: "Error", message: "x", stack: "script:2"))
        #expect(result.during == .init(seq: 1, issued: 1))
        #expect(result.output == [.text("before", console: true)])
        #expect(result.storeWrites == nil)
        let data = try JSONEncoder().encode(result)
        let decoded = try JSONDecoder().decode(CodemodeResult.self, from: data)
        #expect(decoded.value == Optional<JSONValue>.none)
        #expect(decoded == result)
        #expect(try JSONDecoder().decode(JSONValue.self, from: data)["ok"] == false)
    }

    @Test("Start rejects negative or non-finite epoch time without recording a run")
    func startTimeValidation() async throws {
        let sandbox = DeterministicCodemodeSandbox()
        for startedAt in [-1.0, .nan, .infinity, -.infinity] {
            await #expect(throws: CodemodeProtocolError.invalidClock) {
                _ = try await sandbox.start(source: "", name: "time", options: .init(startedAt: startedAt, seed: 1))
            }
        }
        #expect(await sandbox.starts.isEmpty)
        let run = try await sandbox.start(source: "", name: "no-deadline", options: .init(startedAt: 0, seed: UInt32.max, timeoutMs: .infinity))
        #expect(await run.result.ok)
    }


    @Test("Tool names use UTF-16 identity rather than normalized Swift equality")
    func toolNameIdentity() async throws {
        let composed = "\u{e9}", decomposed = "e\u{301}"
        #expect(CodemodeDeclaredTool(name: composed) != CodemodeDeclaredTool(name: decomposed))
        #expect(CodemodeHostCall(id: 1, target: .tool, name: composed) != CodemodeHostCall(id: 1, target: .tool, name: decomposed))
        #expect(CodemodeOutcome.failure(message: composed) != CodemodeOutcome.failure(message: decomposed))
        #expect(CodemodeOutputItem.text(composed) != CodemodeOutputItem.text(decomposed))
        let sandbox = DeterministicCodemodeSandbox { state in
            if state.seq == 0 {
                return .init(calls: [.init(name: composed, args: 1), .init(name: decomposed, args: 2)])
            }
            return state.seq == 2 ? .init(result: .init(value: "done")) : .init()
        }
        let trace = CodemodeProtocolTrace()
        let options = await trace.options(tools: [.init(name: composed, jsName: "composed"),
                                                  .init(name: decomposed, jsName: "decomposed")])
        let run = try await sandbox.start(source: "script", name: "unicode", options: options)
        let calls = await trace.calls
        #expect(calls.count == 2)
        #expect(calls[0].name.utf16.elementsEqual(composed.utf16))
        #expect(calls[1].name.utf16.elementsEqual(decomposed.utf16))
        #expect(!calls[0].name.utf16.elementsEqual(calls[1].name.utf16))
        try await run.deliver(seq: 1, now: 1000, id: 1, outcome: .success(1))
        try await run.deliver(seq: 2, now: 1000, id: 2, outcome: .success(2))
        #expect(await run.result.ok)

        // A normalized match cannot authorize a call to a different name.
        let mismatch = DeterministicCodemodeSandbox { _ in .init(calls: [.init(name: decomposed)]) }
        let rejected = try await mismatch.start(source: "script", name: "unicode-mismatch", options: .init(startedAt: 0, seed: 1,
                                                tools: [.init(name: composed, jsName: "composed")]))
        #expect(await rejected.result.error?.kind == .sandbox)
    }

    @Test("Close aborts active runs and rejects future starts")
    func close() async throws {
        let sandbox = DeterministicCodemodeSandbox { _ in .init(calls: [.init(name: "wait")]) }
        let options = CodemodeRunOptions(startedAt: 0, seed: 1, tools: [.init(name: "wait")])
        let first = try await sandbox.start(source: "script", name: "first", options: options)
        let second = try await sandbox.start(source: "script", name: "second", options: options)
        await sandbox.close()
        #expect(await first.finished)
        #expect(await second.finished)
        #expect(await first.result.error == .init(kind: .aborted, message: "Sandbox closed"))
        #expect(await second.result.error == .init(kind: .aborted, message: "Sandbox closed"))
        await #expect(throws: CodemodeError(kind: .sandbox, message: "Sandbox is closed")) {
            _ = try await sandbox.start(source: "script", name: "later", options: options)
        }
        await sandbox.close()
        #expect(await sandbox.starts.count == 2)
    }


    @Test("Store and error property objects retain distinct UTF-16 keys and property order")
    func objectKeyIdentityAndOrder() async throws {
        let composed = "\u{e9}", decomposed = "e\u{301}"
        let values = JSONObject([(composed, 1), (decomposed, 2)])
        let expectedKeys = [Array(composed.utf16), Array(decomposed.utf16)]
        let sandbox = DeterministicCodemodeSandbox { state in
            .init(result: .init(value: .object(state.options.store), storeWrites: .init(set: state.options.store)))
        }
        let run = try await sandbox.start(source: "script", name: "object-keys", options: .init(startedAt: 0, seed: 1, store: values))
        let starts = await sandbox.starts
        #expect(starts[0].options.store.count == 2)
        #expect(starts[0].options.store.keys.map { Array($0.utf16) } == expectedKeys)
        let result = await run.result
        #expect(result.value == .object(values))
        #expect(result.storeWrites?.set.count == 2)
        let resultTree = try JSONValue(encoding: result)
        let decodedResult = try resultTree.decode(CodemodeResult.self)
        #expect(decodedResult.storeWrites?.set.keys.map { Array($0.utf16) } == expectedKeys)
        #expect(decodedResult.storeWrites?.set[composed] == 1)
        #expect(decodedResult.storeWrites?.set[decomposed] == 2)

        var properties = values
        properties["name"] = "Ignored"
        properties["message"] = "ignored"
        properties["stack"] = "ignored"
        let outcome = CodemodeOutcome.failure(message: "denied", properties: properties)
        let decoded = try JSONValue(encoding: outcome).decode(CodemodeOutcome.self)
        #expect(decoded.errorProperties.count == 2)
        #expect(decoded.errorProperties.keys.map { Array($0.utf16) } == expectedKeys)
        #expect(decoded.errorProperties[composed] == 1)
        #expect(decoded.errorProperties[decomposed] == 2)
        // The Chord JSON text boundary retains key identity and property order.
        let encoded = try JSONValue(encoding: outcome).jsonText()
        let textDecoded = try JSONValue(jsonText: encoded).decode(CodemodeOutcome.self)
        #expect(textDecoded.errorProperties == values)
        #expect(textDecoded.errorProperties.keys.map { Array($0.utf16) } == expectedKeys)
    }

}
