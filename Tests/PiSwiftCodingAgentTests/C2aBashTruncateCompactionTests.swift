import Foundation
import Testing
import PiSwiftAI
import PiSwiftAgent
import PiSwiftCodingAgent

private struct C2aBashOperations: BashOperations {
    let output: String
    let exitCode: Int?

    func execute(_ command: String, options: BashExecutorOptions?) async throws -> BashResult {
        options?.onChunk?(output)
        return BashResult(output: output, exitCode: exitCode, cancelled: false, truncated: false)
    }
}

private func c2aBashText(_ result: AgentToolResult) -> String {
    result.content.compactMap { block in
        if case .text(let text) = block { return text.text }
        return nil
    }.joined()
}

@Test func bashReturnsStructuredErrorAndEmptyOutput() async throws {
    let cwd = FileManager.default.currentDirectoryPath
    let failed = createBashTool(cwd: cwd, options: BashToolOptions(
        operations: C2aBashOperations(output: "out\n", exitCode: 3)
    ))
    let failure = try await failed.execute("failed", ["command": AnyCodable("run")], nil, nil)
    let fields = try #require(failure.structuredContent?.value as? [String: Any])
    #expect(failure.isError == true)
    #expect(c2aBashText(failure) == "out\n\n\nCommand exited with code 3")
    #expect(fields["output"] as? String == "out\n")
    #expect(fields["truncated"] as? Bool == false)
    #expect(fields["exit_code"] as? Int == 3)
    #expect(fields["wall_time_seconds"] as? Double != nil)
    #expect(failed.outputSchema != nil)

    let empty = createBashTool(cwd: cwd, options: BashToolOptions(
        operations: C2aBashOperations(output: "", exitCode: 0)
    ))
    let success = try await empty.execute("empty", ["command": AnyCodable("run")], nil, nil)
    #expect(success.isError == nil)
    #expect(c2aBashText(success) == "(no output)")
    #expect((success.structuredContent?.value as? [String: Any])?["output"] as? String == "")
}

@Test func bashStructuredOutputUsesOneMiBLimit() async throws {
    let cwd = FileManager.default.currentDirectoryPath
    let medium = (1...3000).map(String.init).joined(separator: "\n") + "\n"
    let mediumTool = createBashTool(cwd: cwd, options: BashToolOptions(
        operations: C2aBashOperations(output: medium, exitCode: 0)
    ))
    let mediumResult = try await mediumTool.execute("medium", ["command": AnyCodable("run")], nil, nil)
    let mediumFields = try #require(mediumResult.structuredContent?.value as? [String: Any])
    let mediumPath = (mediumResult.details?.value as? [String: Any])?["fullOutputPath"] as? String
    defer { if let mediumPath { try? FileManager.default.removeItem(atPath: mediumPath) } }
    #expect(mediumResult.details != nil)
    #expect(mediumFields["truncated"] as? Bool == false)
    #expect(mediumFields["output"] as? String == medium)

    let large = "start\n" + String(repeating: "a", count: 1_200_000) + "\nend\n"
    let largeTool = createBashTool(cwd: cwd, options: BashToolOptions(
        operations: C2aBashOperations(output: large, exitCode: 0)
    ))
    let largeResult = try await largeTool.execute("large", ["command": AnyCodable("run")], nil, nil)
    let largeFields = try #require(largeResult.structuredContent?.value as? [String: Any])
    let structuredOutput = try #require(largeFields["output"] as? String)
    let fullPath = try #require(largeFields["full_output_path"] as? String)
    defer { try? FileManager.default.removeItem(atPath: fullPath) }
    #expect(largeFields["truncated"] as? Bool == true)
    #expect(structuredOutput.hasPrefix("start\n"))
    #expect(structuredOutput.hasSuffix("\nend\n"))
    #expect(structuredOutput.contains("bytes omitted"))
    #expect(structuredOutput.utf8.count < structuredOutputMaxTestBytes + 100)
    #expect(try String(contentsOfFile: fullPath, encoding: .utf8) == large)
}

private let structuredOutputMaxTestBytes = 1024 * 1024

@Test func truncateMiddleKeepsUnicodeBoundaries() {
    let result = truncateMiddle("AB😀CDE界FG", maxBytes: 9)
    #expect(result.truncated)
    #expect(result.content == "AB…4 chars truncated…界FG")
    #expect(result.removedChars == 4)
    #expect(result.totalBytes == 14)

    let unchanged = truncateMiddle("one\ntwo\n", maxBytes: 20)
    #expect(!unchanged.truncated)
    #expect(unchanged.totalLines == 2)
}

@Test func compactionIncludesNestedToolFileOperations() {
    let calls = [
        NestedToolCallRecord(id: "outer/1", name: "read", arguments: ["path": AnyCodable("a.txt")], status: .ok),
        NestedToolCallRecord(id: "outer/2", name: "write", arguments: ["path": AnyCodable("b.txt")], status: .ok),
        NestedToolCallRecord(id: "outer/3", name: "edit", arguments: ["path": AnyCodable("a.txt")], status: .error),
        NestedToolCallRecord(id: "outer/4", name: "read", arguments: ["path": AnyCodable("")], status: .ok),
    ]
    let result = ToolResultMessage(toolCallId: "outer", toolName: "script", content: [],
                                   nestedCalls: NestedToolCalls(calls: calls, complete: true), isError: false)
    var operations = createFileOps()
    extractFileOpsFromMessage(.toolResult(result), &operations)
    let files = computeFileLists(operations)
    #expect(files.readFiles.isEmpty)
    #expect(files.modifiedFiles == ["a.txt", "b.txt"])
}
