import Foundation
import PiSwiftAI
import PiSwiftChord

/// Checks the program channel after hooks. Model output uses a separate contract.
internal func structuredOutputError(_ tool: ToolRegistration, _ result: ToolExecutionResult) throws -> String? {
    guard let schema = tool.structuredOutputSchema else {
        return result.structuredOutput == nil ? nil : "Tool \(tool.name) returned structuredOutput but declares no structuredOutputSchema"
    }
    guard let value = result.structuredOutput else {
        return result.isError == true ? nil : "Tool \(tool.name) returned no structuredOutput"
    }
    guard let error = durableStructuredSchemaError(value, schema: schema) else { return nil }
    let diagnostic = error.hasPrefix("root.") ? String(error.dropFirst(5)) : error
    return "Tool \(tool.name) returned structuredOutput that does not match its schema: \(diagnostic)"
}

/// Validates JSON values without conversion to Foundation numeric types or coercion.
internal func durableStructuredSchemaError(_ value: JSONValue, schema: JSONObject) -> String? {
    StructuredSchema(root: .object(schema)).error(value, schema: .object(schema), path: "root", depth: 0)
}

private struct StructuredSchema {
    let root: JSONValue
    init(root: JSONValue) { self.root = root }
    private init(root: JSONValue, child: @escaping (Request) -> String?) { self.root = root; self.child = child }
    struct Reference: Hashable { let target: [UInt16]; let path: [UInt16] }

    private struct Request {
        let value: JSONValue
        let schema: JSONValue
        let path: String
        let depth: Int
        let references: Set<Reference>
    }
    private enum Outcome {
        case valid
        case invalid(String)
        init(_ error: String?) { if let error { self = .invalid(error) } else { self = .valid } }
        var error: String? { if case .invalid(let message) = self { message } else { nil } }
    }
    private struct Frame {
        let request: Request
        var children: [Outcome] = []
    }
    private var child: ((Request) -> String?)? = nil

    func error(_ value: JSONValue, schema: JSONValue, path: String, depth: Int, references: Set<Reference> = []) -> String? {
        let request = Request(value: value, schema: schema, path: path, depth: depth, references: references)
        if let child { return child(request) }
        var frames = [Frame(request: request)]
        while let frame = frames.last {
            var cursor = 0
            var missing: Request?
            let evaluator = StructuredSchema(root: root, child: { request in
                defer { cursor += 1 }
                if cursor < frame.children.count { return frame.children[cursor].error }
                if missing == nil { missing = request }
                // The caller's provisional result is discarded until this child is evaluated.
                return "validation pending"
            })
            let result = evaluator.evaluate(frame.request)
            if let missing {
                frames.append(Frame(request: missing))
            } else {
                frames.removeLast()
                guard !frames.isEmpty else { return result }
                frames[frames.count - 1].children.append(Outcome(result))
            }
        }
        return nil
    }

    /// Evaluates one frame. Child validation is a lookup into the frame's completed prefix.
    private func evaluate(_ request: Request) -> String? {
        let value = request.value, schema = request.schema, path = request.path, depth = request.depth
        let references = request.references

        func invalid(_ message: String) -> String { "\(path): \(message)" }
        if case .bool(let allowed) = schema { return allowed ? nil : invalid("schema is false") }
        guard let s = schema.objectValue else { return invalid("invalid schema") }
        var active = references
        func check(_ nested: JSONValue, _ candidate: JSONValue? = nil, _ location: String? = nil) -> String? {
            error(candidate ?? value, schema: nested, path: location ?? path, depth: depth + 1, references: active)
        }
        if let ref = s["$ref"]?.stringValue {
            guard active.insert(Reference(target: Array(ref.utf16), path: Array(path.utf16))).inserted else { return invalid("cyclic schema reference without value progress") }
            guard let target = resolve(ref) else { return invalid("unresolved local schema reference") }
            if let failure = check(target) { return failure }
            active = references
        }
        if let branches = s["allOf"]?.arrayValue {
            for branch in branches { if let failure = check(branch) { return failure } }
        }
        if let branches = s["anyOf"]?.arrayValue {
            var first: String?
            var matched = false
            for branch in branches {
                if let failure = check(branch) { if first == nil { first = failure } }
                else { matched = true; break }
            }
            if !matched { return first ?? invalid("must match a schema in anyOf") }
        }
        if let branches = s["oneOf"]?.arrayValue, branches.filter({ check($0) == nil }).count != 1 {
            return invalid("must match exactly one schema")
        }
        if let excluded = s["not"], check(excluded) == nil { return invalid("matches an excluded schema") }
        if let condition = s["if"] {
            let keyword = check(condition) == nil ? "then" : "else"
            if let branch = s[keyword], let failure = check(branch) {
                if failure.hasPrefix("\(path): must have required properties ") { return invalid("must match \"\(keyword)\" schema") }
                return failure
            }
        }
        if let constant = s["const"], !equal(value, constant) { return invalid("must be equal to constant") }
        if let choices = s["enum"]?.arrayValue, !choices.contains(where: { equal(value, $0) }) {
            return invalid("must be equal to one of the allowed values")
        }
        let types = s["type"]?.arrayValue?.compactMap(\.stringValue) ?? (s["type"]?.stringValue).map { [$0] } ?? []
        if !types.isEmpty && !types.contains(where: { matches(value, type: $0) }) { return invalid("must be \(types.joined(separator: " or "))") }
        if let failure = typedError(value, schema: s, path: path, depth: depth, references: active) { return failure }
        return unevaluatedError(value, schema: s, path: path, depth: depth, references: active)
    }

