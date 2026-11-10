// Ported from packages/schema/src/explain.ts, pi-mono v1.5.2.
import Foundation

private struct RefMemoKey: Hashable {
    let target: String
    let path: String
}

private struct ExplainState {
    var memo: [RefMemoKey: [SchemaIssue]] = [:]
}

/// Explains failures of one compiled schema.
struct Explainer: Sendable {
    let c: Compiler
    let schema: SchemaValue

    // explain.ts:38
    func errors(_ value: SchemaValue) -> [SchemaIssue] {
        var out: [SchemaIssue] = []
        var state = ExplainState()
        do {
            try walk(schema, c.r.rootBase, value, "", &out, &state)
        } catch {
            return [SchemaIssue(path: "", keyword: "schema", message: "invalid")]
        }
        if out.isEmpty { out.append(SchemaIssue(path: "", keyword: "schema", message: "invalid")) }
        return out
    }

    // explain.ts:50
    private func ok(_ node: SchemaValue, _ base: String, _ value: SchemaValue) throws -> Bool {
        try c.check(node, base: base)(value)
    }

    // explain.ts:55
    private func walk(_ node: SchemaValue, _ base: String, _ value: SchemaValue, _ path: String,
                      _ out: inout [SchemaIssue], _ state: inout ExplainState) throws {
        if node == .bool(true) { return }
        if node == .bool(false) {
            out.append(SchemaIssue(path: path, keyword: "false", message: "no value is allowed here"))
            return
        }
        guard case .object(let object) = node else { return }
        let b = c.r.baseFor(object, base)
        if try ok(node, b, value) { return }
        let start = out.count
        if c.draft == .draft7, let ref = object["$ref"]?.stringValue {
            try walkRef(ref, b, value, path, &out, &state)
            return
        }
        if let declared = object["type"] {
            let types = declared.arrayValue ?? [declared]
            if !types.contains(where: { type in
                guard let name = type.stringValue, let check = TYPE_CHECKS[name] else { return false }
                return check(value)
            }) {
                out.append(SchemaIssue(path: path, keyword: "type",
                                       message: "expected \(types.map(jsString).joined(separator: " or ")), got \(typeName(value))"))
                return
            }
        }
        if let allowed = object["enum"]?.arrayValue, !enumCheck(allowed)(value) {
            out.append(SchemaIssue(path: path, keyword: "enum", message: "expected one of \(listValues(allowed))"))
        }
        if let constant = object["const"], !constCheck(constant)(value) {
            out.append(SchemaIssue(path: path, keyword: "const", message: "expected \(constant.stringify())"))
        }
        if case .string(let string) = value, object["type"] != .string("bytes") {
            try walkString(object, string, path, &out)
        }
        // SchemaValue has no Uint8Array representation. Keep walkBytes for source parity.
        if case .number(let number) = value { walkNumber(object, number, path, &out) }
        if case .object(let objectValue) = value { try walkObject(object, b, objectValue, path, &out, &state) }
        if case .array(let arrayValue) = value { try walkArray(object, b, arrayValue, path, &out, &state) }
        if let branches = object["allOf"]?.arrayValue {
            for branch in branches { try walk(branch, b, value, path, &out, &state) }
        }
        if let branches = object["anyOf"]?.arrayValue {
            try walkUnion(branches, b, value, path, &out, false, &state)
        }
        if let branches = object["oneOf"]?.arrayValue {
            try walkUnion(branches, b, value, path, &out, true, &state)
        }
        if let not = object["not"], try ok(not, b, value) {
            out.append(SchemaIssue(path: path, keyword: "not", message: "must not match the schema in not"))
        }
        if let condition = object["if"] {
            let branch = try ok(condition, b, value) ? object["then"] : object["else"]
            if let branch { try walk(branch, b, value, path, &out, &state) }
        }
        if let ref = object["$ref"]?.stringValue { try walkRef(ref, b, value, path, &out, &state) }
        if out.count == start, object["unevaluatedProperties"] != nil || object["unevaluatedItems"] != nil {
            try walkUnevaluated(object, b, value, path, &out, &state)
        }
        if out.count == start, object["$dynamicRef"]?.stringValue != nil {
            out.append(SchemaIssue(path: path, keyword: "$dynamicRef", message: "does not match the dynamically referenced schema"))
        }
    }

