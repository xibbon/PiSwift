import Foundation
import Testing
import PiSwiftAI
import PiSwiftAgent
@testable import PiSwiftCodingAgent

private func cm1ExecutionText(_ block: ContentBlock) -> String? {
    if case .text(let value) = block { return value.text }
    return nil
}

// Upstream execute.ts:296-321 keeps the separator state across empty items.
@Test(arguments: [
    (["first", "", "", "last"], "first\nlast"),
    (["first\n", "", "", "last"], "first\nlast"),
    (["", "", ""], ""),
    (["first", "", ""], "first\n"),
])
func codemodeCM1EmptyTextSeparators(parts: [String], expected: String) throws {
    let output = joinAdjacentCodemodeText(parts.map { .text(TextContent(text: $0)) })
    try #require(output.count == 1)
    #expect(cm1ExecutionText(output[0]) == expected)
}

@Test func codemodeCM1EmptyTextAtImageBoundary() throws {
    let image = ImageContent(data: "aW1hZ2U=", mimeType: "image/png")
    let output = joinAdjacentCodemodeText([
        .text(TextContent(text: "first")), .text(TextContent(text: "")),
        .image(image), .text(TextContent(text: "")), .text(TextContent(text: "last")),
    ])
    try #require(output.count == 3)
    #expect(cm1ExecutionText(output[0]) == "first\n")
    if case .image(let value) = output[1] { #expect(value.data == image.data) }
    else { Issue.record("Missing image between text blocks") }
    #expect(cm1ExecutionText(output[2]) == "last")
}

// Upstream agent-session-codemode.test.ts:555. Allow headroom for JSC and loaded test hosts.
@Test(.timeLimit(.minutes(1)), arguments: [false, true])
func codemodeCM1FormatsItemLimitInLinearTime(forceWatchdog: Bool) async throws {
    let clock = ContinuousClock()
    let started = clock.now
    let result = try await executeCodemode(toolCallId: "cm1-item-limit",
        params: ["code": AnyCodable("for (let i = 0; i < 100000; i++) text('');")],
        forceWatchdog: forceWatchdog)
    let elapsed = started.duration(to: clock.now)
    if let path = (result.details?.value as? [String: Any])?["fullOutputPath"] as? String {
        defer { try? FileManager.default.removeItem(atPath: path) }
        #expect(FileManager.default.fileExists(atPath: path))
    }
    #expect(result.isError != true)
    #expect(result.content.compactMap(cm1ExecutionText).joined(separator: "\n").contains("==> text 100000/100000 <=="))
    #expect(elapsed < .seconds(20))
}

// The first callback can cancel a script before the sandbox's cancellation preflight.
@Test(.timeLimit(.minutes(1)), arguments: [false, true])
func codemodeCM1PublishesEmptyProgressBeforeExecution(forceWatchdog: Bool) async throws {
    let signal = CancellationToken()
    let updates = LockedState<[(contentCount: Int, callCount: Int)]>([])
    let writes = LockedState(0)
    let result = try await executeCodemode(toolCallId: "cm1-initial-progress",
        params: ["code": AnyCodable("text('should not execute'); store('ran', true); return 1;")],
        signal: signal, onUpdate: { update in
            let rows = (update.details?.value as? [String: Any])?["calls"] as? [[String: Any]]
            updates.withLock { $0.append((update.content.count, rows?.count ?? -1)) }
            signal.cancel()
        }, options: .init(appendEntry: { _, _ in writes.withLock { $0 += 1 } }),
        forceWatchdog: forceWatchdog)
    let first = try #require(updates.withLock { $0.first })
    #expect(first.contentCount == 0)
    #expect(first.callCount == 0)
    #expect(result.isError == true)
    let text = result.content.compactMap(cm1ExecutionText).joined(separator: "\n")
    #expect(text.contains("Script aborted: Execution aborted"))
    #expect(!text.contains("should not execute"))
    #expect(writes.withLock { $0 } == 0)
}

@Test func codemodeCM1DescribesOneNestedObjectLevel() {
    let tool = AgentTool(label: "result", name: "result", description: "Get results.", parameters: [:],
        execute: { _, _, _, _ in AgentToolResult(content: []) },
        outputSchema: ["type": AnyCodable("object"), "properties": AnyCodable([
            "content": ["type": "array", "items": ["type": "object"]],
            "structuredContent": ["type": "object", "properties": [
                "results": ["type": "object", "properties": ["id": ["type": "string"]]]], "required": ["results"]],
        ] as [String: Any]), "required": AnyCodable(["content"])])
    let loadout = ToolLoadout(declared: [tool], callable: [tool], registered: [tool],
        getExposure: { _ in .direct }, getNamespace: { _ in nil })
    #expect(prepareCodemodeLoadout(loadout).descriptions?["result"] ==
        "Get results.\n\nCodemode: `tools.result(args)` resolves to `{ content, structuredContent?: { results } }`.")
    let description = createCodemodeDescription([tool], options: .init(inlineBudget: nil))
    #expect(!description.contains("Shared MCP Types"))
    #expect(!description.contains("CallToolResult"))
}
