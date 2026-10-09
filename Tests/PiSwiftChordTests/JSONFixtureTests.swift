import Foundation
import Testing
import PiSwiftChord

private struct JSONFixtures: Decodable {
    struct Number: Decodable { let bits: String; let text: String }
    struct Operation: Decodable { let op: String; let key: String; let value: JSONValue? }
    struct KeyOrder: Decodable {
        let name: String
        let operations: [Operation]
        let keys: [String]
        let text: String
    }
    struct StringCase: Decodable { let value: String; let text: String }
    struct Parse: Decodable {
        struct Valid: Decodable { let input: String; let text: String }
        let valid: [Valid]
        let invalid: [String]
    }
    let numbers: [Number]
    let keyOrders: [KeyOrder]
    let strings: [StringCase]
    let parse: Parse
}

private func fixtures() throws -> JSONFixtures {
    let url = try #require(Bundle.module.url(forResource: "json-fixtures", withExtension: "json", subdirectory: "Fixtures"))
    return try JSONDecoder().decode(JSONFixtures.self, from: Data(contentsOf: url))
}

@Suite struct JSONFixtureTests {
    @Test func numbersMatchNode() throws {
        let cases = try fixtures().numbers
        #expect(cases.count >= 1025)
        for entry in cases {
            let bits = try #require(UInt64(entry.bits, radix: 16))
            let number = Double(bitPattern: bits)
            let text = try JSONValue.number(number).jsonText()
            #expect(Array(text.utf8) == Array(entry.text.utf8), "bits: \(entry.bits)")
            let parsed = try #require(JSONValue(jsonText: entry.text).numberValue)
            #expect(parsed.bitPattern == (number == 0 ? 0 : bits), "bits: \(entry.bits)")
        }
    }

    @Test func keyOrdersMatchNode() throws {
        for entry in try fixtures().keyOrders {
            var object = JSONObject()
            for operation in entry.operations {
                if operation.op == "remove" {
                    object.removeValue(forKey: operation.key)
                } else {
                    // A missing fixture value is the JSON null value.
                    object[operation.key] = operation.value ?? .null
                }
            }
            #expect(object.keys.map { Array($0.utf8) } == entry.keys.map { Array($0.utf8) }, "case: \(entry.name)")
            let text = try object.jsonText()
            #expect(Array(text.utf8) == Array(entry.text.utf8), "case: \(entry.name)")
            let parsed = try #require(JSONValue(jsonText: entry.text).objectValue)
            #expect(parsed == object, "case: \(entry.name)")
            #expect(parsed.keys.map { Array($0.utf8) } == entry.keys.map { Array($0.utf8) })
            #expect(Array(try parsed.jsonText().utf8) == Array(entry.text.utf8))
        }
    }

    @Test func stringsMatchNode() throws {
        for entry in try fixtures().strings {
            #expect(Array(try JSONValue.string(entry.value).jsonText().utf8) == Array(entry.text.utf8))
            let parsed = try #require(JSONValue(jsonText: entry.text).stringValue)
            #expect(Array(parsed.unicodeScalars) == Array(entry.value.unicodeScalars))
        }
    }

    @Test func validParseCasesMatchNode() throws {
        for entry in try fixtures().parse.valid {
            #expect(Array(try JSONValue(jsonText: entry.input).jsonText().utf8) == Array(entry.text.utf8))
            #expect(try JSONValue(jsonData: Data(entry.input.utf8)) == JSONValue(jsonText: entry.input))
        }
    }

    @Test func invalidParseCasesFail() throws {
        for text in try fixtures().parse.invalid {
            #expect(throws: JSONValueError.self) { try JSONValue(jsonText: text) }
        }
    }
}
