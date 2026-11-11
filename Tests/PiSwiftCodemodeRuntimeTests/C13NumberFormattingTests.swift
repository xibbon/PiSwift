import Testing
@testable import PiSwiftCodemodeRuntime

struct C13NumberFormattingTests {
    // v1.5.2 C-CM: packages/codemode/test/sandbox.test.ts:133.
    @Test("prints non-finite numbers in console output and thrown values like text()", arguments: [false, true])
    func printsNonFiniteNumbersInConsoleOutputAndThrownValuesLikeText(forceWatchdog: Bool) async {
        let logged = await JSCCodemodeEngine.execute(
            code: "console.log(\"avg\", 0 / 0, 1 / 0, -1 / 0, { a: 1 }); text(0 / 0);",
            tools: [], forceWatchdog: forceWatchdog
        ) { _ in .init(ok: true) }
        #expect(logged.execution.failure == nil)
        #expect(logged.execution.output.count == 2)
        if logged.execution.output.count == 2 {
            if case .text(let text, let console) = logged.execution.output[0] {
                #expect(text == "avg NaN Infinity -Infinity {\"a\":1}")
                #expect(console)
            } else { Issue.record("Expected console text") }
            if case .text(let text, let console) = logged.execution.output[1] {
                #expect(text == "NaN")
                #expect(!console)
            } else { Issue.record("Expected text() output") }
        }

        let thrown = await JSCCodemodeEngine.execute(
            code: "throw NaN", tools: [], forceWatchdog: forceWatchdog
        ) { _ in .init(ok: true) }
        #expect(thrown.execution.failure?.kind == .script)
        #expect(thrown.execution.failure?.message == "NaN")
    }
}
