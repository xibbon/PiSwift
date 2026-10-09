import Foundation
import Testing
import PiSwiftChord

@Suite struct JSONValueTests {
    @Test func checksStrictJSONWithoutNormalizingIt() {
        let value: JSONValue = ["nested": [1, true, nil]]
        #expect(value.isStrictJSON)
        #expect(!JSONValue.number(.infinity).isStrictJSON)
        #expect(!JSONValue.object(["nested": [.number(.nan)]]).isStrictJSON)
        #expect(value["nested"]?[0] == 1)
    }

    @Test func copiesStrictJSONWithoutRetainingAliases() throws {
        struct Nested: Encodable { let value: Int }
        struct Pair: Encodable { let left: Nested; let right: Nested }
        let shared = Nested(value: 1)
        let copied = try JSONValue(encoding: Pair(left: shared, right: shared))
        #expect(copied["left"] == copied["right"])
        var left = try #require(copied["left"]?.objectValue)
        left["value"] = 2
        #expect(copied["left"]?["value"] == 1)
        #expect(copied["right"]?["value"] == 1)
        #expect(left["value"] == 2)
    }

    @Test func omitsOptionalPropertiesAndKeepsExplicitNull() throws {
        struct OptionalValue: Encodable { let kept: Int; let omitted: String? }
        struct ExplicitNull: Encodable {
            enum CodingKeys: String, CodingKey { case value }
            func encode(to encoder: any Encoder) throws {
                var container = encoder.container(keyedBy: CodingKeys.self)
                try container.encodeNil(forKey: .value)
            }
        }
        let value = try JSONValue(encoding: OptionalValue(kept: 1, omitted: nil))
        #expect(value.objectValue?.keys == ["kept"])
        #expect(value["omitted"] == nil)
        #expect(try JSONValue(encoding: ExplicitNull())["value"] == .null)
        #expect(try JSONValue(encoding: [Int?.none, 1]) == [nil, 1])
    }

    @Test func preservesOwnProtoDataProperties() throws {
        let text = #"{"__proto__":{"safe":true}}"#
        let value = try JSONValue(jsonText: text)
        #expect(value.objectValue?.contains("__proto__") == true)
        #expect(value["__proto__"]?["safe"] == true)
        #expect(try value.jsonText() == text)
    }

    @Test func equalityUsesScalarsAndIgnoresObjectOrder() {
        let composed = "\u{e9}"
        let decomposed = "e\u{301}"
        #expect(JSONValue.string(composed) != .string(decomposed))
        let object = JSONObject([(composed, 1), (decomposed, 2)])
        #expect(object.count == 2)
        #expect(object[composed] == 1)
        #expect(object[decomposed] == 2)
        #expect(object != JSONObject([(composed, 2), (decomposed, 1)]))
        #expect(JSONObject([("b", 2), ("a", 1)]) == JSONObject([("a", 1), ("b", 2)]))
        #expect(JSONValue.array([1, 2]) != .array([2, 1]))
        #expect(JSONValue.number(-0.0) == .number(0))
    }

    @Test func objectMutationAndSequenceKeepKeyRules() throws {
        var object = JSONObject([("b", 1), ("10", 2), ("a", 3), ("2", 4), ("b", 5)])
        #expect(object.keys == ["2", "10", "b", "a"])
        #expect(object.values == [4, 2, 5, 3])
        #expect(object.count == 4)
        #expect(!object.isEmpty)
        let copy = object
        object["b"] = 6
        #expect(object.keys == copy.keys)
        #expect(copy["b"] == 5)
        #expect(object.removeValue(forKey: "b") == 6)
        #expect(object.removeValue(forKey: "missing") == nil)
        object["b"] = .null
        #expect(object.keys == ["2", "10", "a", "b"])
        #expect(object.contains("b"))
        #expect(object["b"] == .null)
        #expect(Array(object).map(\.key) == object.keys)
        #expect(Array(object).map(\.value) == object.values)
        object["b"] = nil
        #expect(!object.contains("b"))
        #expect(JSONObject().isEmpty)
    }

