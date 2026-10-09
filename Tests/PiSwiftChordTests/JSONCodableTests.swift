import Foundation
import Testing
import PiSwiftChord

private struct BridgeNested: Codable, Equatable {
    let name: String
    let count: Int
}
private enum BridgeState: String, Codable { case ready, done }
private struct BridgePayload: Codable, Equatable {
    let nested: BridgeNested
    let omitted: String?
    let values: [Int?]
    let state: BridgeState
    let timestamp: Int64
    let dictionary: [String: Int]
}

private struct NestedContainers: Codable, Equatable {
    enum Keys: String, CodingKey { case x }
    let first: Int
    let second: Int
    let third: Int

    func encode(to encoder: any Encoder) throws {
        var container = encoder.unkeyedContainer()
        var array = container.nestedUnkeyedContainer()
        try array.encode(first)
        var object = container.nestedContainer(keyedBy: Keys.self)
        try object.encode(second, forKey: .x)
        try third.encode(to: container.superEncoder())
    }

    init(first: Int, second: Int, third: Int) {
        self.first = first
        self.second = second
        self.third = third
    }

    init(from decoder: any Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var array = try container.nestedUnkeyedContainer()
        first = try array.decode(Int.self)
        let object = try container.nestedContainer(keyedBy: Keys.self)
        second = try object.decode(Int.self, forKey: .x)
        third = try Int(from: container.superDecoder())
    }
}

private struct SuperContainers: Codable, Equatable {
    enum Keys: String, CodingKey { case value, parent }
    struct Base: Codable, Equatable { let base: Int }
    let value: Int
    let base: Base
    let parent: Base

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: Keys.self)
        try container.encode(value, forKey: .value)
        try base.encode(to: container.superEncoder())
        try parent.encode(to: container.superEncoder(forKey: .parent))
    }

    init(value: Int, base: Base, parent: Base) {
        self.value = value
        self.base = base
        self.parent = parent
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: Keys.self)
        value = try container.decode(Int.self, forKey: .value)
        base = try Base(from: container.superDecoder())
        parent = try Base(from: container.superDecoder(forKey: .parent))
    }
}

@Suite struct JSONCodableTests {
    @Test func directBridgeRoundTripKeepsDeclarationOrder() throws {
        let payload = BridgePayload(nested: .init(name: "one", count: 1), omitted: nil,
            values: [1, nil, 3], state: .ready, timestamp: 1_791_500_123_456,
            dictionary: ["a": 1, "b": 2])
        let json = try JSONValue(encoding: payload)
        #expect(json.objectValue?.keys == ["nested", "values", "state", "timestamp", "dictionary"])
        #expect(json["nested"]?.objectValue?.keys == ["name", "count"])
        #expect(json["values"] == [1, nil, 3])
        #expect(json["state"] == "ready")
        #expect(json["timestamp"]?.int64Value == payload.timestamp)
        #expect(try json.decode(BridgePayload.self) == payload)
        let inferred: BridgePayload = try json.decode()
        #expect(inferred == payload)
    }

    @Test func numericCodingKeysUseJavaScriptOrder() throws {
        struct NumericKeys: Encodable {
            enum Keys: String, CodingKey { case b, ten = "10", a, two = "2" }
            func encode(to encoder: any Encoder) throws {
                var container = encoder.container(keyedBy: Keys.self)
                try container.encode(1, forKey: .b)
                try container.encode(2, forKey: .ten)
                try container.encode(3, forKey: .a)
                try container.encode(4, forKey: .two)
            }
        }
        #expect(try JSONValue(encoding: NumericKeys()).objectValue?.keys == ["2", "10", "b", "a"])
    }

