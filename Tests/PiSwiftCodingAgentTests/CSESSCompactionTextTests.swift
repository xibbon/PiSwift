import Foundation
import Testing
import PiSwiftAI
@testable import PiSwiftCodingAgent

private func summaryToolMessage(_ text: String) -> Message {
    .toolResult(ToolResultMessage(toolCallId: "test", toolName: "read",
                                  content: [.text(TextContent(text: text))], isError: false))
}

// v1.5.2 C-SESS 9e870f6f0, compaction/utils.ts:94-104.
@Test func summaryToolResultsUseTwoThousandUTF16UnitsAndUpstreamMarker() {
    let text = String(repeating: "a", count: 2001)
    #expect(serializeConversation([summaryToolMessage(text)]) ==
            "[Tool result]: \(String(repeating: "a", count: 2000))\n\n[... 1 more characters truncated]")
    #expect(serializeConversation([summaryToolMessage(String(repeating: "a", count: 2000))]) ==
            "[Tool result]: \(String(repeating: "a", count: 2000))")
}

@Test func summaryToolResultCutDropsWholeSurrogatePair() {
    let split = String(repeating: "a", count: 1999) + "😀tail"
    #expect(serializeConversation([summaryToolMessage(split)]) ==
            "[Tool result]: \(String(repeating: "a", count: 1999))\n\n[... 5 more characters truncated]")
    let exact = String(repeating: "a", count: 1998) + "😀tail"
    #expect(serializeConversation([summaryToolMessage(exact)]) ==
            "[Tool result]: \(String(repeating: "a", count: 1998))😀\n\n[... 4 more characters truncated]")
}