    // explain.ts:106
    private func walkRef(_ ref: String, _ base: String, _ value: SchemaValue, _ path: String,
                         _ out: inout [SchemaIssue], _ state: inout ExplainState) throws {
        let target = try c.resolve(ref, base: base)
        if target.node == .bool(false), c.r.isUnresolved(ref, base: base) {
            out.append(SchemaIssue(path: path, keyword: "$ref", message: "unresolved reference \(ref)"))
            return
        }
        guard case .object = target.node, value.objectValue != nil || value.arrayValue != nil else {
            try walk(target.node, target.base, value, path, &out, &state)
            return
        }
        // Target URI plus input path is a stable per-call equivalent of the JS object pair.
        let key = RefMemoKey(target: schemaResolveURI(ref, base), path: path)
        if let known = state.memo[key] { out.append(contentsOf: known); return }
        var errors: [SchemaIssue] = []
        try walk(target.node, target.base, value, path, &errors, &state)
        state.memo[key] = errors
        out.append(contentsOf: errors)
    }

    // explain.ts:133
    private func walkString(_ node: SchemaObject, _ value: String, _ path: String,
                            _ out: inout [SchemaIssue]) throws {
        let n = codePoints(value)
        if let min = node["minLength"]?.numberValue, Double(n) < min {
            out.append(SchemaIssue(path: path, keyword: "minLength", message: "expected at least \(jsNumber(min)) characters"))
        }
        if let max = node["maxLength"]?.numberValue, Double(n) > max {
            out.append(SchemaIssue(path: path, keyword: "maxLength", message: "expected at most \(jsNumber(max)) characters"))
        }
        if let pattern = node["pattern"]?.stringValue, !schemaRegexMatches(pattern, value) {
            out.append(SchemaIssue(path: path, keyword: "pattern", message: "expected to match \(pattern)"))
        }
        if let name = node["format"]?.stringValue, let format = c.formats?[name], !format(value) {
            out.append(SchemaIssue(path: path, keyword: "format", message: "expected format \(name)"))
        }
    }

    // explain.ts:152
    // Unreachable: SchemaValue is JSON-only and cannot hold Uint8Array.
    private func walkBytes(_ node: SchemaObject, _ length: Int, _ path: String, _ out: inout [SchemaIssue]) {
        if let min = node["minLength"]?.numberValue, Double(length) < min {
            out.append(SchemaIssue(path: path, keyword: "minLength", message: "expected at least \(jsNumber(min)) bytes"))
        }
        if let max = node["maxLength"]?.numberValue, Double(length) > max {
            out.append(SchemaIssue(path: path, keyword: "maxLength", message: "expected at most \(jsNumber(max)) bytes"))
        }
    }

    // explain.ts:162
    private func walkNumber(_ node: SchemaObject, _ value: Bound, _ path: String, _ out: inout [SchemaIssue]) {
        if let min = node["minimum"].flatMap(isBound), value < min {
            out.append(SchemaIssue(path: path, keyword: "minimum", message: "expected >= \(jsNumber(min))"))
        }
        if let max = node["maximum"].flatMap(isBound), value > max {
            out.append(SchemaIssue(path: path, keyword: "maximum", message: "expected <= \(jsNumber(max))"))
        }
        if let min = node["exclusiveMinimum"].flatMap(isBound), value <= min {
            out.append(SchemaIssue(path: path, keyword: "exclusiveMinimum", message: "expected > \(jsNumber(min))"))
        }
        if let max = node["exclusiveMaximum"].flatMap(isBound), value >= max {
            out.append(SchemaIssue(path: path, keyword: "exclusiveMaximum", message: "expected < \(jsNumber(max))"))
        }
        if let divisor = node["multipleOf"].flatMap(isBound), !isMultiple(value, divisor) {
            out.append(SchemaIssue(path: path, keyword: "multipleOf", message: "expected a multiple of \(jsNumber(divisor))"))
        }
    }

