import Foundation
import Testing
@testable import PiSwiftAI

private func g2JSON(_ text: String) throws -> Any {
    try JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed])
}

private func g2Schema(_ text: String) throws -> [String: Any] {
    try #require(g2JSON(text) as? [String: Any])
}

@Test func g2ToolArgumentEnvelopeRequiresBooleanComplete() throws {
    for literal in ["0", "1", "false", "true"] {
        let object = try g2Schema("{\"complete\":\(literal),\"calls\":[{\"arguments\":{\"z\":1,\"a\":0}}]}")
        #expect(jsonObjectCarriesToolArguments(object) == ["false", "true"].contains(literal))
    }
}

@Test func g2BooleanValidationRejectsNumbersWithoutCoercion() throws {
    for literal in ["0", "1", "false", "true"] {
        let value = try g2JSON(literal)
        let result = JSONSchemaValidator.shared.validate(value, against: ["type": "boolean"], coerceTypes: false)
        #expect(result.isValid == ["false", "true"].contains(literal))
        #expect(JSONSchemaValidator.shared.validate(value, against: ["type": "boolean"], coerceTypes: true).isValid)
    }
}

@Test func g2SchemaEqualityKeepsBooleansDistinctFromNumbers() throws {
    for literal in ["0", "1", "false", "true"] {
        for keyword in ["const", "enum"] {
            let member = keyword == "const" ? literal : "[\(literal)]"
            let schema = try g2Schema("{\"\(keyword)\":\(member)}")
            for other in ["0", "1", "false", "true"] {
                #expect(JSONSchemaValidator.shared.validate(try g2JSON(other), against: schema, coerceTypes: false).isValid == (literal == other))
            }
        }
    }
}

@Test func g2UniqueItemsKeepsBooleansDistinctFromNumbers() throws {
    let schema = try g2Schema(#"{"type":"array","uniqueItems":true}"#)
    #expect(JSONSchemaValidator.shared.validate(try g2JSON("[0,false,1,true]"), against: schema, coerceTypes: false).isValid)
    for literal in ["0", "1", "false", "true"] {
        #expect(!JSONSchemaValidator.shared.validate(try g2JSON("[\(literal),\(literal)]"), against: schema, coerceTypes: false).isValid)
    }
}

@Test func g2StringCoercionKeepsBooleanText() throws {
    for literal in ["0", "1", "false", "true"] {
        let result = JSONSchemaValidator.shared.validate(try g2JSON(literal), against: ["type": "string"])
        #expect(result.isValid)
        #expect(result.coercedValue as? String == literal)
    }
}

@Test func g2SchemaReferenceRequiresBooleanOrObject() throws {
    for literal in ["0", "1", "false", "true"] {
        let schema = try g2Schema("{\"$ref\":\"#/$defs/flag\",\"$defs\":{\"flag\":\(literal)}}")
        #expect(JSONSchemaValidator.shared.validate("x", against: schema, coerceTypes: false).isValid == (literal == "true"))
    }
}

@Test func g2NullableRequiresBooleanTrue() throws {
    for literal in ["0", "1", "false", "true"] {
        let schema = try g2Schema("{\"type\":\"string\",\"nullable\":\(literal)}")
        #expect(JSONSchemaValidator.shared.validate(NSNull(), against: schema, coerceTypes: false).isValid == (literal == "true"))
        #expect(JSONSchemaValidator.shared.validate(nil, against: schema, coerceTypes: false).isValid == (literal == "true"))
    }
}

@Test func g2SchemaNumbersExcludeBooleans() throws {
    for literal in ["0", "1", "false", "true"] {
        let schema = try g2Schema("{\"type\":\"number\",\"minimum\":\(literal)}")
        #expect(JSONSchemaValidator.shared.validate(-1, against: schema, coerceTypes: false).isValid == ["false", "true"].contains(literal))
    }
}

@Test func g2ExclusiveMinimumKeepsNumberAndBooleanRules() throws {
    for literal in ["0", "1", "false", "true"] {
        let schema = try g2Schema("{\"type\":\"number\",\"minimum\":0,\"exclusiveMinimum\":\(literal)}")
        #expect(JSONSchemaValidator.shared.validate(1, against: schema, coerceTypes: false).isValid == (literal != "1"))
    }
}

@Test func g2ExclusiveMaximumKeepsNumberAndBooleanRules() throws {
    for literal in ["0", "1", "false", "true"] {
        let schema = try g2Schema("{\"type\":\"number\",\"maximum\":2,\"exclusiveMaximum\":\(literal)}")
        #expect(JSONSchemaValidator.shared.validate(1, against: schema, coerceTypes: false).isValid == ["false", "true"].contains(literal))
    }
}

@Test func g2UniqueItemsRequiresBooleanFlag() throws {
    for literal in ["0", "1", "false", "true"] {
        let schema = try g2Schema("{\"type\":\"array\",\"uniqueItems\":\(literal)}")
        #expect(JSONSchemaValidator.shared.validate([0, 0], against: schema, coerceTypes: false).isValid == (literal != "true"))
    }
}

@Test func g2PrefixItemsRequiresBooleanFalseToForbidRemainder() throws {
    for literal in ["0", "1", "false", "true"] {
        let schema = try g2Schema("{\"type\":\"array\",\"prefixItems\":[],\"items\":\(literal)}")
        #expect(JSONSchemaValidator.shared.validate([0], against: schema, coerceTypes: false).isValid == (literal != "false"))
    }
}

@Test func g2AdditionalItemsRequiresBooleanFalseToForbidRemainder() throws {
    for literal in ["0", "1", "false", "true"] {
        let schema = try g2Schema("{\"type\":\"array\",\"items\":[],\"additionalItems\":\(literal)}")
        #expect(JSONSchemaValidator.shared.validate([0], against: schema, coerceTypes: false).isValid == (literal != "false"))
    }
}

@Test func g2AdditionalPropertiesRequiresBooleanFalseToForbidProperty() throws {
    for literal in ["0", "1", "false", "true"] {
        let schema = try g2Schema("{\"type\":\"object\",\"additionalProperties\":\(literal)}")
        #expect(JSONSchemaValidator.shared.validate(["a": 0], against: schema, coerceTypes: false).isValid == (literal != "false"))
    }
}
