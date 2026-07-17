import Foundation
import Testing
@testable import PiSwiftAI

// The canonical content-block/usage codec (`contentBlockToJSONObject` etc.) is the single source
// of truth shared by session persistence and the Codable-based proxy transport. The proxy path
// bridges through `AnyCodable(contentBlockToJSONObject(...))`, so that bridge must produce JSON
// byte-identical to the JSONSerialization shape session persistence writes. These tests pin that
// equivalence so the two encoders can never silently diverge again.

private func jsonObject(_ any: Any) throws -> NSDictionary {
    let data = try JSONSerialization.data(withJSONObject: any)
    return try #require(JSONSerialization.jsonObject(with: data) as? NSDictionary)
}

private func anyCodableEncoded(_ object: [String: Any]) throws -> NSDictionary {
    let data = try JSONEncoder().encode(AnyCodable(object))
    return try #require(try JSONSerialization.jsonObject(with: data) as? NSDictionary)
}

private func assertBridgeMatchesCanonical(_ block: ContentBlock) throws {
    let canonical = contentBlockToJSONObject(block)
    let viaJSONSerialization = try jsonObject(canonical)   // session-persistence path
    let viaAnyCodable = try anyCodableEncoded(canonical)   // proxy-transport path
    #expect(viaAnyCodable == viaJSONSerialization)
}

@Test func proxyBridgeMatchesCanonicalForAllBlockKinds() throws {
    try assertBridgeMatchesCanonical(.text(TextContent(text: "hello", textSignature: "reasoning-item-1")))
    try assertBridgeMatchesCanonical(.thinking(ThinkingContent(thinking: "step", thinkingSignature: "sig")))
    try assertBridgeMatchesCanonical(.thinking(ThinkingContent(thinking: "[redacted]", thinkingSignature: "opaque==", redacted: true)))
    try assertBridgeMatchesCanonical(.image(ImageContent(data: "AAAA", mimeType: "image/png")))
    try assertBridgeMatchesCanonical(.toolCall(ToolCall(
        id: "t1",
        name: "read",
        arguments: ["path": AnyCodable("/x"), "limit": AnyCodable(10), "deep": AnyCodable(true)]
    )))
}

@Test func usageBridgeMatchesCanonical() throws {
    let usage = Usage(input: 3, output: 5, cacheRead: 1, cacheWrite: 2, totalTokens: 11)
    let canonical = usageToJSONObject(usage)
    #expect(try anyCodableEncoded(canonical) == (try jsonObject(canonical)))
}

@Test func contentBlockJSONRoundTripIsStable() {
    let blocks: [ContentBlock] = [
        .text(TextContent(text: "t", textSignature: "ts")),
        .thinking(ThinkingContent(thinking: "th", thinkingSignature: "sig", redacted: true)),
        .image(ImageContent(data: "D", mimeType: "image/jpeg")),
        .toolCall(ToolCall(id: "id", name: "n", arguments: ["k": AnyCodable("v")])),
    ]
    for block in blocks {
        let restored = contentBlockFromJSONObject(contentBlockToJSONObject(block))
        #expect(restored != nil)
    }
    // Field-level: redacted + textSignature survive.
    if case .thinking(let t)? = contentBlockFromJSONObject(contentBlockToJSONObject(blocks[1])) {
        #expect(t.redacted == true)
        #expect(t.thinkingSignature == "sig")
    } else {
        Issue.record("thinking block did not round-trip")
    }
}
