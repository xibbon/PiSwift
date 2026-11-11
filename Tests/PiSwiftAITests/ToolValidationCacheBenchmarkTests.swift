import Foundation
import Testing
@testable import PiSwiftAI

/// Measurement only. Run this test in a release build when reviewing the cache.
@Test func s4TwentyKilobyteSchemaCacheLookup() throws {
    let properties = Dictionary(uniqueKeysWithValues: (0..<250).map { index in
        (String(format: "field%03d", index), ["type": "string", "description": String(repeating: "x", count: 46)])
    })
    let schema: [String: Any] = ["type": "object", "properties": properties]
    let size = try JSONSerialization.data(withJSONObject: schema).count
    let tool = AITool(name: "large", description: "", parameters: schema.mapValues(AnyCodable.init))
    let call = ToolCall(id: "bench", name: "large", arguments: ["field000": AnyCodable("x")])
    _ = try validateToolArguments(tool: tool, toolCall: call)
    let start = DispatchTime.now().uptimeNanoseconds
    for _ in 0..<500 { _ = try validateToolArguments(tool: tool, toolCall: call) }
    let elapsed = DispatchTime.now().uptimeNanoseconds - start
    print("S4 cache benchmark: \(size) bytes, \(Double(elapsed) / 500_000) microseconds per lookup")
}