    @Test func literalsAndAccessors() throws {
        let null: JSONValue = nil
        let boolean: JSONValue = true
        let integer: JSONValue = 42
        let floating: JSONValue = 1.5
        let string: JSONValue = "text"
        let array: JSONValue = [null, boolean, integer]
        let object: JSONValue = ["b": 1, "2": 2, "a": 3, "b": 4]
        #expect(null.isNull)
        #expect(!integer.isNull)
        #expect(boolean.boolValue == true)
        #expect(integer.numberValue == 42)
        #expect(integer.intValue == 42)
        #expect(integer.int64Value == 42)
        #expect(floating.intValue == nil)
        #expect(floating.int64Value == nil)
        #expect(JSONValue.number(.infinity).intValue == nil)
        #expect(JSONValue.number(Double(Int64.max)).int64Value == nil)
        #expect(string.stringValue == "text")
        #expect(array.arrayValue == [nil, true, 42])
        #expect(object.objectValue?.keys == ["2", "b", "a"])
        #expect(object["b"] == 4)
        #expect(array[-1] == nil)
        #expect(array[3] == nil)
        #expect(integer[0] == nil)
        #expect(integer["x"] == nil)
        #expect(integer.boolValue == nil)
        #expect(integer.stringValue == nil)
        #expect(integer.arrayValue == nil)
        #expect(integer.objectValue == nil)
        #expect(string.numberValue == nil)
        #expect(string.intValue == nil)
        #expect(string.int64Value == nil)
        #expect(object.description == (try object.jsonText()))
        #expect(object.debugDescription == object.description)
        #expect(JSONValue.number(.nan).description == "NaN")
        #expect(JSONValue.number(.infinity).description == "Infinity")
        #expect(JSONValue.number(-.infinity).description == "-Infinity")
    }

    @Test func strictErrorsHaveExpectedCasesAndText() throws {
        for number in [Double.nan, .infinity, -.infinity] {
            #expect(throws: JSONValueError.nonFiniteNumber) { try JSONValue.number(number).jsonText() }
            #expect(throws: JSONValueError.nonFiniteNumber) { try JSONValue(encoding: number) }
        }
        #expect(throws: JSONValueError.nonFiniteNumber) { try JSONValue(encoding: Float.infinity) }
        #expect(throws: JSONValueError.nonFiniteNumber) { try JSONValue.object(["x": [.number(.nan)]]).jsonText() }
        #expect(JSONValueError.nonFiniteNumber.description == "Value contains a non-finite number and is not strict JSON")
        #expect(throws: JSONValueError.nonFiniteNumber) { try JSONValue(jsonText: "1e400") }
        #expect(throws: JSONValueError.nonFiniteNumber) { try JSONValue(jsonText: "-1e400") }
        for text in [#""\ud800""#, #""\udc00""#, #""\ud800x""#, #""\ud800\u0041""#] {
            do {
                _ = try JSONValue(jsonText: text)
                Issue.record("A lone surrogate was accepted")
            } catch JSONValueError.loneSurrogate(let offset) {
                #expect(offset >= 1 && offset < text.utf8.count)
            }
        }
        #expect(throws: JSONValueError.unsafeInteger) { try JSONValue(encoding: Int64(9_007_199_254_740_993)) }
        #expect(try JSONValue(encoding: Int64(9_007_199_254_740_992)) == .number(9_007_199_254_740_992))
        #expect(throws: JSONValueError.unsafeInteger) { try JSONValue(encoding: UInt64.max) }
    }

    @Test func parserErrorsUseByteOffsetsAndRejectBadUTF8() throws {
        do {
            _ = try JSONValue(jsonText: #"["é",?]"#)
            Issue.record("Invalid JSON was accepted")
        } catch JSONValueError.invalidJSON(let offset, _) {
            #expect(offset == 6)
        }
        #expect(throws: JSONValueError.self) { try JSONValue(jsonData: Data([0x22, 0xff, 0x22])) }
        #expect(throws: JSONValueError.self) { try JSONValue(jsonData: Data([0xef, 0xbb, 0xbf, 0x31])) }
    }

    @Test func keepsByteOrderMarksInsideStrings() throws {
        // A raw U+FEFF at the start of a string and after an escape stays, as in JSON.parse.
        let bom: [UInt8] = [0xef, 0xbb, 0xbf]
        let text = [0x22] + bom + [0x61, 0x5c, 0x6e] + bom + [0x62, 0x22]
        #expect(try JSONValue(jsonData: Data(text)) == .string("\u{FEFF}a\n\u{FEFF}b"))
        #expect(try JSONValue(jsonText: "[\"\u{FEFF}\"]") == .array([.string("\u{FEFF}")]))
    }
}