    private func typedError(_ value: JSONValue, schema s: JSONObject, path: String, depth: Int, references: Set<Reference>) -> String? {
        switch value {
        case .number(let number): return numberError(number, schema: s, path: path)
        case .string(let text): return stringError(text, schema: s, path: path)
        case .array(let values): return arrayError(values, schema: s, path: path, depth: depth, references: references)
        case .object(let object): return objectError(object, schema: s, path: path, depth: depth, references: references)
        case .null, .bool: return nil
        }
    }

    private func numberError(_ number: Double, schema s: JSONObject, path: String) -> String? {
        func invalid(_ message: String) -> String { "\(path): \(message)" }

        guard number.isFinite else { return invalid("must be a finite number") }
        if let bound = s["minimum"]?.numberValue, number < bound { return invalid("must be >= \(numberText(bound))") }
        if let bound = s["maximum"]?.numberValue, number > bound { return invalid("must be <= \(numberText(bound))") }
        if let bound = s["exclusiveMinimum"]?.numberValue, number <= bound { return invalid("must be > \(numberText(bound))") }
        if let bound = s["exclusiveMaximum"]?.numberValue, number >= bound { return invalid("must be < \(numberText(bound))") }
        if let divisor = s["multipleOf"]?.numberValue, divisor > 0 {
            let quotient = number / divisor
            if !quotient.isFinite || abs(quotient - quotient.rounded()) > 1e-10 { return invalid("must be multiple of \(numberText(divisor))") }
        }
        return nil
    }

    private func stringError(_ text: String, schema s: JSONObject, path: String) -> String? {
        func invalid(_ message: String) -> String { "\(path): \(message)" }

        let count = text.count
        if let minimum = s["minLength"]?.numberValue, Double(count) < minimum { return invalid("must not have fewer than \(numberText(minimum)) characters") }
        if let maximum = s["maxLength"]?.numberValue, Double(count) > maximum { return invalid("must not have more than \(numberText(maximum)) characters") }
        if let pattern = s["pattern"]?.stringValue {
            guard let matched = match(text, pattern: pattern) else { return invalid("invalid regex pattern") }
            if !matched { return invalid("must match pattern \"\(pattern)\"") }
        }
        if let format = s["format"]?.stringValue {
            let result = JSONSchemaValidator.shared.validate(text, against: ["type": "string", "format": format], coerceTypes: false)
            if !result.isValid { return invalid("must match format \"\(format)\"") }
        }
        return nil
    }

