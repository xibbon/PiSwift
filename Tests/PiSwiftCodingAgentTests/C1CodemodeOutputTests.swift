import Testing
import PiSwiftAI
@testable import PiSwiftCodingAgent

@Suite struct C1CodemodeOutputTests {
    private func run(_ code: String) async -> CodemodeRuntimeResult {
        await CodemodeSandbox.execute(
            code: code, tools: [], globals: [], store: [:], timeoutMs: 30_000,
            onCall: { _ in .init(ok: false, payloadJSON: "unexpected call") }
        )
    }

    private func characters(_ result: CodemodeRuntimeResult) -> Int {
        // Upstream v1.1.0: read the text and console output item type.
        result.execution.output.reduce(0) { count, block in
            switch block {
            case .text(let text, _): count + text.utf16.count
            case .image(let image): count + image.data.utf16.count
            }
        }
    }

    // Upstream #10283: a caught RangeError must not resume output.
    @Test(.timeLimit(.minutes(1))) func caughtOutputErrorsEndTheScript() async {
        let calls = ["text(s)"] + ["log", "info", "warn", "error", "debug"].map {
            "console.\($0)(s)"
        } + [#"image("data:image/png;base64," + p)"#]
        for call in calls {
            let result = await run("""
                const s = "x".repeat(1 << 20);
                const p = "iVBORw0KGgoA" + "A".repeat(1 << 20);
                for (;;) { try { \(call); } catch {} }
                """)
            #expect(result.execution.failure?.kind == .script)
            #expect(result.execution.failure?.name == "RangeError")
            #expect(result.execution.failure?.message == "script output exceeded the limit of 16777216 characters or 100000 text(), image(), and console calls. Print a summary instead, or write large data to a file with a tool.")
            let count = characters(result)
            #expect(count <= codemodeMaxOutputChars)
            #expect(count > codemodeMaxOutputChars - (2 << 20))
        }
    }

    @Test(.timeLimit(.minutes(1))) func emptyOutputStopsAtTheItemLimit() async {
        let accepted = await run("for (let i = 0; i < \(codemodeMaxOutputItems); i++) text('')")
        #expect(accepted.execution.failure == nil)
        #expect(accepted.execution.output.count == codemodeMaxOutputItems)
        let failed = await run("for (;;) text('')")
        #expect(failed.execution.failure?.kind == .script)
        #expect(failed.execution.failure?.name == "RangeError")
        #expect(failed.execution.output.count == codemodeMaxOutputItems)
    }

    @Test(.timeLimit(.minutes(1))) func outputCountsUTF16AndFailsOnlyPastTheLimit() async {
        let code = #"text("\u{1F600}".repeat(\#(codemodeMaxOutputChars / 2)))"#
        let accepted = await run(code)
        #expect(accepted.execution.failure == nil)
        #expect(characters(accepted) == codemodeMaxOutputChars)
        let failed = await run(code + "; try { text('x') } catch {} text('after'); return 'after'")
        #expect(failed.execution.failure?.name == "RangeError")
        #expect(failed.execution.output.count == 1)
        #expect(characters(failed) == codemodeMaxOutputChars)
        #expect(failed.execution.returnedValue == nil)
    }
}
