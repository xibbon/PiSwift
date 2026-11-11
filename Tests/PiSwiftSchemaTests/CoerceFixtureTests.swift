// Differential checks against packages/schema at pi-mono v1.5.2.
import Foundation
import Testing
@testable import PiSwiftSchema

private let coerceFixtures = (Bundle.module.resourceURL ?? Bundle.module.bundleURL).appendingPathComponent("Fixtures")
private enum CoerceFixtureError: Error { case invalid(String) }

private struct CoerceFixtureCase: Sendable, CustomTestStringConvertible {
    var testDescription: String { id }
    let id: String
    let schema: SchemaValue
    let data: SchemaValue
    let options: CompileOptions
    let coerce: String
    let parse: String
    let convertOnly: String
}

private func coerceSharedSchemas() throws -> [String: SchemaValue] {
    let remote = coerceFixtures.appendingPathComponent("json-schema-test-suite/remotes")
    guard let files = FileManager.default.enumerator(at: remote, includingPropertiesForKeys: nil) else {
        throw CoerceFixtureError.invalid("remote schemas")
    }
    var schemas: [String: SchemaValue] = [:]
    for case let file as URL in files where file.pathExtension == "json" {
        let relative = String(file.path.dropFirst(remote.path.count + 1))
        schemas["http://localhost:1234/\(relative)"] = try .parse(json: Data(contentsOf: file))
    }
    let meta = coerceFixtures.appendingPathComponent("meta-schemas")
    func read(_ name: String) throws -> SchemaValue { try .parse(json: Data(contentsOf: meta.appendingPathComponent(name))) }
    schemas["http://json-schema.org/draft-07/schema"] = try read("draft-07-schema.json")
    schemas["https://json-schema.org/draft/2020-12/schema"] = try read("draft2020-12-schema.json")
    for name in ["core", "applicator", "unevaluated", "validation", "meta-data", "format-annotation", "content"] {
        schemas["https://json-schema.org/draft/2020-12/meta/\(name)"] = try read("draft2020-12-meta-\(name).json")
    }
    return schemas
}

private func coerceFixtureCases() throws -> [CoerceFixtureCase] {
    let url = coerceFixtures.appendingPathComponent("generated/coerce-v1.5.2.jsonl")
    let bytes = try Data(contentsOf: url)
    guard bytes.count <= 2_000_000 else { throw CoerceFixtureError.invalid("coerce fixture exceeds 2 MB") }
    let lines = String(decoding: bytes, as: UTF8.self).split(separator: "\n")
    guard let first = lines.first, case let .object(header) = try SchemaValue.parse(json: String(first)),
          header["tag"] == .string("v1.5.2"),
          header["commit"] == .string("b4afdddf44e059c67ccf5097e5317d913521b470"),
          header["generator"] == .string("Scripts/schema-fixtures/generate-coerce-fixtures.mjs"),
          let extraCount = header["extraCases"]?.numberValue, extraCount >= 400 else {
        throw CoerceFixtureError.invalid("coerce provenance")
    }
    let sharedSchemas = try coerceSharedSchemas()
    var files: [String: [SchemaValue]] = [:]
    var cases: [CoerceFixtureCase] = []
    var suiteCount = 0
    var newExtraCount = 0
    for line in lines.dropFirst() {
        guard case let .object(row) = try SchemaValue.parse(json: String(line)),
              let coerce = row["coerce"]?.stringValue, let parse = row["parse"]?.stringValue,
              let convertOnly = row["convertOnly"]?.stringValue else {
            throw CoerceFixtureError.invalid("coerce row")
        }
        let id: String
        let schema: SchemaValue
        let data: SchemaValue
        var options = CompileOptions(schemas: sharedSchemas)
        if let file = row["file"]?.stringValue {
            if files[file] == nil {
                let url = coerceFixtures.appendingPathComponent("json-schema-test-suite/tests/\(file).json")
                guard case let .array(groups) = try SchemaValue.parse(json: Data(contentsOf: url)) else {
                    throw CoerceFixtureError.invalid(file)
                }
                files[file] = groups
            }
            guard let groups = files[file], let g = row["group"]?.numberValue.map(Int.init),
                  let t = row["test"]?.numberValue.map(Int.init), groups.indices.contains(g),
                  case let .object(group) = groups[g], let sourceSchema = group["schema"],
                  case let .array(tests)? = group["tests"], tests.indices.contains(t),
                  case let .object(test) = tests[t], let sourceData = test["data"] else {
                throw CoerceFixtureError.invalid(file)
            }
            id = "\(file)/\(g)/\(t)"
            schema = sourceSchema
            data = sourceData
            options.draft = file.hasPrefix("draft7/") ? .draft7 : .draft2020_12
            options.formats = file.contains("/optional/format/") ? standardFormats : nil
            suiteCount += 1
        } else {
            guard let sourceID = row["id"]?.stringValue, let sourceSchema = row["schema"], let sourceData = row["data"] else {
                throw CoerceFixtureError.invalid("extra coerce row")
            }
            id = sourceID
            schema = sourceSchema
            data = sourceData
            let fields = row["options"]?.objectValue
            options.draft = (fields?["draft"] ?? row["draft"]) == .string("7") ? .draft7 : .draft2020_12
            options.unresolvedRefs = (fields?["unresolvedRefs"] ?? row["unresolvedRefs"]) == .string("reject") ? .reject : .throw
            if let supplied = fields?["schemas"]?.objectValue {
                for (key, value) in supplied { options.schemas[key] = value }
            }
            if id.hasPrefix("coerce-extra/") { newExtraCount += 1 }
        }
        cases.append(CoerceFixtureCase(id: id, schema: schema, data: data, options: options,
                                       coerce: coerce, parse: parse, convertOnly: convertOnly))
    }
    guard Double(suiteCount) == header["suiteCases"]?.numberValue,
          Double(newExtraCount) == extraCount,
          cases.count == Int((header["suiteCases"]?.numberValue ?? 0) + (header["checkExtraCases"]?.numberValue ?? 0) +
                             (header["errorExtraCases"]?.numberValue ?? 0) + extraCount) else {
        throw CoerceFixtureError.invalid("coerce case counts")
    }
    return cases
}