    private func arrayError(_ values: [JSONValue], schema s: JSONObject, path: String, depth: Int, references: Set<Reference>) -> String? {
        func invalid(_ message: String) -> String { "\(path): \(message)" }
        func check(_ nested: JSONValue, _ candidate: JSONValue? = nil, _ location: String? = nil) -> String? {
            error(candidate ?? .null, schema: nested, path: location ?? path, depth: depth + 1, references: references)
        }

        if let minimum = s["minItems"]?.numberValue, Double(values.count) < minimum { return invalid("must not have fewer than \(numberText(minimum)) items") }
        if let maximum = s["maxItems"]?.numberValue, Double(values.count) > maximum { return invalid("must not have more than \(numberText(maximum)) items") }
        if s["uniqueItems"] == true {
            for index in values.indices where values[..<index].contains(where: { equal($0, values[index]) }) {
                return invalid("must not have duplicate items")
            }
        }
        let prefix = s["prefixItems"]?.arrayValue ?? s["items"]?.arrayValue ?? []
        for (index, nested) in prefix.enumerated() where index < values.count {
            if let failure = check(nested, values[index], "\(path).\(index)") { return failure }
        }
        let remainderSchema = s["items"]?.arrayValue == nil ? s["items"] : s["additionalItems"]
        if let nested = remainderSchema {
            for index in values.indices where index >= prefix.count {
                if let failure = check(nested, values[index], "\(path).\(index)") { return failure }
            }
        }
        if let nested = s["contains"] {
            let count = values.filter { check(nested, $0) == nil }.count
            if Double(count) < (s["minContains"]?.numberValue ?? 1) { return invalid("must contain at least \(numberText(s["minContains"]?.numberValue ?? 1)) valid item") }
            if let maximum = s["maxContains"]?.numberValue, Double(count) > maximum { return invalid("must contain at most \(numberText(maximum)) valid items") }
        }
        return nil
    }

    private func objectError(_ object: JSONObject, schema s: JSONObject, path: String, depth: Int, references: Set<Reference>) -> String? {
        func invalid(_ message: String) -> String { "\(path): \(message)" }
        func check(_ nested: JSONValue, _ candidate: JSONValue? = nil, _ location: String? = nil) -> String? {
            error(candidate ?? .null, schema: nested, path: location ?? path, depth: depth + 1, references: references)
        }

        if let minimum = s["minProperties"]?.numberValue, Double(object.count) < minimum { return invalid("object has too few properties") }
        if let maximum = s["maxProperties"]?.numberValue, Double(object.count) > maximum { return invalid("object has too many properties") }
        let missing = (s["required"]?.arrayValue?.compactMap(\.stringValue) ?? []).filter { object[$0] == nil }
        if !missing.isEmpty { return invalid("must have required properties \(missing.joined(separator: ", "))") }
        for (key, required) in s["dependentRequired"]?.objectValue ?? [:] where object[key] != nil {
            let missing = (required.arrayValue?.compactMap(\.stringValue) ?? []).filter { object[$0] == nil }
            if !missing.isEmpty { return invalid("must have properties \(missing.joined(separator: ", ")) when property \(key) is present") }
        }
        for (key, nested) in s["dependentSchemas"]?.objectValue ?? [:] where object[key] != nil {
            if let failure = check(nested, .object(object)) { return failure }
        }
        let properties = s["properties"]?.objectValue ?? [:]
        let patterns = s["patternProperties"]?.objectValue ?? [:]
        for (key, child) in object {
            let location = "\(path).\(key)"
            var covered = false
            if let nested = properties[key] {
                covered = true
                if let failure = check(nested, child, location) { return failure }
            }
            for (pattern, nested) in patterns {
                guard let matched = match(key, pattern: pattern) else { return invalid("invalid property regex pattern") }
                if matched {
                    covered = true
                    if let failure = check(nested, child, location) { return failure }
                }
            }
            if !covered, let nested = s["additionalProperties"], let failure = check(nested, child, location) { return failure }
            if let nested = s["propertyNames"], let failure = check(nested, .string(key), location) { return failure }
        }
        return nil
    }

    private struct Evaluated {
        var properties: Set<[UInt16]> = []
        var items: Set<Int> = []
    }

    private func unevaluatedError(_ value: JSONValue, schema: JSONObject, path: String, depth: Int, references: Set<Reference>) -> String? {
        guard schema["unevaluatedProperties"] != nil || schema["unevaluatedItems"] != nil else { return nil }
        let evaluated = evaluated(value, schema: schema, path: path, depth: depth, references: references)
        if let object = value.objectValue, let nested = schema["unevaluatedProperties"] {
            for (key, child) in object where !evaluated.properties.contains(Array(key.utf16)) {
                if nested == false { return "\(path): must not have unevaluated properties" }
                if let failure = error(child, schema: nested, path: "\(path).\(key)", depth: depth + 1, references: references) { return failure }
            }
        }
        if let values = value.arrayValue, let nested = schema["unevaluatedItems"] {
            for index in values.indices where !evaluated.items.contains(index) {
                if nested == false { return "\(path): must not have unevaluated items" }
                if let failure = error(values[index], schema: nested, path: "\(path).\(index)", depth: depth + 1, references: references) { return failure }
            }
        }
        return nil
    }

