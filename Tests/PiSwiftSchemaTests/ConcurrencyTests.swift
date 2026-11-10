import Testing
import PiSwiftSchema

@Test func validatorChecksConcurrently() async throws {
    let schema = try SchemaValue.parse(json: """
        {"$id":"https://example.test/tree.json","type":"object",
         "required":["children"],"properties":{"children":{"type":"array","items":{"$ref":"#"}}}}
        """)
    let validator = try compile(schema)
    let valid = try SchemaValue.parse(json: #"{"children":[{"children":[]},{"children":[{"children":[]}]}]}"#)
    let invalid = try SchemaValue.parse(json: #"{"children":[{"children":3}]}"#)

    let results = await withTaskGroup(of: Bool.self, returning: [Bool].self) { group in
        for index in 0..<256 {
            group.addTask {
                index.isMultiple(of: 2) ? validator.check(valid) : !validator.check(invalid)
            }
        }
        var values: [Bool] = []
        for await result in group { values.append(result) }
        return values
    }
    #expect(results.count == 256)
    #expect(results.allSatisfy { $0 })
}

@Test func dynamicValidatorChecksConcurrently() async throws {
    let schema = try SchemaValue.parse(json: """
        {"$id":"https://example.test/dynamic-tree.json","$dynamicAnchor":"node",
         "type":"object","required":["children"],
         "properties":{"children":{"type":"array","items":{"$dynamicRef":"#node"}}}}
        """)
    let validator = try compile(schema)
    let valid = try SchemaValue.parse(json: #"{"children":[{"children":[]},{"children":[{"children":[]}]}]}"#)
    let invalid = try SchemaValue.parse(json: #"{"children":[{"children":7}]}"#)

    let results = await withTaskGroup(of: Bool.self, returning: [Bool].self) { group in
        for index in 0..<256 {
            group.addTask {
                index.isMultiple(of: 2) ? validator.check(valid) : !validator.check(invalid)
            }
        }
        var values: [Bool] = []
        for await result in group { values.append(result) }
        return values
    }
    #expect(results.count == 256)
    #expect(results.allSatisfy { $0 })
}

@Test func branchlessIfUsesAnnotationsOnlyWhenNeeded() throws {
    let plain = try SchemaValue.parse(json: #"{"if":{"not":7}}"#)
    #expect(try compile(plain).check(.null))

    let annotating = try SchemaValue.parse(json: #"{"if":{"not":7},"unevaluatedProperties":false}"#)
    #expect(throws: SchemaCompileError.self) { try compile(annotating) }
}

@Test func unrelatedDynamicAnchorDoesNotCompile() throws {
    let schema = try SchemaValue.parse(json: """
        {"$id":"https://example.test/anchors.json",
         "$defs":{"good":{"$dynamicAnchor":"good","type":"string"},
                  "unused":{"$dynamicAnchor":"unused","not":7}},
         "$dynamicRef":"#good"}
        """)
    let validator = try compile(schema)
    #expect(validator.check(.string("ok")))
    #expect(!validator.check(.number(3)))
}

@Test(arguments: [
    #"{"type":"object","properties":{"n":{"type":"integer"}},"required":["n"]}"#,
    ##"{"$id":"https://example.test/tree.json","type":"object","properties":{"n":{"type":"integer"},"children":{"type":"array","items":{"$ref":"#"}}},"required":["n"]}"##,
    ##"{"$id":"https://example.test/dynamic.json","$dynamicAnchor":"node","type":"object","properties":{"n":{"type":"integer"},"children":{"type":"array","items":{"$dynamicRef":"#node"}}},"required":["n"]}"##,
])
func validatorErrorsAndChecksConcurrently(schemaText: String) async throws {
    let validator = try compile(.parse(json: schemaText))
    let valid = try SchemaValue.parse(json: #"{"n":1,"children":[]}"#)
    let invalid = try SchemaValue.parse(json: #"{"n":"x","children":[{"n":2,"children":[]}] }"#)
    let expected = validator.errors(invalid)
    #expect(!expected.isEmpty)
    let results = await withTaskGroup(of: Bool.self, returning: [Bool].self) { group in
        for index in 0..<256 {
            group.addTask {
                switch index % 4 {
                case 0: return validator.check(valid)
                case 1: return !validator.check(invalid)
                case 2: return validator.errors(invalid) == expected
                default: return validator.errors(valid).isEmpty
                }
            }
        }
        var values: [Bool] = []
        for await result in group { values.append(result) }
        return values
    }
    #expect(results.count == 256)
    #expect(results.allSatisfy { $0 })
}
