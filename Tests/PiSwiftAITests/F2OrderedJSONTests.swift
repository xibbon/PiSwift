import Testing
@testable import PiSwiftAI

// JSON.parse retains the first property position and the last value for duplicate keys.
// MCP config opts in. Transcript parsing keeps its existing duplicate-key rejection.
@Test func f2OrderedJSONCanApplyJSONParseDuplicateKeyRules() throws {
    let json = try OrderedJSON.parse(#"{"z":1,"a":{"x":true,"x":false},"z":2}"#, allowDuplicateKeys: true)
    #expect(json.objectEntries?.map { $0.0 } == ["z", "a"])
    #expect(json.serialized() == #"{"z":2,"a":{"x":false}}"#)
    #expect(throws: OrderedJSONError.self) { try OrderedJSON.parse(#"{"z":1,"z":2}"#) }
}