    /// Collects annotations for this instance. Child instance annotations stay with their child.
    private func evaluated(_ value: JSONValue, schema: JSONObject, path: String, depth: Int, references: Set<Reference>) -> Evaluated {
        var result = Evaluated(), pending: [JSONObject] = [schema]
        var seenReferences: Set<[UInt16]> = []
        while let current = pending.popLast() {
            if let reference = current["$ref"]?.stringValue, seenReferences.insert(Array(reference.utf16)).inserted,
               let target = resolve(reference)?.objectValue { pending.append(target) }
            for keyword in ["allOf", "anyOf", "oneOf"] {
                for branch in current[keyword]?.arrayValue ?? [] {
                    if error(value, schema: branch, path: path, depth: depth + 1, references: references) == nil,
                       let object = branch.objectValue { pending.append(object) }
                }
            }
            if let condition = current["if"] {
                let passed = error(value, schema: condition, path: path, depth: depth + 1, references: references) == nil
                if passed, let object = condition.objectValue { pending.append(object) }
                if let branch = current[passed ? "then" : "else"]?.objectValue { pending.append(branch) }
            }
            if let object = value.objectValue {
                let properties = current["properties"]?.objectValue ?? [:]
                let patterns = current["patternProperties"]?.objectValue ?? [:]
                for (key, _) in object {
                    if properties[key] != nil || patterns.contains(where: { match(key, pattern: $0.key) == true }) || current["additionalProperties"] != nil {
                        result.properties.insert(Array(key.utf16))
                    }
                }
                for (key, branch) in current["dependentSchemas"]?.objectValue ?? [:] where object[key] != nil {
                    if let object = branch.objectValue { pending.append(object) }
                }
            }
            if let values = value.arrayValue {
                let prefix = current["prefixItems"]?.arrayValue ?? current["items"]?.arrayValue ?? []
                for index in values.indices where index < prefix.count { result.items.insert(index) }
                if current["items"] != nil && current["items"]?.arrayValue == nil || current["items"]?.arrayValue != nil && current["additionalItems"] != nil {
                    result.items.formUnion(values.indices)
                }
                if let contains = current["contains"] {
                    for index in values.indices where error(values[index], schema: contains, path: "\(path).\(index)", depth: depth + 1, references: references) == nil {
                        result.items.insert(index)
                    }
                }
            }
        }
        return result
    }

    private func numberText(_ value: Double) -> String {
        do { return try JSONValue.number(value).jsonText() }
        catch { return String(value) }
    }

    private func matches(_ value: JSONValue, type: String) -> Bool {
        switch (type, value) {
        case ("null", .null), ("boolean", .bool), ("string", .string), ("array", .array), ("object", .object): true
        case ("number", .number(let number)): number.isFinite
        case ("integer", .number(let number)): number.isFinite && number.rounded(.towardZero) == number
        default: false
        }
    }

    private func equal(_ lhs: JSONValue, _ rhs: JSONValue) -> Bool {
        var pending = [(lhs, rhs)]
        while let (left, right) = pending.popLast() {
            switch (left, right) {
            case (.object(let a), .object(let b)):
                guard a.count == b.count else { return false }
                for (key, child) in a {
                    guard let other = b[key] else { return false }
                    pending.append((child, other))
                }
            case (.array(let a), .array(let b)):
                guard a.count == b.count else { return false }
                pending.append(contentsOf: zip(a, b))
            case (.null, .null): break
            case let (.bool(a), .bool(b)): if a != b { return false }
            case let (.number(a), .number(b)): if a != b { return false }
            case let (.string(a), .string(b)): if !a.unicodeScalars.elementsEqual(b.unicodeScalars) { return false }
            default: return false
            }
        }
        return true
    }

    private func match(_ text: String, pattern: String) -> Bool? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        return regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    private func resolve(_ reference: String) -> JSONValue? {
        if reference == "#" { return root }
        guard reference.hasPrefix("#/"), let decoded = String(reference.dropFirst()).removingPercentEncoding else { return nil }
        var current = root
        for part in decoded.dropFirst().split(separator: "/", omittingEmptySubsequences: false) {
            let raw = String(part)
            guard raw.range(of: "~(?![01])", options: .regularExpression) == nil else { return nil }
            let key = raw.replacingOccurrences(of: "~1", with: "/").replacingOccurrences(of: "~0", with: "~")
            if let object = current.objectValue, let next = object[key] { current = next }
            else if let array = current.arrayValue, let index = Int(key), index >= 0, index < array.count, String(index) == key { current = array[index] }
            else { return nil }
        }
        return current
    }
}
