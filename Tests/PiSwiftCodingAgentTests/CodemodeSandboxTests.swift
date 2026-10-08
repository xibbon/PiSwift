import Foundation
import Testing
import PiSwiftAI
@testable import PiSwiftCodingAgent

private func sandboxValue(_ result: CodemodeRuntimeResult) -> String? {
    guard let value = result.execution.returnedValue,
          let data = try? JSONEncoder().encode(value) else { return nil }
    return String(decoding: data, as: UTF8.self)
}

private func sandboxOutput(_ result: CodemodeRuntimeResult) -> [String] {
    // Upstream v1.1.0: output items carry the console flag.
    result.execution.output.compactMap { block in
        if case .text(let text, _) = block { return text }
        return nil
    }
}

private func sandboxRun(_ code: String, tools: [CodemodeRuntimeTool] = [],
                        globals: [CodemodeRuntimeGlobal] = [],
                        store: [String: AnyCodable] = [:], timeoutMs: Int = 3_000,
                        signal: CancellationToken? = nil, forceWatchdog: Bool = false,
                        onCall: @escaping @Sendable (CodemodeRuntimeCall) async -> CodemodeRuntimeReply = { _ in
                            CodemodeRuntimeReply(ok: false, payloadJSON: "unexpected call")
                        }) async -> CodemodeRuntimeResult {
    await CodemodeSandbox.execute(code: code, tools: tools, globals: globals, store: store,
                                  timeoutMs: timeoutMs, signal: signal,
                                  forceWatchdog: forceWatchdog, onCall: onCall)
}

@Test(.timeLimit(.minutes(1))) func sandboxRunsFreshVmWithAwaitAndJsonReturn() async {
    let first = await sandboxRun("globalThis.privateValue = 9; const x = await Promise.resolve(41); return {x: x+1, list: [true, 'a']}")
    #expect(first.execution.failure == nil)
    let object = sandboxValue(first).flatMap { text in
        try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
    }
    #expect(object?["x"] as? Int == 42)
    let list = object?["list"] as? [Any]
    #expect(list?.count == 2)
    #expect(list?.first as? Bool == true)
    #expect(list?.last as? String == "a")
    let second = await sandboxRun("return typeof globalThis.privateValue")
    #expect(sandboxValue(second) == #""undefined""#)
}

@Test(.timeLimit(.minutes(1))) func sandboxTextImageExitAndPartialFailure() async {
    // Upstream #10215: image() validates the image signature.
    let output = await sandboxRun("console.log('hello', 1); text({a:1}); text(undefined); image('data:image/png;base64,iVBORw0KGgo='); return null")
    #expect(output.execution.failure == nil)
    // Upstream v1.1.0: console output is marked in the sandbox result.
    #expect(sandboxOutput(output) == ["hello 1", #"{"a":1}"#, "undefined"])
    if case .text("hello 1", console: true)? = output.execution.output.first {} else {
        Issue.record("Missing console flag")
    }
    #expect(output.execution.output.contains { if case .image(let image) = $0 { return image.data == "iVBORw0KGgo=" && image.mimeType == "image/png" }; return false })

    let exited = await sandboxRun("text('before'); try { exit() } catch {} text('after')")
    #expect(exited.execution.failure == nil)
    #expect(sandboxOutput(exited) == ["before"])

    let failed = await sandboxRun("text('partial');\nthrow new TypeError('boom')")
    #expect(sandboxOutput(failed) == ["partial"])
    #expect(failed.execution.failure?.kind == .script)
    #expect(failed.execution.failure?.name == "TypeError")
    #expect(failed.execution.failure?.stack?.contains("codemode.js:2") == true)
    #expect(failed.execution.failure?.stack?.contains("codemode-prelude.js") == false)
    let syntax = await sandboxRun("const a = 1;\nconst b = ;")
    #expect(syntax.execution.failure?.kind == .script)
    #expect(syntax.execution.failure?.name == "SyntaxError")
}

@Test(.timeLimit(.minutes(1))) func sandboxCallsToolsConcurrentlyAndRejectsErrors() async {
    let seen = LockedState<[String]>([])
    let result = await sandboxRun("const [a,b] = await Promise.all([tools.echo({n:1}), tools.echo({n:2})]); try { await tools.fail() } catch(e) { return [a,b,e.message] }",
        tools: [.init(name: "echo"), .init(name: "fail")], onCall: { call in
            seen.withLock { $0.append(call.name) }
            if call.name == "fail" { return .init(ok: false, payloadJSON: "tool exploded") }
            return .init(ok: true, payloadJSON: call.argsJSON)
        })
    #expect(result.execution.failure == nil)
    #expect(sandboxValue(result) == #"[{"n":1},{"n":2},"tool exploded"]"#)
    #expect(seen.withLock { $0.sorted() } == ["echo", "echo", "fail"])
}

