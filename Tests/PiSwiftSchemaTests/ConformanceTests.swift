import Foundation
import Testing
@testable import PiSwiftSchema

private let fixtures = (Bundle.module.resourceURL ?? Bundle.module.bundleURL).appendingPathComponent("Fixtures")

private struct SuiteCase: Sendable, CustomTestStringConvertible {
    var testDescription: String { id }
    let id: String
    let draft: String
    let schema: SchemaValue
    let data: SchemaValue
    let valid: Bool
}

private let knownFailures: Set<String> = [
    "draft2020-12/vocabulary > schema that uses custom metaschema with with no validation vocabulary > no validation: invalid number, but it still validates",
    "draft2020-12/optional/format-assertion > schema that uses custom metaschema with format-assertion: false > format-assertion: false: invalid string",
    "draft2020-12/optional/format-assertion > schema that uses custom metaschema with format-assertion: true > format-assertion: true: invalid string",
    "draft2020-12/optional/cross-draft > refs to historic drafts are processed as historic drafts > first item not a string is valid",
    "draft7/optional/cross-draft > refs to future drafts are processed as future drafts > missing bar is invalid",
    "draft7/optional/content > validation of string-encoded content based on media type > an invalid JSON document",
    "draft7/optional/content > validation of binary string-encoding > an invalid base64 string (% is not a valid character)",
    "draft7/optional/content > validation of binary-encoded media type documents > a validly-encoded invalid JSON document",
    "draft7/optional/content > validation of binary-encoded media type documents > an invalid base64 string that is valid JSON",
]

private func jsonFiles(_ root: URL) throws -> [URL] {
    guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { throw FixtureError.invalid(root.path) }
    return enumerator.compactMap { $0 as? URL }.filter { $0.pathExtension == "json" }.sorted { $0.path < $1.path }
}

private func suiteSchemas() throws -> [String: SchemaValue] {
    let remote = fixtures.appendingPathComponent("json-schema-test-suite/remotes")
    var schemas: [String: SchemaValue] = [:]
    for url in try jsonFiles(remote) {
        let relative = String(url.path.dropFirst(remote.path.count + 1))
        schemas["http://localhost:1234/\(relative)"] = try .parse(json: Data(contentsOf: url))
    }
    let meta = fixtures.appendingPathComponent("meta-schemas")
    func read(_ name: String) throws -> SchemaValue { try .parse(json: Data(contentsOf: meta.appendingPathComponent(name))) }
    schemas["http://json-schema.org/draft-07/schema"] = try read("draft-07-schema.json")
    schemas["https://json-schema.org/draft/2020-12/schema"] = try read("draft2020-12-schema.json")
    for name in ["core", "applicator", "unevaluated", "validation", "meta-data", "format-annotation", "content"] {
        schemas["https://json-schema.org/draft/2020-12/meta/\(name)"] = try read("draft2020-12-meta-\(name).json")
    }
    return schemas
}

private let sharedSchemas = Result { try suiteSchemas() }

private func suiteCases() throws -> [SuiteCase] {
    let root = fixtures.appendingPathComponent("json-schema-test-suite/tests")
    var cases: [SuiteCase] = []
    for draft in ["draft2020-12", "draft7"] {
        for url in try jsonFiles(root.appendingPathComponent(draft)) {
            let name = String(url.path.dropFirst(root.path.count + 1).dropLast(5))
            if name.contains("/optional/format/") { continue }
            guard case let .array(groups) = try SchemaValue.parse(json: Data(contentsOf: url)) else { throw FixtureError.invalid(name) }
            for group in groups {
                guard case let .object(group) = group,
                      case let .string(description)? = group["description"],
                      let schema = group["schema"], case let .array(tests)? = group["tests"] else { throw FixtureError.invalid(name) }
                for test in tests {
                    guard case let .object(test) = test, case let .string(testDescription)? = test["description"],
                          let data = test["data"], case let .bool(valid)? = test["valid"] else { throw FixtureError.invalid(name) }
                    let id = "\(name) > \(description) > \(testDescription)"
                    cases.append(SuiteCase(id: id, draft: draft, schema: schema, data: data, valid: valid))
                }
            }
        }
    }
    return cases
}

private enum FixtureError: Error { case invalid(String) }

@Test(arguments: try suiteCases()) private func jsonSchemaConformance(item: SuiteCase) throws {
    let schemas = try sharedSchemas.get()
    let validator = try compile(item.schema, options: .init(draft: item.draft == "draft7" ? .draft7 : .draft2020_12, schemas: schemas))
    let actual = validator.check(item.data)
    if knownFailures.contains(item.id) {
        #expect(actual != item.valid, "Known failure now passes: \(item.id)")
    } else {
        #expect(actual == item.valid, "\(item.id): expected \(item.valid), got \(actual)")
    }
}

@Test func knownFailureNamesExist() throws {
    #expect(knownFailures.isSubset(of: Set(try suiteCases().map(\.id))))
}

private struct DifferentialCase: Sendable, CustomTestStringConvertible {
    var testDescription: String { id }
    let id: String
    let schema: SchemaValue
    let data: SchemaValue
    let draft: String
    let reject: Bool
    let expected: Bool?
    let thrown: String?
}

private func differentialCases() throws -> [DifferentialCase] {
    let url = fixtures.appendingPathComponent("generated/check-v1.5.2.jsonl")
    let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
    var cases: [DifferentialCase] = []
    for line in lines.dropFirst() {
        guard case let .object(item) = try SchemaValue.parse(json: String(line)),
              case let .string(id)? = item["id"], let schema = item["schema"], let data = item["data"] else {
            throw FixtureError.invalid("differential JSONL")
        }
        // Swift SchemaValue represents JSON only; JS undefined and bigint have no JSON value.
        if item["format"] == .bool(true) || item["dataKind"] != nil { continue }
        let draft: String
        if case let .string(value)? = item["draft"] { draft = value } else { draft = "2020-12" }
        let expected: Bool?
        if case let .bool(value)? = item["expected"] { expected = value } else { expected = nil }
        let thrown: String?
        if case let .string(value)? = item["thrown"] { thrown = value } else { thrown = nil }
        cases.append(DifferentialCase(id: id, schema: schema, data: data, draft: draft,
                                      reject: item["unresolvedRefs"] == .string("reject"), expected: expected, thrown: thrown))
    }
    return cases
}

@Test(arguments: try differentialCases()) private func differentialCheck(item: DifferentialCase) throws {
    let options = CompileOptions(draft: item.draft == "7" ? .draft7 : .draft2020_12,
                                 schemas: try sharedSchemas.get(), unresolvedRefs: item.reject ? .reject : .throw)
    if let expected = item.expected {
        let validator = try compile(item.schema, options: options)
        #expect(validator.check(item.data) == expected, "\(item.id)")
    } else {
        #expect(item.thrown != nil, "Missing result: \(item.id)")
        do {
            _ = try compile(item.schema, options: options)
            Issue.record("Expected compile error for \(item.id)")
        } catch let error as SchemaCompileError {
            #expect(error.description == item.thrown, "Error message for \(item.id)")
        }
    }
}