    @Test func repeatedKeyEncodingKeepsFirstPosition() throws {
        struct Repeated: Encodable {
            enum Keys: String, CodingKey { case b, a }
            func encode(to encoder: any Encoder) throws {
                var container = encoder.container(keyedBy: Keys.self)
                try container.encode(1, forKey: .b)
                try container.encode(2, forKey: .a)
                try container.encode(3, forKey: .b)
            }
        }
        let value = try JSONValue(encoding: Repeated())
        #expect(value.objectValue?.keys == ["b", "a"])
        #expect(value["b"] == 3)
        #expect(try value.jsonText() == #"{"b":3,"a":2}"#)
    }

    @Test func JSONTypesWorkInsideForeignCodableContainers() throws {
        struct Wrapper: Codable, Equatable { let value: JSONValue; let object: JSONObject }
        let wrapper = Wrapper(value: [1, true, nil, ["é": "e\u{301}"]], object: ["b": 2, "1": 1])
        let data = try JSONEncoder().encode(wrapper)
        #expect(try JSONDecoder().decode(Wrapper.self, from: data) == wrapper)
        #expect(try JSONValue(encoding: wrapper).decode(Wrapper.self) == wrapper)
        #expect(try JSONValue(encoding: wrapper.value) == wrapper.value)
        #expect(try JSONValue(encoding: wrapper.object) == .object(wrapper.object))
        let scalarKeys = JSONObject([("é", 1), ("e\u{301}", 2)])
        #expect(try JSONValue(encoding: scalarKeys).objectValue?.count == 2)
        #expect(try JSONValue(encoding: JSONValue.object(scalarKeys)).objectValue?.count == 2)
    }