@Test(.timeLimit(.minutes(1))) func sandboxStoreCopiesValuesAndEnforcesLimits() async {
    let result = await sandboxRun("const v=load('obj'); v.a=2; store('kept', {b:1}); store('old', undefined); return [load('obj').a, load('kept').b, load('old')]",
        store: ["obj": AnyCodable(["a": 1]), "old": AnyCodable("x")])
    #expect(sandboxValue(result) == "[1,1,null]")
    #expect(result.storeWrites.set["kept"] != nil)
    #expect(result.storeWrites.delete == ["old"])

    let limits = await sandboxRun("const f=(run)=>{try {run();return 'ok'}catch(e){return e.name}}; return [f(()=>store(1,'x')),f(()=>load({})),f(()=>store('big','x'.repeat(300*1024))),f(()=>{for(let i=0;i<8;i++)store('k'+i,'x'.repeat(200*1024))})]")
    #expect(sandboxValue(limits) == #"["TypeError","TypeError","RangeError","RangeError"]"#)
}

@Test(.timeLimit(.minutes(1))) func sandboxGlobalsAndStalledPromise() async {
    let globals = await sandboxRun("const x=await models.first('a'); await models.list('classifier',undefined,3); return [x,Object.keys(models)]",
        globals: [.init(name: "models.first"), .init(name: "models.list", spread: true)], onCall: { call in
            #expect(call.target == .global)
            return .init(ok: true, payloadJSON: call.name == "models.first" ? #""a""# : nil)
        })
    #expect(globals.execution.failure == nil)
    #expect(sandboxValue(globals)?.contains(#""a""#) == true)
    let stalled = await sandboxRun("await new Promise(() => {}); return 'never'")
    #expect(stalled.execution.failure?.kind == .script)
    #expect(stalled.execution.failure?.message.contains("can never settle") == true)
    let invalid = await sandboxRun("return 1", globals: [.init(name: "store")])
    #expect(invalid.execution.failure?.kind == .sandbox)
}

@Test(.timeLimit(.minutes(1))) func sandboxNormalizesToolNamesAndPreservesFirstCollision() async {
    let result = await sandboxRun("return {all:ALL_TOOLS.map(x=>x.name), values:[await tools.my_tool(),await tools['my-tool'](),await tools.mcp__docs__search()]}",
        tools: [.init(name: "my-tool", description: "First"), .init(name: "my_tool", description: "Shadowed"),
                .init(name: "mcp__docs__search")], onCall: { call in
            .init(ok: true, payloadJSON: #""\#(call.name)""#)
        })
    #expect(result.execution.failure == nil)
    let object = sandboxValue(result).flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
    #expect(object?["all"] as? [String] == ["my_tool", "mcp__docs__search"])
    #expect(object?["values"] as? [String] == ["my-tool", "my-tool", "mcp__docs__search"])
}

@Test(.timeLimit(.minutes(1))) func sandboxRejectsInvalidOutputAndCatchesStackOverflow() async {
    let invalid = await sandboxRun("const f=(fn)=>{try{fn();return 'ok'}catch(e){return e.name}}; return [f(()=>image('https://example.com/a.png')),f(()=>image('data:image/png,raw')),f(()=>image({type:'text',text:'x'})),f(()=>image(42))]")
    #expect(sandboxValue(invalid) == #"["TypeError","TypeError","TypeError","TypeError"]"#)
    let overflow = await sandboxRun("let depth=0; function dive(){depth++;dive()} try{dive()}catch(e){return [e.name,depth>1000]}")
    #expect(sandboxValue(overflow) == #"["RangeError",true]"#)
    let bigint = await sandboxRun("return 10n")
    #expect(bigint.execution.failure?.kind == .script)
    #expect(bigint.execution.failure?.name == "TypeError")
}

@Test(.timeLimit(.minutes(1))) func sandboxTimesOutAndAbortsWithBoundedWallTime() async {
    let timeout = await sandboxRun("const end=Date.now()+1000; while(Date.now()<end){}; return 'late'", timeoutMs: 100)
    #expect(timeout.execution.failure?.kind == .timeout)
    let token = CancellationToken()
    let task = Task { await sandboxRun("const end=Date.now()+1000; while(Date.now()<end){}", timeoutMs: 3_000, signal: token) }
    try? await Task.sleep(for: .milliseconds(50))
    token.cancel()
    let aborted = await task.value
    #expect(aborted.execution.failure?.kind == .aborted)
}

@Test(.timeLimit(.minutes(1))) func sandboxWatchdogFallbackReturnsOnTimeout() async {
    let result = await sandboxRun("const end=Date.now()+1000; while(Date.now()<end){}", timeoutMs: 100,
                                  forceWatchdog: true)
    #expect(result.usedWatchdog)
    #expect(result.execution.failure?.kind == .timeout)
}

#if os(macOS)
@Test(.timeLimit(.minutes(1))) func sandboxMacOSTimeLimitInterruptsLoop() async {
    guard CodemodeSandbox.usesTimeLimit(forceWatchdog: false) else {
        print("Skipped: JSContextGroupSetExecutionTimeLimit is unavailable")
        return
    }
    let result = await sandboxRun("while(true){}", timeoutMs: 100)
    #expect(!result.usedWatchdog)
    #expect(result.execution.failure?.kind == .timeout)
}
#endif

@Test(.timeLimit(.minutes(1))) func codemodeToolDescriptionMakesNoMemoryClaim() {
    let definition = createCodemodeToolDefinition()
    let standalone = createCodemodeTool()
    #expect(!definition.description.contains("256 MB memory limit"))
    #expect(!standalone.description.contains("256 MB memory limit"))
}
