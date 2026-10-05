import Foundation
import JavaScriptCore
import Testing
import PiSwiftAI
@testable import PiSwiftCodingAgent

private func v104Value(_ result: CodemodeRuntimeResult) throws -> String? {
    try result.execution.returnedValue.map { String(decoding: try JSONEncoder().encode($0), as: UTF8.self) }
}

private func v104Run(_ code: String, forceWatchdog: Bool = false,
                     tools: [CodemodeRuntimeTool] = [],
                     onCall: @escaping @Sendable (CodemodeRuntimeCall) async -> CodemodeRuntimeReply = { _ in
                         .init(ok: false, payloadJSON: "Unexpected call")
                     }) async -> CodemodeRuntimeResult {
    await CodemodeSandbox.execute(code: code, tools: tools, timeoutMs: 3_000,
                                  forceWatchdog: forceWatchdog, onCall: onCall)
}

private struct V104BridgeCase: Sendable {
    var calls: String
    var reason: String
}

private let v104BridgeCases: [V104BridgeCase] = [
    // Upstream #10444: sandbox.test.ts:655-671 (the seven raw-worker cases).
    .init(calls: #"bridge("done", "true", "1", "null");"#, reason: "store writes are not an array"),
    .init(calls: #"bridge("done", "true", "1", "[1]");"#, reason: "store writes contain a malformed entry"),
    .init(calls: #"bridge("done", "true", "1", '[["k", "{"]]');"#, reason: #"store value for "k" is not valid JSON"#),
    .init(calls: #"bridge("done", "true", "{", "[]");"#, reason: "return value is not valid JSON"),
    .init(calls: #"bridge("done", "true", "undefined", "[]");"#, reason: "return value is not valid JSON"),
    .init(calls: #"bridge("done", "false", "5");"#, reason: "script error is not an object"),
    .init(calls: #"bridge("done", "false", "{}");"#, reason: "script error is malformed"),
    .init(calls: #"bridge("nonsense");"#, reason: "unknown message from the worker"),
    // Check the other validated JSON fields and each store entry shape.
    .init(calls: #"bridge("done", "true", "1", "{");"#, reason: "store writes is not valid JSON"),
    .init(calls: #"bridge("done", "true", "1", "[[]]");"#, reason: "store writes contain a malformed entry"),
    .init(calls: #"bridge("done", "true", "1", "[[1]]");"#, reason: "store writes contain a malformed entry"),
    .init(calls: #"bridge("done", "true", "1", '[["k", null]]');"#, reason: "store writes contain a malformed entry"),
    .init(calls: #"bridge("done", "true", "1", '[["k", "1", "2"]]');"#, reason: "store writes contain a malformed entry"),
    .init(calls: #"bridge("done", "false", "{");"#, reason: "script error is not valid JSON"),
    .init(calls: #"bridge("done", "false", "null");"#, reason: "script error is not an object"),
    .init(calls: #"bridge("done", "false", "[]");"#, reason: "script error is malformed"),
    .init(calls: #"bridge("done", "false", '{"message":1}');"#, reason: "script error is malformed"),
    .init(calls: #"bridge("done", "false", '{"message":"x", "name":1}');"#, reason: "script error is malformed"),
    .init(calls: #"bridge("done", "false", '{"message":"x", "stack":null}');"#, reason: "script error is malformed"),
    // Swift has a direct bridge. Bad call or output fields must fail the run.
    .init(calls: #"bridge("call", "not-a-number", "echo", "1");"#, reason: "unknown message from the worker"),
    .init(calls: #"bridge("call", "1");"#, reason: "unknown message from the worker"),
    .init(calls: #"bridge("call", "1", null);"#, reason: "unknown message from the worker"),
    .init(calls: #"bridge("call", "1", 5);"#, reason: "unknown message from the worker"),
    .init(calls: #"bridge("global", undefined, "echo");"#, reason: "unknown message from the worker"),
    .init(calls: #"bridge("global", "1");"#, reason: "unknown message from the worker"),
    .init(calls: #"bridge("output", "text");"#, reason: "unknown message from the worker"),
    .init(calls: #"bridge("output", "image");"#, reason: "unknown message from the worker"),
    .init(calls: #"bridge("output", "image", null);"#, reason: "unknown message from the worker"),
    .init(calls: #"bridge("output", "text", null);"#, reason: "unknown message from the worker"),
    .init(calls: #"bridge("output", "nonsense", "x");"#, reason: "unknown message from the worker"),
    .init(calls: #"bridge("call", "7", "echo"); bridge("global", "7", "other");"#, reason: "duplicate call id 7"),
]

private func v104RawPrelude(_ calls: String) -> String {
    """
    (function(bridge) {
        return { run() { \(calls) }, settle() {}, stalled() {} };
    })
    """
}

@Test(.timeLimit(.minutes(1)), arguments: v104BridgeCases)
private func codemodeV104RejectsBrokenBridge(_ testCase: V104BridgeCase) async {
    let result = await CodemodeSandbox.execute(code: "", tools: [], timeoutMs: 3_000,
        preludeSource: v104RawPrelude(testCase.calls), onCall: { call in
            // Keep call IDs pending until the failed run cancels them.
            while !call.signal.isCancelled { try? await Task.sleep(for: .milliseconds(10)) }
            return .init(ok: false)
        })
    #expect(result.execution.failure?.kind == .sandbox)
    #expect(result.execution.failure?.message == "Sandbox bridge broken: \(testCase.reason). The script may have modified built-ins such as a prototype's toJSON.")
    #expect(result.execution.returnedValue == nil)
    #expect(result.storeWrites.set.isEmpty)
    #expect(result.storeWrites.delete.isEmpty)
}

@Test(.timeLimit(.minutes(1))) func codemodeV104BridgeKeepsUndefinedAndMissingWritesAndIgnoresLateMessages() async {
    // Upstream #10444: finished runs ignore later worker messages.
    let result = await CodemodeSandbox.execute(code: "", tools: [], timeoutMs: 3_000,
        preludeSource: v104RawPrelude(#"bridge("done", "true"); bridge("nonsense"); bridge("output", "text", "late");"#),
        onCall: { _ in .init(ok: false) })
    #expect(result.execution.failure == nil)
    #expect(result.execution.returnedValue == nil)
    #expect(result.execution.output.isEmpty)
    #expect(result.storeWrites.set.isEmpty)
    #expect(result.storeWrites.delete.isEmpty)
}

@Test(.timeLimit(.minutes(1))) func codemodeV104BridgeAcceptsValidWritesAndScriptError() async throws {
    let success = await CodemodeSandbox.execute(code: "", tools: [], timeoutMs: 3_000,
        preludeSource: v104RawPrelude(#"bridge("done", "true", "null", '[["set", "[1]"], ["deleted"]]');"#),
        onCall: { _ in .init(ok: false) })
    #expect(success.execution.failure == nil)
    #expect(try v104Value(success) == "null")
    #expect(success.storeWrites.set["set"] == AnyCodable([1]))
    #expect(success.storeWrites.delete == ["deleted"])
    let failure = await CodemodeSandbox.execute(code: "", tools: [], timeoutMs: 3_000,
        preludeSource: v104RawPrelude(#"bridge("done", "false", '{"message":"x"}');"#),
        onCall: { _ in .init(ok: false) })
    #expect(failure.execution.failure?.kind == .script)
    #expect(failure.execution.failure?.message == "x")
    #expect(failure.execution.failure?.name == nil)
    #expect(failure.execution.failure?.stack == nil)
}

@Test(.timeLimit(.minutes(1))) func codemodeV104BridgeAllowsCompletedCallIdReuse() async throws {
    // Upstream #10444 checks duplicate IDs only while the call is pending.
    let prelude = """
    (function(bridge) {
        let settled = 0;
        return {
            run() { bridge("call", "7", "echo", "1"); },
            settle() {
                if (++settled === 1) bridge("call", "7", "echo", "2");
                else bridge("done", "true", "2", "[]");
            },
            stalled() {}
        };
    })
    """
    let result = await CodemodeSandbox.execute(code: "", tools: [], timeoutMs: 3_000,
        preludeSource: prelude, onCall: { call in .init(ok: true, payloadJSON: call.argsJSON) })
    #expect(result.execution.failure == nil)
    #expect(try v104Value(result) == "2")
}

@Test(.timeLimit(.minutes(1)), arguments: [false, true])
func codemodeV104IgnoresBuiltInAndGlobalPatches(forceWatchdog: Bool) async throws {
    // Upstream #10444: sandbox.test.ts:724-738, on both JavaScriptCore paths.
    let result = await v104Run("""
        Array.prototype.toJSON = () => null;
        Object.prototype.toJSON = () => 5;
        Promise.prototype.then = () => {};
        Map.prototype.get = () => undefined;
        globalThis.JSON = { stringify: () => "x", parse: () => "x" };
        store("k", [1]);
        return [await tools.echo([2]), JSON.stringify({ a: 1 })];
        """, forceWatchdog: forceWatchdog, tools: [.init(name: "echo")], onCall: { call in
            .init(ok: true, payloadJSON: call.argsJSON)
        })
    #expect(result.execution.failure == nil)
    #expect(try v104Value(result) == #"[[2],"{\"a\":1}"]"#)
    #expect(result.storeWrites.set["k"] == AnyCodable([1]))
    #expect(result.usedWatchdog == !CodemodeSandbox.usesTimeLimit(forceWatchdog: forceWatchdog))
    print("C1 JSContext path: forceWatchdog=\(forceWatchdog); usesTimeLimit=\(CodemodeSandbox.usesTimeLimit(forceWatchdog: forceWatchdog)); usedWatchdog=\(result.usedWatchdog)")
}

@Test(.timeLimit(.minutes(1))) func codemodeV104FreezesInstanceIntrinsics() async throws {
    // Upstream #10444: sandbox.test.ts:740-755.
    let result = await v104Run("""
        return [
            Object.getPrototypeOf(function* () {}).prototype,
            Object.getPrototypeOf(async function () {}),
            Object.getPrototypeOf(Int8Array).prototype,
            Object.getPrototypeOf([][Symbol.iterator]()),
            Object.getPrototypeOf(Object.getPrototypeOf([][Symbol.iterator]())),
            Object.getPrototypeOf(new Map()[Symbol.iterator]()),
            Object.getPrototypeOf(/a/[Symbol.matchAll]("")),
        ].every((object) => Object.isFrozen(object));
        """)
    #expect(result.execution.failure == nil)
    #expect(try v104Value(result) == "true")
}

@Test(.timeLimit(.minutes(1))) func codemodeV104AllowsInstanceOverrides() async throws {
    // Upstream #10444: sandbox.test.ts:757-779.
    let result = await v104Run("""
        const object = {};
        object.toString = () => "custom";
        function Legacy() {}
        Legacy.prototype = Object.create(Error.prototype);
        Legacy.prototype.constructor = Legacy;
        const bare = new Error();
        bare.message = "set later";
        class MyError extends Error {
            constructor(message) {
                super(message);
                this.name = "MyError";
            }
        }
        let patched = "silent";
        try { Error.prototype.name = "Patched"; } catch (error) { patched = error.constructor.name; }
        return [String(object), new Legacy().constructor === Legacy, bare.message, new MyError("x").name, Error.prototype.name, patched];
        """)
    #expect(result.execution.failure == nil)
    #expect(try v104Value(result) == #"["custom",true,"set later","MyError","Error","TypeError"]"#)
}

@Test(.timeLimit(.minutes(1))) func codemodeV104CoercesErrorNameAndMessage() async {
    // Upstream #10444: sandbox.test.ts:782-786, plus a non-string name.
    let message = await v104Run("const error = new Error('x'); error.message = 42; throw error;")
    #expect(message.execution.failure?.kind == .script)
    #expect(message.execution.failure?.name == "Error")
    #expect(message.execution.failure?.message == "42")
    let name = await v104Run("const error = new Error('x'); error.name = 42; throw error;")
    #expect(name.execution.failure?.kind == .script)
    #expect(name.execution.failure?.name == "42")
    #expect(name.execution.failure?.message == "x")
    let unprintable = await v104Run("throw { toString() { throw new Error('cannot describe'); }, toJSON() { throw new Error('cannot serialize'); } };")
    #expect(unprintable.execution.failure?.kind == .script)
    #expect(unprintable.execution.failure?.message == "The script threw a value that cannot be described")
}

@Test func codemodeV104MeasuresLockdownInJSContext() throws {
    // Run only the upstream lockdown in fresh VMs, excluding VM creation and other prelude work.
    let start = try #require(codemodePreludeSource.range(of: "\t(function lockdown() {"))
    let end = try #require(codemodePreludeSource.range(of: "\t})();", range: start.lowerBound..<codemodePreludeSource.endIndex))
    let lockdown = "(function() { 'use strict';\n" + codemodePreludeSource[start.lowerBound..<end.upperBound] + "\n})()"
    let clock = ContinuousClock()
    var milliseconds: [Double] = []
    for _ in 0..<12 {
        let context = try #require(JSContext(virtualMachine: JSVirtualMachine()))
        // Match the runtime's context setup; the prelude supplies its own console.
        context.evaluateScript("delete globalThis.console")
        let before = clock.now
        context.evaluateScript(lockdown)
        let duration = before.duration(to: clock.now).components
        milliseconds.append(Double(duration.seconds) * 1_000 + Double(duration.attoseconds) / 1_000_000_000_000_000)
        #expect(context.exception == nil)
        #expect(context.evaluateScript("Object.isFrozen(Array.prototype) && Object.isFrozen(Object.prototype) && (typeof Iterator !== 'function' || Object.isFrozen(Iterator.prototype))")?.toBool() == true)
    }
    let sorted = milliseconds.sorted()
    print(String(format: "C1 JSContext lockdown: 12 fresh VMs; median %.3f ms; min %.3f ms; max %.3f ms", (sorted[5] + sorted[6]) / 2, sorted[0], sorted[11]))
}