    @Test func ownCodableImplementationsHandleDateDataAndURL() throws {
        struct Standard: Codable, Equatable { let date: Date; let data: Data; let url: URL }
        let standard = Standard(date: Date(timeIntervalSinceReferenceDate: 1234.5),
            data: Data([0, 1, 127, 255]), url: try #require(URL(string: "https://example.com/a?b=1")))
        #expect(try JSONValue(encoding: standard).decode(Standard.self) == standard)
    }

    @Test func nestedUnkeyedAndSuperContainersRoundTrip() throws {
        let value = NestedContainers(first: 7, second: 8, third: 9)
        let json = try JSONValue(encoding: value)
        #expect(json == [[7], ["x": 8], 9])
        #expect(try json.decode(NestedContainers.self) == value)
        let supers = SuperContainers(value: 1, base: .init(base: 2), parent: .init(base: 3))
        let superJSON = try JSONValue(encoding: supers)
        #expect(superJSON == ["value": 1, "super": ["base": 2], "parent": ["base": 3]])
        #expect(try superJSON.decode(SuperContainers.self) == supers)
    }

    @Test func nestedKeyedContainersAndEncodingPaths() throws {
        struct Paths: Encodable {
            enum Keys: String, CodingKey { case group, items, empty }
            struct Probe: Encodable {
                func encode(to encoder: any Encoder) throws {
                    #expect(encoder.codingPath.count == 3)
                    #expect(encoder.codingPath[0].stringValue == "group")
                    #expect(encoder.codingPath[1].stringValue == "items")
                    #expect(encoder.codingPath[2].intValue == 0)
                    var container = encoder.singleValueContainer()
                    try container.encode("ok")
                }
            }
            func encode(to encoder: any Encoder) throws {
                #expect(encoder.codingPath.isEmpty)
                var root = encoder.container(keyedBy: Keys.self)
                var group = root.nestedContainer(keyedBy: Keys.self, forKey: .group)
                var items = group.nestedUnkeyedContainer(forKey: .items)
                try items.encode(Probe())
                _ = root.nestedUnkeyedContainer(forKey: .empty)
            }
        }
        #expect(try JSONValue(encoding: Paths()) == ["group": ["items": ["ok"]], "empty": []])
        #expect(try JSONValue(encoding: [Int]()) == [])
        #expect(try JSONValue(encoding: [String: Int]()) == [:])
    }

    @Test func integersDecodeOnlyWhenIntegralAndInRange() throws {
        #expect(try JSONValue.number(1.0).decode(Int.self) == 1)
        #expect(try JSONValue.number(127).decode(Int8.self) == 127)
        #expect(try JSONValue.number(255).decode(UInt8.self) == 255)
        #expect(try JSONValue.number(32_767).decode(Int16.self) == 32_767)
        #expect(try JSONValue.number(65_535).decode(UInt16.self) == 65_535)
        #expect(try JSONValue.number(2_147_483_647).decode(Int32.self) == 2_147_483_647)
        #expect(try JSONValue.number(4_294_967_295).decode(UInt32.self) == 4_294_967_295)
        #expect(try JSONValue.number(42).decode(Int64.self) == 42)
        #expect(try JSONValue.number(42).decode(UInt64.self) == 42)
        #expect(try JSONValue.number(42).decode(UInt.self) == 42)
        #expect(try JSONValue.number(1.5).decode(Double.self) == 1.5)
        #expect(try JSONValue.number(1.5).decode(Float.self) == 1.5)
        #expect(throws: DecodingError.self) { try JSONValue.number(1.5).decode(Int.self) }
        #expect(throws: DecodingError.self) { try JSONValue.number(128).decode(Int8.self) }
        #expect(throws: DecodingError.self) { try JSONValue.number(-1).decode(UInt.self) }
        #expect(throws: DecodingError.self) { try JSONValue.number(Double(Int64.max)).decode(Int64.self) }
        #expect(throws: DecodingError.self) { try JSONValue.null.decode(Int.self) }
        #expect(throws: DecodingError.self) { try JSONValue.bool(true).decode(Int.self) }
    }

    @Test func allIntegerEncodingOverloadsPreserveExactValues() throws {
        #expect(try JSONValue(encoding: Int(42)) == 42)
        #expect(try JSONValue(encoding: Int8(-128)) == -128)
        #expect(try JSONValue(encoding: Int16(-32_768)) == -32_768)
        #expect(try JSONValue(encoding: Int32(-2_147_483_648)) == -2_147_483_648)
        #expect(try JSONValue(encoding: Int64(-9_007_199_254_740_992)) == .number(-9_007_199_254_740_992))
        #expect(try JSONValue(encoding: UInt(42)) == 42)
        #expect(try JSONValue(encoding: UInt8(255)) == 255)
        #expect(try JSONValue(encoding: UInt16(65_535)) == 65_535)
        #expect(try JSONValue(encoding: UInt32(4_294_967_295)) == .number(4_294_967_295))
        #expect(try JSONValue(encoding: UInt64(9_007_199_254_740_992)) == .number(9_007_199_254_740_992))
        #expect(try JSONValue(encoding: Float(1.5)) == 1.5)
        #expect(try JSONValue(encoding: true) == true)
        #expect(try JSONValue(encoding: "é") == "é")
    }

    @Test func wideIntegersUseExactDoubleValues() throws {
        struct Wide: Codable, Equatable {
            let signed: Int128
            let unsigned: UInt128
            let optional: Int128?
            let signedArray: [Int128]
            let unsignedArray: [UInt128]
        }
        let exact = Int128(1) << 100
        let wide = Wide(signed: -exact, unsigned: UInt128(exact), optional: exact,
            signedArray: [exact], unsignedArray: [UInt128(exact)])
        let json = try JSONValue(encoding: wide)
        #expect(try json.decode(Wide.self) == wide)
        #expect(try JSONValue(encoding: exact).decode(Int128.self) == exact)
        #expect(try JSONValue(encoding: UInt128(exact)).decode(UInt128.self) == UInt128(exact))
        #expect(throws: JSONValueError.unsafeInteger) { try JSONValue(encoding: exact + 1) }
        #expect(throws: DecodingError.self) { try JSONValue.number(1e40).decode(Int128.self) }
        #expect(throws: DecodingError.self) { try JSONValue.number(-1).decode(UInt128.self) }
    }

    @Test func decodingErrorsContainNestedCodingPaths() throws {
        struct Row: Decodable { let count: Int }
        struct Rows: Decodable { let rows: [Row] }
        do {
            _ = try JSONValue.object(["rows": [["count": 1.5]]]).decode(Rows.self)
            Issue.record("A fractional integer was accepted")
        } catch let error as DecodingError {
            let context: DecodingError.Context
            switch error {
            case .typeMismatch(_, let value), .dataCorrupted(let value): context = value
            default: Issue.record("Unexpected error: \(error)"); return
            }
            #expect(context.codingPath.count == 3)
            #expect(context.codingPath[0].stringValue == "rows")
            #expect(context.codingPath[1].intValue == 0)
            #expect(context.codingPath[2].stringValue == "count")
        }
        do {
            _ = try JSONValue.object(["rows": [[:]]]).decode(Rows.self)
            Issue.record("A missing key was accepted")
        } catch DecodingError.keyNotFound(let key, let context) {
            #expect(key.stringValue == "count")
            #expect(context.codingPath.count == 2)
            #expect(context.codingPath[0].stringValue == "rows")
            #expect(context.codingPath[1].intValue == 0)
        }
        do {
            _ = try JSONValue.object(["rows": [["count": "bad"]]]).decode(Rows.self)
            Issue.record("A wrong type was accepted")
        } catch DecodingError.typeMismatch(_, let context) {
            #expect(context.codingPath.count == 3)
            #expect(context.codingPath.last?.stringValue == "count")
        }
        struct Required: Decodable { let required: Int }
        do {
            _ = try JSONValue.object([:]).decode(Required.self)
            Issue.record("A missing root key was accepted")
        } catch DecodingError.keyNotFound(let key, let context) {
            #expect(key.stringValue == "required")
            #expect(context.codingPath.isEmpty)
        }
    }

    @Test func nestedUnkeyedTypeErrorHasIndexPath() throws {
        do {
            _ = try JSONValue.array([[1, "bad"]]).decode([[Int]].self)
            Issue.record("A string integer was accepted")
        } catch DecodingError.typeMismatch(_, let context) {
            #expect(context.codingPath.count == 2)
            #expect(context.codingPath[0].intValue == 0)
            #expect(context.codingPath[1].intValue == 1)
        }
    }

    @Test func missingSuperKeysUseKeyNotFound() throws {
        struct ReadSuper: Decodable {
            enum Keys: String, CodingKey { case parent }
            init(from decoder: any Decoder) throws {
                let container = try decoder.container(keyedBy: Keys.self)
                do {
                    _ = try container.superDecoder()
                    Issue.record("A missing super key was accepted")
                } catch DecodingError.keyNotFound(let key, let context) {
                    #expect(key.stringValue == "super")
                    #expect(context.codingPath.isEmpty)
                }
                _ = try container.superDecoder(forKey: .parent)
            }
        }
        do {
            _ = try JSONValue.object([:]).decode(ReadSuper.self)
            Issue.record("A missing parent key was accepted")
        } catch DecodingError.keyNotFound(let key, let context) {
            #expect(key.stringValue == "parent")
            #expect(context.codingPath.isEmpty)
        }
    }

    @Test func unkeyedContainerTracksCountNullAndEndErrors() throws {
        struct ReadArray: Decodable {
            init(from decoder: any Decoder) throws {
                var container = try decoder.unkeyedContainer()
                #expect(container.count == 2)
                #expect(container.currentIndex == 0)
                #expect(!container.isAtEnd)
                #expect(try container.decodeNil())
                #expect(container.currentIndex == 1)
                #expect(!(try container.decodeNil()))
                #expect(container.currentIndex == 1)
                #expect(try container.decode(Int.self) == 1)
                #expect(container.isAtEnd)
                do {
                    _ = try container.decode(Int.self)
                    Issue.record("An exhausted array was accepted")
                } catch DecodingError.valueNotFound(_, let context) {
                    #expect(context.codingPath.last?.intValue == 2)
                }
            }
        }
        _ = try JSONValue.array([nil, 1]).decode(ReadArray.self)
    }
}
