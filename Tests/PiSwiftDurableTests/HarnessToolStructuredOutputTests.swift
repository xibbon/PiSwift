import Synchronization
import Testing
import PiSwiftAI
import PiSwiftChord
@testable import PiSwiftDurable
import PiSwiftDurableTesting

@Suite struct HarnessToolStructuredOutputTests {
    @Test(arguments: ["no-schema", "missing", "invalid", "no-coercion", "null", "error-missing", "error-valid", "error-invalid"])
    func modelStructuredOutputContract(mode: String) async throws {
        let setup = HarnessChatSetup()
        let schema: JSONObject? = mode == "no-schema" ? nil : mode == "null" ? ["type": "null"] : ["type": "integer"]
        let value: JSONValue? = switch mode {
        case "missing", "error-missing": nil
        case "null": .null
        case "invalid", "error-invalid": .object(["wrong": true])
        case "no-coercion": .string("3")
        default: .number(3)
        }
        let isError = mode.hasPrefix("error-")
        var tool = try harnessTestTool(execute: { _, _, _ in
            .init(output: [.text(TextContent(text: "tool output"))], structuredOutput: value, isError: isError)
        })
        tool.structuredOutputSchema = schema
        try installHarnessTool(tool, setup: setup)
        let (opened, entries) = try await runHarnessTools(setup)
        let result = try #require(harnessToolResults(entries).first)
        let entry = try #require(entries.first { $0.kind == toolResultEntry.kind })
        let broken = ["no-schema", "missing", "invalid", "no-coercion", "error-invalid"].contains(mode)
        let reports = setup.reports.values.filter { String(describing: $0).contains("structuredOutput") }
        #expect(reports.count == (broken ? 1 : 0))
        #expect(reports.allSatisfy { $0 is TaskDefinitionError })
        #expect(result.isError == isError)
        #expect(harnessToolText(result) == "tool output")
        #expect(entry.data?["diagnostics"] == [])
        #expect(entry.data?["structuredOutput"] == nil)
        #expect(entry.model?.first?["structuredOutput"] == nil)
        try await opened.harness.close(context: .background)
    }

    @Test(arguments: [true, false])
    func validatesStructuredOutputAfterToolHooks(repair: Bool) async throws {
        let setup = HarnessChatSetup()
        var tool = try harnessTestTool(execute: { _, _, _ in
            .init(output: [.text(TextContent(text: "kept"))], structuredOutput: repair ? .string("bad") : .number(3))
        })
        tool.structuredOutputSchema = ["type": "integer"]
        try installHarnessTool(tool, setup: setup)
        try setup.registry.install(Extension(name: "replace-structured-output", hooks: [hook(ToolHooks(afterTool: { _, result, _, _ in
            var replacement = result
            replacement.structuredOutput = repair ? .number(4) : .string("bad")
            return replacement
        }))]))
        let (opened, entries) = try await runHarnessTools(setup)
        #expect(setup.reports.values.filter { String(describing: $0).contains("structuredOutput") }.count == (repair ? 0 : 1))
        let result = try #require(harnessToolResults(entries).first)
        #expect(!result.isError && harnessToolText(result) == "kept")
        #expect(entries.first { $0.kind == toolResultEntry.kind }?.data?["diagnostics"] == [])
        try await opened.harness.close(context: .background)
    }

    @Test func structuredOutputDoesNotChangeBoundedTranscriptOutput() async throws {
        let setup = HarnessChatSetup()
        var tool = try harnessTestTool(limits: .init(maxLines: 1), execute: { _, _, _ in
            .init(output: [.text(TextContent(text: "first\nsecond\n"))], structuredOutput: ["answer": 3])
        })
        tool.structuredOutputSchema = ["type": "object", "properties": ["answer": ["type": "integer"]], "required": ["answer"]]
        try installHarnessTool(tool, setup: setup)
        let (opened, entries) = try await runHarnessTools(setup)
        let result = try #require(harnessToolResults(entries).first)
        let entry = try #require(entries.first { $0.kind == toolResultEntry.kind })
        #expect(!result.isError)
        #expect(harnessToolText(result).hasPrefix("first\n"))
        #expect(!harnessToolText(result).contains("second"))
        #expect(entry.data?["diagnostics"]?.arrayValue?.contains { $0["code"] == "truncated" } == true)
        #expect(setup.reports.values.isEmpty)
        try await opened.harness.close(context: .background)
    }

    @Test(arguments: [false, true])
    func retainedOutputReadsBoundedStreamAndRejectsSettledCalls(tail: Bool) async throws {
        let retain: PiSwiftChord.OutputRetention = tail ? .tail : .head
        let setup = HarnessChatSetup(), apiCopy = Mutex<ToolExecutionApi?>(nil)
        let windows = Mutex<[String]>([]), truncated = Mutex<[Bool]>([])
        try installHarnessTool(harnessTestTool(limits: .init(maxLines: 1, retain: retain), execute: { _, api, _ in
            apiCopy.withLock { $0 = api }
            let empty = try api.retainedOutput()
            #expect(empty.text.isEmpty && !empty.truncated)
            try api.output(.text("first\n"), nil)
            let first = try api.retainedOutput()
            windows.withLock { $0.append(first.text) }; truncated.withLock { $0.append(first.truncated) }
            try api.output(.text("second\n"), nil)
            let second = try api.retainedOutput()
            windows.withLock { $0.append(second.text) }; truncated.withLock { $0.append(second.truncated) }
            return .init()
        }), setup: setup)
        let (opened, entries) = try await runHarnessTools(setup)
        #expect(windows.withLock { $0 } == ["first\n", retain == .head ? "first\n" : "second\n"])
        #expect(truncated.withLock { $0 } == [false, true])
        let api = try #require(apiCopy.withLock { $0 })
        #expect(throws: (any Error).self) { try api.retainedOutput() }
        let result = try #require(harnessToolResults(entries).first)
        #expect(harnessToolText(result).hasPrefix(retain == .head ? "first\n" : "second\n"))
        try await opened.harness.close(context: .background)
    }
}
