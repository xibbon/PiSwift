import Foundation
import Testing
import PiSwiftChord
@testable import PiSwiftDurable

@Suite("PiSwiftDurableTests.StructuredToolSchemaFixtures")
struct StructuredToolSchemaFixtureTests {
    @Test func acceptanceMatchesPinnedUpstreamValidator() throws {
        let url = try #require(Bundle.module.url(forResource: "structured-tool-schema-v130", withExtension: "json", subdirectory: "Fixtures"))
        let fixture = try JSONValue(jsonData: Data(contentsOf: url))
        #expect(fixture["tag"] == "v1.3.0")
        #expect(fixture["dependency"] == "typebox@1.3.27")
        let cases = try #require(fixture["cases"]?.arrayValue)
        #expect(cases.count == 88)
        for item in cases {
            let name = try #require(item["name"]?.stringValue)
            let schema = try #require(item["schema"]?.objectValue)
            let value = try #require(item["value"])
            let expected = try #require(item["check"]?.boolValue)
            let error = durableStructuredSchemaError(value, schema: schema)
            #expect((error == nil) == expected, "Schema case \(name): \(error ?? "accepted")")
            if let first = item["first"], first != .null {
                let pointer = try #require(first["instancePath"]?.stringValue)
                let path = pointer.isEmpty ? "root" : "root." + pointer.dropFirst().replacingOccurrences(of: "/", with: ".")
                let reason = try #require(first["message"]?.stringValue)
                #expect(error == "\(path): \(reason)", "Schema diagnostic \(name)")
            }
        }
    }
}
