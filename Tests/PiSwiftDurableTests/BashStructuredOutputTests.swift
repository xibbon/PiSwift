import Testing
import PiSwiftChord
@testable import PiSwiftDurable

@Suite struct BashStructuredOutputTests {
    @Test(arguments: [0, 7])
    func shellValueUsesRetainedTailAndSpillPath(exitCode: Int) async throws {
        let env = ToolFixtureEnv(base: LocalExecutionEnv(), execHook: { _, options, context in
            do { try options?.onOutput?("first\nlast\n", context, .init(stream: .stdout)) }
            catch { return .failure(.init(.callbackError, message: String(describing: error))) }
            return .success(.init(exitCode: exitCode, spillPath: "/fixture/full-output.log"))
        })
        let reports = ToolTestReports()
        let tool = try createBashTool()
        let window = ShellOutputWindow(maxBytes: 32, maxLines: 1, minIntervalMs: 0, bytesPerSecond: 1024)
        let result = try await tool.execute(["command": "fixture"], reports.api(env: env, outputWindow: window), .background)
        #expect(result.output == nil)
        #expect(result.structuredOutput == ["output": "last\n", "truncated": true,
            "fullOutputPath": "/fixture/full-output.log", "exitCode": .number(Double(exitCode))])
        #expect(result.isError == (exitCode == 0 ? nil : true))
        #expect(result.diagnostics?.map(\.code) == (exitCode == 0 ? nil : ["exit_code"]))
        #expect(reports.diagnostics.map(\.code) == ["full_output"])
        #expect(try structuredOutputError(tool, result) == nil)
        #expect(try tool.currentOrderedDeclaration()["structuredOutputSchema"] == nil)
    }
}
