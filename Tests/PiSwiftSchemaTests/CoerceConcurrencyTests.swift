import Testing
import PiSwiftSchema

@Test(arguments: [
    #"{"type":"object","properties":{"n":{"type":"integer"}},"required":["n"]}"#,
    ##"{"$id":"https://example.test/tree.json","type":"object","properties":{"n":{"type":"integer"},"children":{"type":"array","items":{"$ref":"#"}}},"required":["n"]}"##,
    ##"{"$id":"https://example.test/dynamic.json","$dynamicAnchor":"node","type":"object","properties":{"n":{"type":"integer"},"children":{"type":"array","items":{"$dynamicRef":"#node"}}},"required":["n"]}"##,
])
func coercingValidatorConcurrentCalls(schemaText: String) async throws {
    let validator = try compileCoercing(.parse(json: schemaText))
    let input = try SchemaValue.parse(json: #"{"n":"2","children":[]}"#)
    let expected = try SchemaValue.parse(json: #"{"n":2,"children":[]}"#)
    let bad = try SchemaValue.parse(json: #"{"n":"x","children":[]}"#)
    let expectedErrors = validator.errors(bad)
    let outcomes = await withTaskGroup(of: Bool.self, returning: [Bool].self) { group in
        for index in 0..<256 {
            group.addTask {
                switch index % 5 {
                case 0: return validator.coerce(input) == expected
                case 1:
                    if case .ok(let result) = validator.parse(input) { return result == expected }
                    return false
                case 2: return validator.check(expected)
                case 3: return validator.errors(bad) == expectedErrors
                default: return !validator.check(bad)
                }
            }
        }
        var results: [Bool] = []
        for await result in group { results.append(result) }
        return results
    }
    #expect(outcomes.count == 256)
    #expect(outcomes.allSatisfy { $0 })
}