    // explain.ts:173
    private func walkObject(_ node: SchemaObject, _ base: String, _ value: SchemaObject, _ path: String,
                            _ out: inout [SchemaIssue], _ state: inout ExplainState) throws {
        let properties = node["properties"]?.objectValue ?? SchemaObject()
        let required = node["required"]?.arrayValue ?? []
        for key in required {
            guard let name = key.stringValue else { continue }
            if value[name] == nil { out.append(SchemaIssue(path: pointer(path, name), keyword: "required", message: "missing")) }
        }
        for (key, schema) in properties {
            if let child = value[key] { try walk(schema, base, child, pointer(path, key), &out, &state) }
        }
        let patterns = node["patternProperties"]?.objectValue ?? SchemaObject()
        for (key, child) in value {
            var matched = properties[key] != nil
            for (pattern, schema) in patterns where schemaRegexMatches(pattern, key) {
                matched = true
                try walk(schema, base, child, pointer(path, key), &out, &state)
            }
            if !matched, let extra = node["additionalProperties"] {
                if extra == .bool(false) {
                    out.append(SchemaIssue(path: pointer(path, key), keyword: "additionalProperties", message: "unknown field"))
                } else { try walk(extra, base, child, pointer(path, key), &out, &state) }
            }
            if let names = node["propertyNames"], try !ok(names, base, .string(key)) {
                out.append(SchemaIssue(path: pointer(path, key), keyword: "propertyNames", message: "invalid property name"))
            }
        }
        if let min = node["minProperties"]?.numberValue, Double(value.count) < min {
            out.append(SchemaIssue(path: path, keyword: "minProperties", message: "expected at least \(jsNumber(min)) properties"))
        }
        if let max = node["maxProperties"]?.numberValue, Double(value.count) > max {
            out.append(SchemaIssue(path: path, keyword: "maxProperties", message: "expected at most \(jsNumber(max)) properties"))
        }
        var dependencies = c.draft == .draft7 ? SchemaObject() : (node["dependentRequired"]?.objectValue ?? SchemaObject())
        if let legacy = node["dependencies"]?.objectValue {
            for (key, schema) in legacy { dependencies[key] = schema }
        }
        for (key, dependency) in dependencies where value[key] != nil {
            if let names = dependency.arrayValue {
                for name in names where value[jsPropertyKey(name)] == nil {
                    out.append(SchemaIssue(path: pointer(path, jsPropertyKey(name)), keyword: "dependentRequired",
                                           message: "required when \(key) is present"))
                }
            } else { try walk(dependency, base, .object(value), path, &out, &state) }
        }
        if c.draft != .draft7, let schemas = node["dependentSchemas"]?.objectValue {
            for (key, schema) in schemas where value[key] != nil {
                try walk(schema, base, .object(value), path, &out, &state)
            }
        }
    }

