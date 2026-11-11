import Foundation
import Testing
@testable import PiSwiftAI

@Test func nestedAnyCodableWrappersPreserveJSONValues() throws {
    let object = AnyCodable(["location": AnyCodable(["type": AnyCodable("string")])])
    #expect((object.value as? [String: Any])?["location"] is [String: Any])
    #expect(((object.value as? [String: Any])?["location"] as? [String: Any])?["type"] as? String == "string")

    let array = AnyCodable([AnyCodable(42), AnyCodable([AnyCodable(true), AnyCodable(NSNull())])])
    let values = try #require(array.value as? [Any])
    #expect(values[0] as? Int == 42)
    let nested = try #require(values[1] as? [Any])
    #expect(nested[0] as? Bool == true)
    #expect(nested[1] is NSNull)

    let doubled = AnyCodable(AnyCodable(AnyCodable("value")))
    #expect(doubled == AnyCodable("value"))
    let roundTrip = try JSONDecoder().decode([AnyCodable].self,
        from: JSONEncoder().encode([object, array, doubled]))
    #expect(roundTrip == [object, array, doubled])
}