private func parseResultText(_ result: SchemaParseResult) -> String {
    switch result {
    case let .ok(value):
        return SchemaValue.object(["ok": .bool(true), "value": value]).stringify()
    case let .failed(issues):
        let errors = issues.map { SchemaValue.object(["path": .string($0.path), "keyword": .string($0.keyword), "message": .string($0.message)]) }
        return SchemaValue.object(["ok": .bool(false), "errors": .array(errors)]).stringify()
    }
}

@Test(arguments: try coerceFixtureCases())
private func taggedCoerceDifferential(item: CoerceFixtureCase) throws {
    let input = item.data
    let before = input.stringify()
    let validator = try compileCoercing(item.schema, options: item.options)
    #expect(validator.coerce(input).stringify() == item.coerce, "coerce: \(item.id)")
    #expect(parseResultText(validator.parse(input)) == item.parse, "parse: \(item.id)")
    let plain = try compile(item.schema, options: item.options)
    let conversion = Coercer(c: plain.compiler, schema: item.schema)
    #expect(conversion.convertOnly(input).stringify() == item.convertOnly, "convertOnly: \(item.id)")
    #expect(input.stringify() == before, "input changed: \(item.id)")
}

private struct TypeBoxFixtureCase: Sendable, CustomTestStringConvertible {
    var testDescription: String { id }
    let id: String
    let operation: String
    let schema: SchemaValue
    let data: SchemaValue
    let expected: String
}

private func typeBoxFixtureCases() throws -> [TypeBoxFixtureCase] {
    let url = coerceFixtures.appendingPathComponent("generated/coerce-typebox-v1.5.2.jsonl")
    let bytes = try Data(contentsOf: url)
    guard bytes.count <= 600_000 else { throw CoerceFixtureError.invalid("TypeBox fixture exceeds 600 KB") }
    let lines = String(decoding: bytes, as: UTF8.self).split(separator: "\n")
    guard let first = lines.first, case let .object(header) = try SchemaValue.parse(json: String(first)),
          header["tag"] == .string("v1.5.2"), header["typebox"] == .string("1.3.27"),
          header["commit"] == .string("b4afdddf44e059c67ccf5097e5317d913521b470"),
          header["generator"] == .string("Scripts/schema-fixtures/generate-typebox-coerce-fixtures.mjs"),
          header["cases"]?.numberValue == Double(lines.count - 1),
          let skips = header["skippedNonJSON"]?.numberValue, skips > 0 else {
        throw CoerceFixtureError.invalid("TypeBox provenance")
    }
    return try lines.dropFirst().map { line in
        guard case let .object(row) = try SchemaValue.parse(json: String(line)),
              let id = row["id"]?.stringValue, let operation = row["operation"]?.stringValue,
              let schema = row["schema"], let data = row["data"], let expected = row["expected"]?.stringValue,
              ["convertOnly", "check"].contains(operation) else { throw CoerceFixtureError.invalid("TypeBox row") }
        return TypeBoxFixtureCase(id: id, operation: operation, schema: schema, data: data, expected: expected)
    }
}

