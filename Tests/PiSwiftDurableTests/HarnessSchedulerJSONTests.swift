import Testing
import PiSwiftChord
@testable import PiSwiftDurable

@Suite struct HarnessSchedulerJSONTests {
    @Test func directObjectDecodeKeepsKeyOrderIdentityAndValueOwnership() throws {
        let source: JSONObject = ["z": .null, "10": .number(10), "2": .number(2),
                                  "é": .string("composed"), "e\u{301}": .string("decomposed"),
                                  "nested": .object(["value": .array([.bool(true)])])]
        let value = JSONValue.object(source)
        var decoded = try value.decode(JSONObject.self)
        #expect(decoded.keys == source.keys)
        #expect(try decoded.jsonText() == source.jsonText())
        decoded["é"] = .string("changed")
        decoded["nested"] = nil
        #expect(source["é"] == .string("composed"))
        #expect(source["e\u{301}"] == .string("decomposed"))
        #expect(source["nested"] != nil)
    }

    @Test func directPrimitiveEncodeKeepsTypesAndNumberValidation() throws {
        #expect(try JSONValue(encoding: "true") == .string("true"))
        #expect(try JSONValue(encoding: true) == .bool(true))
        #expect(try JSONValue(encoding: 1.25) == .number(1.25))
        #expect(try JSONValue(encoding: -0.0) == .number(-0.0))
        for value in [Double.nan, .infinity, -.infinity] {
            #expect(throws: JSONValueError.nonFiniteNumber) { try JSONValue(encoding: value) }
        }
    }

    @Test func directPrimitiveDecodeKeepsTypesAndRejectsInvalidNumbers() throws {
        #expect(try JSONValue.string("true").decode(String.self) == "true")
        #expect(try JSONValue.bool(true).decode(Bool.self))
        #expect(try JSONValue.number(1.25).decode(Double.self) == 1.25)
        #expect(throws: DecodingError.self) { try JSONValue.bool(true).decode(String.self) }
        #expect(throws: DecodingError.self) { try JSONValue.number(1).decode(Bool.self) }
        #expect(throws: DecodingError.self) { try JSONValue.string("1").decode(Double.self) }
        for value in [Double.nan, .infinity, -.infinity] {
            #expect(throws: DecodingError.self) { try JSONValue.number(value).decode(Double.self) }
        }
    }

    private struct ObjectBody: Encodable {
        let value: JSONObject
        func encode(to encoder: any Encoder) throws { try value.encode(to: encoder) }
    }

    @Test func directObjectEncodeKeepsShapeAndRejectsNonFiniteNumbers() throws {
        let object: JSONObject = ["z": .null, "10": .number(10), "2": .number(2),
                                  "é": .string("composed"), "e\u{301}": .string("decomposed")]
        #expect(try JSONValue(encoding: ObjectBody(value: object)).jsonText() == object.jsonText())
        for value in [Double.nan, .infinity, -.infinity] {
            #expect(throws: JSONValueError.nonFiniteNumber) {
                try JSONValue(encoding: ObjectBody(value: ["nested": .object(["value": .number(value)])]))
            }
        }
    }

    private struct MergedBody: Encodable {
        let first: JSONObject
        let second: JSONObject
        func encode(to encoder: any Encoder) throws {
            try first.encode(to: encoder)
            try second.encode(to: encoder)
        }
    }

    @Test func directObjectEncodeStillMergesRepeatedKeyedContainers() throws {
        let body = MergedBody(first: ["z": .number(1), "value": .number(2)],
                              second: ["value": .number(3), "a": .null])
        #expect(try JSONValue(encoding: body).jsonText() == "{\"z\":1,\"value\":3,\"a\":null}")
    }

    @Test func recordExtensionsKeepExactUnknownKeysAndTheirOrder() throws {
        let object: JSONObject = ["known": .number(0), "10": .number(10), "2": .number(2),
                                  "é": .string("composed"), "e\u{301}": .string("decomposed"), "last": .null]
        let remaining = recordExtensions(object, excluding: ["known", "é", "2", "absent"])
        #expect(remaining.keys == ["10", "e\u{301}", "last"])
        #expect(remaining["é"] == nil)
        #expect(remaining["e\u{301}"] == .string("decomposed"))
        #expect(object["known"] == .number(0))
    }

    @Test func strictObjectValidationChecksNestedValues() {
        #expect(JSONValue.object(["10": .array([.object(["value": .number(1)])]), "z": .null]).isStrictJSON)
        for value in [Double.nan, .infinity, -.infinity] {
            let object = JSONValue.object(["10": .array([.object(["value": .number(value)])]), "z": .null])
            #expect(!object.isStrictJSON)
            #expect(throws: JSONValueError.nonFiniteNumber) { try object.jsonText() }
        }
    }

    @Test(arguments: [JSONValue.null, .array([]), .number(1), .bool(false), .string("object")])
    func directObjectDecodeRejectsOtherShapes(value: JSONValue) {
        #expect(throws: DecodingError.self) { try value.decode(JSONObject.self) }
    }
}
