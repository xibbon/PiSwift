import Testing
import PiSwiftAI
@testable import PiMCPAdapter

@Suite("MCP Output Guard")
struct McpOutputGuardTests {
    @Test("guards oversized text and preserves images")
    func guardsOversizedText() async {
        let output = await guardMcpOutput(
            [
                .text(TextContent(text: String(repeating: "abc", count: 100))),
                .image(ImageContent(data: "data", mimeType: "image/png")),
            ],
            serverName: "demo",
            settings: McpSettings(outputGuard: .limits(OutputGuardLimits(maxBytes: 80, maxLines: 5))),
            outputStore: nil
        )

        #expect(output.details?.originalBytes == 300)
        #expect(output.details?.returnedBytes ?? .max < 300)
        #expect(output.content.contains { if case .image = $0 { return true }; return false })
        #expect(output.content.contains { block in
            if case .text(let text) = block { return text.text.contains("MCP output truncated") }
            return false
        })
    }

    @Test("can disable the output guard")
    func canDisableGuard() async {
        let text = String(repeating: "abc", count: 100)
        let output = await guardMcpOutput(
            [.text(TextContent(text: text))],
            serverName: "demo",
            settings: McpSettings(outputGuard: .enabled(false)),
            outputStore: nil
        )

        #expect(output.details == nil)
        #expect(output.content.count == 1)
        if case .text(let returned) = output.content[0] {
            #expect(returned.text == text)
        } else {
            Issue.record("Expected text output")
        }
    }

    @Test("bounds large raw MCP details separately from model output")
    func boundsLargeRawDetails() async throws {
        let store = MemoryOutputStore()
        let output = await guardMcpOutput(
            [.text(TextContent(text: "ok"))],
            serverName: "demo",
            settings: McpSettings(outputGuard: .limits(OutputGuardLimits(detailsMaxBytes: 40))),
            outputStore: store,
            rawMcpResult: AnyCodable(["content": [["text": String(repeating: "x", count: 500)]]])
        )

        let details = try #require(output.detailsValue?.value as? [String: Any])
        let result = try #require(details["mcpResult"] as? [String: Any])
        #expect(result["omitted"] as? Bool == true)
        #expect((result["rawResultBytes"] as? Int ?? 0) > 40)
        #expect(result["fullResultReference"] as? String == "memory://demo-result")
        #expect(await store.savedCount() == 1)
    }
}

private actor MemoryOutputStore: McpOutputStore {
    private var saved: [String] = []

    func save(serverName: String, content: String) async -> String? {
        saved.append(content)
        return "memory://\(serverName)"
    }

    func savedCount() -> Int { saved.count }
}
