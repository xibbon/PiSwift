import Foundation
import Testing
import PiSwiftAI
import PiSwiftChord
@testable import PiSwiftDurable

@Suite("PiSwiftDurableTests.D8SchemaVectors")
struct D8SchemaVectorsTests {
    private func canonical(_ value: JSONValue) throws -> String {
        switch value {
        case .array(let values): return "[" + (try values.map(canonical)).joined(separator: ",") + "]"
        case .object(let object):
            let members = Array(object).sorted { $0.key.utf16.lexicographicallyPrecedes($1.key.utf16) }
            return "{" + (try members.map { member in
                try JSONValue.string(member.key).jsonText() + ":" + canonical(member.value)
            }).joined(separator: ",") + "}"
        default: return try value.jsonText()
        }
    }
    private func hash(_ value: JSONValue) throws -> String {
        var state: UInt64 = 0xcbf29ce484222325
        for byte in try canonical(value).utf8 {
            state = (state ^ UInt64(byte)) &* 0x100000001b3
        }
        let digits = String(state, radix: 16)
        return String(repeating: "0", count: 16 - digits.count) + digits
    }

    @Test(.timeLimit(.minutes(3))) func toolArgumentsAndStructuredOutputMatchTaggedVectors() throws {
        // v1.5.2 ai/src/utils/validation.ts:5-68 and durable/src/harness/tool.ts:778-801.
        let url = try #require(Bundle.module.url(forResource: "d8-schema-v152", withExtension: "json", subdirectory: "Fixtures"))
        let fixture = try JSONValue(jsonData: Data(contentsOf: url))
        #expect(fixture["tag"] == "v1.5.2")
        let schemas = try #require(fixture["schemas"]?.arrayValue)
        let cases = try #require(fixture["cases"]?.arrayValue)
        #expect(cases.count >= 3_000)
        var differences: [String] = []
        for row in cases {
            let id = try #require(row["id"]?.stringValue)
            let name = try #require(row["name"]?.stringValue)
            let index = try #require(row["schema"]?.numberValue).rounded(.towardZero)
            let schema = try #require(schemas[Int(index)].objectValue)
            let args = try #require(row["args"]?.objectValue)
            let schemaObject = try foundationJSON(from: .object(schema)) as! [String: Any]
            let argsObject = try foundationJSON(from: .object(args)) as! [String: Any]
            let tool = AITool(name: name, description: "", parameters: schemaObject.mapValues(AnyCodable.init))
            let call = ToolCall(id: id, name: name, arguments: argsObject.mapValues(AnyCodable.init),
                argumentsJSON: try OrderedJSON.parse(args.jsonText()), argumentsError: row["argumentsError"]?.stringValue)
            do {
                let result = try PiSwiftAI.validateToolArguments(tool: tool, toolCall: call,
                    orderedParameters: OrderedJSON.parse(schema.jsonText()))
                let value = try durableJSON(fromFoundation: result.mapValues(\.value))
                if try hash(value) != row["resultHash"]?.stringValue { differences.append("\(id): argument value") }
            } catch {
                if error.localizedDescription != row["error"]?.stringValue { differences.append("\(id): \(error.localizedDescription)") }
            }
            if let output = row["output"] {
                let actual = durableStructuredSchemaError(output, schema: schema)
                let expected = row["outputError"]?.stringValue
                if actual != expected { differences.append("\(id): output \(actual ?? "accepted")") }
            }
        }
        #expect(differences.isEmpty, "\(differences.count) differences: \(differences.prefix(12))")
    }
}