    // explain.ts:233
    private func walkArray(_ node: SchemaObject, _ base: String, _ value: [SchemaValue], _ path: String,
                           _ out: inout [SchemaIssue], _ state: inout ExplainState) throws {
        let prefix: [SchemaValue]
        let rest: SchemaValue?
        if let items = node["items"]?.arrayValue {
            prefix = items; rest = node["additionalItems"]
        } else {
            prefix = c.draft == .draft7 ? [] : (node["prefixItems"]?.arrayValue ?? [])
            rest = node["items"]
        }
        for index in value.indices {
            let schema = index < prefix.count ? prefix[index] : rest
            if let schema { try walk(schema, base, value[index], "\(path)/\(index)", &out, &state) }
        }
        if let min = node["minItems"]?.numberValue, Double(value.count) < min {
            out.append(SchemaIssue(path: path, keyword: "minItems", message: "expected at least \(jsNumber(min)) items"))
        }
        if let max = node["maxItems"]?.numberValue, Double(value.count) > max {
            out.append(SchemaIssue(path: path, keyword: "maxItems", message: "expected at most \(jsNumber(max)) items"))
        }
        if node["uniqueItems"] == .bool(true), !uniqueCheck(.array(value)) {
            out.append(SchemaIssue(path: path, keyword: "uniqueItems", message: "expected unique items"))
        }
        if let contains = node["contains"] {
            let min = c.draft == .draft7 ? 1 : (node["minContains"]?.numberValue ?? 1)
            let max = c.draft == .draft7 ? Double.infinity : (node["maxContains"]?.numberValue ?? .infinity)
            if !containsCheck(try c.check(contains, base: base), min, max)(.array(value)) {
                out.append(SchemaIssue(path: path, keyword: "contains", message: containsMessage(min, max)))
            }
        }
    }

    // explain.ts:271
    private func walkUnion(_ branches: [SchemaValue], _ base: String, _ value: SchemaValue, _ path: String,
                           _ out: inout [SchemaIssue], _ exactlyOne: Bool, _ state: inout ExplainState) throws {
        var matches = 0
        for branch in branches where try ok(branch, base, value) { matches += 1 }
        if matches == 1 || (!exactlyOne && matches > 0) { return }
        let keyword = exactlyOne ? "oneOf" : "anyOf"
        if matches > 1 {
            out.append(SchemaIssue(path: path, keyword: keyword, message: "matches more than one alternative"))
            return
        }
        if let tag = try tagOf(branches, base), let object = value.objectValue {
            guard let index = tag.values.firstIndex(of: object[tag.key] ?? .null), object[tag.key] != nil else {
                out.append(SchemaIssue(path: pointer(path, tag.key), keyword: keyword,
                                       message: "expected one of \(listValues(tag.values))"))
                return
            }
            try walk(branches[index], base, value, path, &out, &state)
            return
        }
        var best: (errors: [SchemaIssue], declared: Int)?
        for branch in branches {
            var errors: [SchemaIssue] = []
            try walk(branch, base, value, path, &errors, &state)
            if errors.isEmpty { continue }
            let declared = try value.objectValue.map { try declaredKeys(branch, base, $0) } ?? 0
            if best == nil || declared > (best?.declared ?? -1) ||
                (declared == best?.declared && errors[0].path.utf16.count > (best?.errors.first?.path.utf16.count ?? -1)) {
                best = (errors, declared)
            }
        }
        out.append(contentsOf: best?.errors ?? [SchemaIssue(path: path, keyword: keyword, message: "matches no alternative")])
    }

    // explain.ts:317
    private func declaredKeys(_ branch: SchemaValue, _ base: String, _ value: SchemaObject) throws -> Int {
        let node: SchemaValue
        if case .object(let object) = branch, let ref = object["$ref"]?.stringValue {
            node = try c.resolve(ref, base: c.r.baseFor(object, base)).node
        } else { node = branch }
        let properties = node.objectValue?["properties"]?.objectValue ?? SchemaObject()
        return value.keys.filter { properties[$0] != nil }.count
    }

    // explain.ts:324
    private func tagOf(_ branches: [SchemaValue], _ base: String) throws -> (key: String, values: [SchemaValue])? {
        var resolved: [SchemaValue] = []
        for branch in branches {
            if case .object(let object) = branch, let ref = object["$ref"]?.stringValue {
                resolved.append(try c.resolve(ref, base: c.r.baseFor(object, base)).node)
            } else { resolved.append(branch) }
        }
        guard let first = resolved.first?.objectValue?["properties"]?.objectValue else { return nil }
        for (key, _) in first {
            let values = resolved.map { node -> SchemaValue? in
                node.objectValue?["properties"]?.objectValue?[key]?.objectValue?["const"]
            }
            guard values.allSatisfy({ value in
                guard let value else { return false }
                switch value { case .null, .bool, .number, .string: return true; default: return false }
            }) else { continue }
            let actual = values.compactMap { $0 }
            if Set(actual.map { $0.stringify() }).count == actual.count { return (key, actual) }
        }
        return nil
    }