@Test(arguments: try typeBoxFixtureCases())
private func taggedTypeBoxConvertDifferential(item: TypeBoxFixtureCase) throws {
    let validator = try compile(item.schema, options: .init(formats: standardFormats))
    if item.operation == "check" {
        #expect(String(validator.check(item.data)) == item.expected, "\(item.id)")
    } else {
        let coercer = Coercer(c: validator.compiler, schema: item.schema)
        #expect(coercer.convertOnly(item.data).stringify() == item.expected, "\(item.id)")
    }
}

@Test("ECMAScript Number(string) and String(number) match Node 22")
private func taggedJSValueDifferential() throws {
    let url = coerceFixtures.appendingPathComponent("generated/js-values-v1.5.2.json")
    guard case let .object(root) = try SchemaValue.parse(json: Data(contentsOf: url)),
          root["tag"] == .string("v1.5.2"), root["nodeMajor"] == .number(22),
          root["commit"] == .string("b4afdddf44e059c67ccf5097e5317d913521b470"),
          root["generator"] == .string("Scripts/schema-fixtures/generate-js-value-fixtures.mjs"),
          case let .array(numbers)? = root["number"], case let .array(strings)? = root["string"],
          case let .array(bigints)? = root["bigint"], case let .array(trims)? = root["trim"],
          case let .array(numerics)? = root["numeric"], case let .array(strict)? = root["strict"],
          numbers.count >= 200, strings.count >= 200, bigints.count >= 200,
          trims.count >= 200, numerics.count >= 200, strict.count >= 100 else { throw CoerceFixtureError.invalid("JS values") }
    for vector in numbers {
        guard case let .object(row) = vector, let input = row["input"]?.stringValue else {
            throw CoerceFixtureError.invalid("Number vector")
        }
        let result = jsNumber(input)
        if row["nan"] == .bool(true) {
            #expect(result.isNaN, "Number(\(String(reflecting: input)))")
        } else {
            guard let hex = row["bits"]?.stringValue, let expected = UInt64(hex, radix: 16) else {
                throw CoerceFixtureError.invalid("Number bits")
            }
            #expect(result.bitPattern == expected, "Number(\(String(reflecting: input)))")
        }
    }
    for vector in strings {
        guard case let .object(row) = vector, let hex = row["bits"]?.stringValue,
              let bits = UInt64(hex, radix: 16), let expected = row["expected"]?.stringValue else {
            throw CoerceFixtureError.invalid("String vector")
        }
        #expect(jsString(.number(Double(bitPattern: bits))) == expected, "String(number bits: \(hex))")
    }
    for vector in bigints {
        guard case let .object(row) = vector, let input = row["input"]?.stringValue else {
            throw CoerceFixtureError.invalid("BigInt vector")
        }
        #expect(jsBigInt(input) == row["expected"]?.stringValue, "BigInt(\(String(reflecting: input)))")
    }
    for vector in trims {
        guard case let .object(row) = vector, let input = row["input"]?.stringValue,
              let expected = row["expected"]?.stringValue else { throw CoerceFixtureError.invalid("trim vector") }
        #expect(jsTrim(input) == expected, "trim(\(String(reflecting: input)))")
    }
    for vector in numerics {
        guard case let .object(row) = vector, let hex = row["bits"]?.stringValue,
              let bits = UInt64(hex, radix: 16), let truncHex = row["trunc"]?.stringValue,
              let truncBits = UInt64(truncHex, radix: 16), case let .bool(integer)? = row["integer"],
              case let .bool(safe)? = row["safeInteger"] else { throw CoerceFixtureError.invalid("numeric vector") }
        let value = Double(bitPattern: bits)
        #expect(jsTrunc(value).bitPattern == truncBits, "Math.trunc bits: \(hex)")
        #expect(jsIsInteger(value) == integer, "Number.isInteger bits: \(hex)")
        #expect(jsIsSafeInteger(value) == safe, "Number.isSafeInteger bits: \(hex)")
    }
    for vector in strict {
        guard case let .object(row) = vector, let a = row["a"], let b = row["b"],
              case let .bool(expected)? = row["expected"] else { throw CoerceFixtureError.invalid("strict vector") }
        #expect(jsStrictEqual(a, b) == expected, "strict equality")
    }
}
