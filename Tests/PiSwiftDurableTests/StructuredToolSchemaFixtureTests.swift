import Foundation
import Testing
import PiSwiftChord
@testable import PiSwiftDurable

@Suite("PiSwiftDurableTests.StructuredToolSchemaFixtures")
struct StructuredToolSchemaFixtureTests {
    @Test func acceptanceMatchesPinnedUpstreamValidator() throws {
        // v1.5.2 D8: durable/src/harness/tool.ts:778-801 uses pi-schema's first error.
        let url = try #require(Bundle.module.url(forResource: "structured-tool-schema-v152", withExtension: "json", subdirectory: "Fixtures"))
        let fixture = try JSONValue(jsonData: Data(contentsOf: url))
        #expect(fixture["tag"] == "v1.5.2")
        let cases = try #require(fixture["cases"]?.arrayValue)
        #expect(cases.count == 88)
        for item in cases {
            let name = try #require(item["name"]?.stringValue)
            let schema = try #require(item["schema"]?.objectValue)
            let value = try #require(item["value"])
            let expected = try #require(item["accepted"]?.boolValue)
            let error = durableStructuredSchemaError(value, schema: schema)
            #expect((error == nil) == expected, "Schema case \(name): \(error ?? "accepted")")
            #expect(error == item["error"]?.stringValue, "Schema diagnostic \(name)")
        }
    }
}