    // explain.ts:341
    private func walkUnevaluated(_ node: SchemaObject, _ base: String, _ value: SchemaValue, _ path: String,
                                 _ out: inout [SchemaIssue], _ state: inout ExplainState) throws {
        var rest = node
        rest["unevaluatedProperties"] = nil
        rest["unevaluatedItems"] = nil
        rest["$id"] = nil
        var annotations = newAnnotations()
        _ = try c.annotating(.object(rest), base: base)(value, &annotations)
        if let object = value.objectValue, let schema = node["unevaluatedProperties"], !annotations.allProps {
            for (key, child) in object {
                if annotations.props?.contains(Array(key.utf16)) == true { continue }
                if schema == .bool(false) {
                    out.append(SchemaIssue(path: pointer(path, key), keyword: "unevaluatedProperties", message: "unknown field"))
                } else { try walk(schema, base, child, pointer(path, key), &out, &state) }
            }
        }
        if let array = value.arrayValue, let schema = node["unevaluatedItems"],
           !annotations.allItems, annotations.items < array.count {
            for index in annotations.items..<array.count {
                if annotations.indexes?.contains(index) == true { continue }
                if schema == .bool(false) {
                    out.append(SchemaIssue(path: "\(path)/\(index)", keyword: "unevaluatedItems", message: "unexpected item"))
                } else { try walk(schema, base, array[index], "\(path)/\(index)", &out, &state) }
            }
        }
    }
}

// explain.ts:371
private func listValues(_ values: [SchemaValue]) -> String {
    if values.count <= 20 { return SchemaValue.array(values).stringify() }
    let listed = SchemaValue.array(Array(values.prefix(20))).stringify()
    return String(listed.dropLast()) + ", ... and \(values.count - 20) more]"
}

// explain.ts:377
private func containsMessage(_ min: Double, _ max: Double) -> String {
    if max == .infinity { return "expected at least \(jsNumber(min)) matching \(min == 1 ? "item" : "items")" }
    if min == 0 { return "expected at most \(jsNumber(max)) matching \(max == 1 ? "item" : "items")" }
    return "expected between \(jsNumber(min)) and \(jsNumber(max)) matching items"
}

// explain.ts:383
private func isBound(_ value: SchemaValue) -> Bound? { value.numberValue }

// explain.ts:387
private func pointer(_ path: String, _ key: String) -> String {
    path + "/" + key.replacingOccurrences(of: "~", with: "~0").replacingOccurrences(of: "/", with: "~1")
}

// explain.ts:391
private func typeName(_ value: SchemaValue) -> String {
    switch value {
    case .null: "null"
    case .array: "array"
    case .object: "object"
    case .string: "string"
    case .bool: "boolean"
    case .number(let number):
        if number.isNaN { "NaN" }
        else if number == .infinity { "Infinity" }
        else if number == -.infinity { "-Infinity" }
        else if number.rounded(.towardZero) == number { "integer" }
        else { "number" }
    }
}

private func jsNumber(_ value: Double) -> String {
    if value.isNaN { return "NaN" }
    if value == .infinity { return "Infinity" }
    if value == -.infinity { return "-Infinity" }
    return SchemaValue.number(value).stringify()
}
private func jsString(_ value: SchemaValue) -> String {
    switch value {
    case .string(let string): string
    case .null: ""
    case .array(let array): array.map(jsString).joined(separator: ",")
    case .object: "[object Object]"
    case .bool(let flag): flag ? "true" : "false"
    case .number(let number): jsNumber(number)
    }
}

private func jsPropertyKey(_ value: SchemaValue) -> String {
    if value == .null { return "null" }
    return jsString(value)
}
