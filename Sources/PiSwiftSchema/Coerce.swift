// Ported from packages/schema/src/coerce.ts, pi-mono v1.5.2.
import Foundation

/// Coercion rules for one compiled schema. Conversion state belongs to each call.
final class Coercer: Sendable {
    let c: Compiler
    let schema: SchemaValue
    init(c: Compiler, schema: SchemaValue) { self.c = c; self.schema = schema }

    // coerce.ts:51
    func coerce(_ value: SchemaValue) -> SchemaValue {
        let depth = schemaNestingDepth(value, stoppingAt: schemaMaximumValueDepth)
        if depth > schemaMaximumValueDepth { return value }
        if max(depth, schemaNestingDepth(schema, stoppingAt: schemaMaximumSchemaDepth)) > schemaLargeStackThreshold {
            return schemaOnLargeStack { self.coerceUnchecked(value) } ?? value
        }
        return coerceUnchecked(value)
    }

    func coerceUnchecked(_ value: SchemaValue) -> SchemaValue {
        var run = Conversion(c: c, schema: schema)
        let result = run.coerce(value)
        return schemaNestingDepth(result, stoppingAt: schemaMaximumValueDepth) > schemaMaximumValueDepth ? value : result
    }

    // coerce.ts:58
    func convertOnly(_ value: SchemaValue) -> SchemaValue {
        let depth = schemaNestingDepth(value, stoppingAt: schemaMaximumValueDepth)
        if depth > schemaMaximumValueDepth { return value }
        if max(depth, schemaNestingDepth(schema, stoppingAt: schemaMaximumSchemaDepth)) > schemaLargeStackThreshold {
            return schemaOnLargeStack { self.convertOnlyUnchecked(value) } ?? value
        }
        return convertOnlyUnchecked(value)
    }

    private func convertOnlyUnchecked(_ value: SchemaValue) -> SchemaValue {
        var run = Conversion(c: c, schema: schema)
        let result = run.convertOnly(value)
        return schemaNestingDepth(result, stoppingAt: schemaMaximumValueDepth) > schemaMaximumValueDepth ? value : result
    }
}

// The source class holds these mutable fields. Swift keeps them inside a single invocation.
private struct Conversion {
    let c: Compiler
    let schema: SchemaValue
    var entered: [Entry] = []
    var cuts = 0
    var memo: [Entry: SchemaValue] = [:]
    var path: [String] = []

    struct Entry: Hashable {
        let node: String
        let value: String
    }

    private func entry(_ node: SchemaValue, _ base: String, _ value: SchemaValue) -> Entry {
        let valueKey: String
        switch value {
        case .object, .array: valueKey = "path:" + path.joined(separator: "/") + ":" + value.stringify()
        default: valueKey = "primitive:" + value.stringify()
        }
        return Entry(node: base + "|" + node.stringify(), value: valueKey)
    }

    private mutating func at<T>(_ component: String, _ body: (inout Conversion) -> T) -> T {
        path.append(component)
        defer { path.removeLast() }
        return body(&self)
    }

    // coerce.ts:51
    mutating func coerce(_ value: SchemaValue) -> SchemaValue {
        let base = c.r.rootBase
        let withoutNulls = dropOptionalNulls(value, schema, base)
        return coerceTypes(convertOnly(withoutNulls), schema, base)
    }

    // coerce.ts:58
    mutating func convertOnly(_ value: SchemaValue) -> SchemaValue {
        defer { memo.removeAll(); cuts = 0 }
        return convert(schema, c.r.rootBase, value)
    }

    // coerce.ts:68
    private mutating func reenter(_ node: SchemaValue, _ base: String, _ value: SchemaValue, _ memoize: Bool) -> SchemaValue {
        let key = entry(node, base, value)
        if entered.contains(key) { cuts += 1; return value }
        if memoize, let result = memo[key] { return result }
        let before = cuts
        entered.append(key)
        let result = convert(node, base, value)
        entered.removeLast()
        if memoize && cuts == before { memo[key] = result }
        return result
    }

    // coerce.ts:99
    private func passes(_ node: SchemaValue, _ base: String, _ value: SchemaValue) -> Bool? {
        guard let check = try? c.check(node, base: baseOf(node, base)) else { return nil }
        return check(value)
    }

    // coerce.ts:107
    private func baseOf(_ node: SchemaValue, _ base: String) -> String {
        guard case .object(let object) = node else { return base }
        return c.r.baseFor(object, base)
    }

    // coerce.ts:115
    private mutating func dropOptionalNulls(_ value: SchemaValue, _ schema: SchemaValue, _ base: String) -> SchemaValue {
        guard case .object(let node) = schema else { return value }
        let b = baseOf(schema, base)
        if case .array(let items) = value {
            return .array(mapItems(items) { item, i in
                guard let sub = itemSchemaAt(node, i) else { return item }
                return at(String(i)) { $0.dropOptionalNulls(item, sub, b) }
            })
        }
        guard case .object(let object) = value else { return value }
        let properties = node["properties"]?.objectValue ?? SchemaObject()
        let patterns = node["patternProperties"]?.objectValue ?? SchemaObject()
        let additional = node["additionalProperties"]?.objectValue.map(SchemaValue.object)
        if patterns.isEmpty && additional == nil && node["properties"]?.objectValue == nil { return value }
        let required = Set(node["required"]?.arrayValue?.compactMap(\.stringValue) ?? [])
        var out: SchemaObject? = nil
        func set(_ key: String, _ next: SchemaValue) {
            if next == (out ?? object)[key] { return }
            if out == nil { out = object }
            out?[key] = next
        }
        for (key, property) in properties {
            guard let current = object[key] else { continue }
            let isRef = property.objectValue?["$ref"]?.stringValue != nil
            if current == .null && !required.contains(key) && !isRef && passes(property, b, .null) == false {
                if out == nil { out = object }
                out?[key] = nil
                continue
            }
            let next = at(key) { $0.dropOptionalNulls(current, property, b) }
            set(key, next)
        }
        if !patterns.isEmpty || additional != nil {
            for (key, original) in object {
                var matched = properties[key] != nil
                for (pattern, sub) in patterns where schemaRegexMatches(pattern, key) {
                    matched = true
                    let current = (out ?? object)[key] ?? original
                    let next = at(key) { $0.dropOptionalNulls(current, sub, b) }
                    set(key, next)
                }
                if !matched, let additional {
                    let next = at(key) { $0.dropOptionalNulls(original, additional, b) }
                    set(key, next)
                }
            }
        }
        return .object(out ?? object)
    }

    // coerce.ts:168
    private mutating func convert(_ node: SchemaValue, _ base: String, _ value: SchemaValue) -> SchemaValue {
        guard case .object(let object) = node else { return value }
        let b = baseOf(node, base)
        if let ref = object["$ref"]?.stringValue {
            guard let target = try? c.resolve(ref, base: b), case .object = target.node else { return value }
            return reenter(target.node, target.base, value, true)
        }
        return convertNode(object, b, value)
    }

    // coerce.ts:184
    private mutating func convertNode(_ node: SchemaObject, _ base: String, _ value: SchemaValue) -> SchemaValue {
        if let literal = node["const"] { return convertLiteral(literal, value) }
        if let values = node["enum"]?.arrayValue { return convertEnum(node, values, base, value) }
        if let branches = node["anyOf"]?.arrayValue { return convertUnion(node, branches, base, value) }
        if let branches = node["oneOf"]?.arrayValue { return convertUnion(node, branches, base, value) }
        if let branches = node["allOf"]?.arrayValue {
            var next = value
            for branch in branches { next = convert(branch, base, next) }
            return convertMembers(node, base, next)
        }
        switch node["type"]?.stringValue {
        case "string": return orValue(tryString(value), value)
        case "number": return orValue(tryNumber(value), value)
        case "integer":
            guard case .number(let n) = tryNumber(value) else { return value }
            return .number(jsTrunc(n))
        case "boolean": return orValue(tryBoolean(value), value)
        case "null": return orValue(tryNull(value), value)
        case "bigint": return orValue(tryBigInt(value), value)
        case "undefined": return orValue(tryUndefined(value), value)
        case "array": return convertArray(node, base, value)
        case "object": return convertObject(node, base, value)
        case nil:
            // An array-valued `type` reaches JavaScript's default case, not `case undefined`.
            if node["type"] != nil { return value }
            if node["properties"] != nil || node["patternProperties"] != nil { return convertObject(node, base, value) }
            if node["items"] != nil || node["prefixItems"] != nil { return convertArray(node, base, value) }
            return value
        default: return value
        }
    }

    // coerce.ts:229
    private mutating func convertEnum(_ node: SchemaObject, _ values: [SchemaValue], _ base: String, _ value: SchemaValue) -> SchemaValue {
        if values.contains(where: { jsStrictEqual($0, value) }) { return value }
        for member in values {
            let candidate = convertLiteral(member, value)
            if !jsStrictEqual(candidate, value) && passes(.object(node), base, candidate) == true { return candidate }
        }
        return value
    }

    // coerce.ts:244
    private mutating func convertUnion(_ node: SchemaObject, _ branches: [SchemaValue], _ base: String, _ value: SchemaValue) -> SchemaValue {
        if branches.contains(where: { passes($0, base, value) == true }) { return convertMembers(node, base, value) }
        for branch in branches {
            let candidate = convertMembers(node, base, convert(branch, base, value))
            if passes(.object(node), base, candidate) == true { return candidate }
        }
        return convertMembers(node, base, value)
    }

    // coerce.ts:255
    private mutating func convertMembers(_ node: SchemaObject, _ base: String, _ value: SchemaValue) -> SchemaValue {
        let declares = node["properties"] != nil || node["patternProperties"] != nil || node["additionalProperties"] != nil
        return declares ? convertObject(node, base, value) : value
    }

    // coerce.ts:263
    private mutating func convertArray(_ node: SchemaObject, _ base: String, _ value: SchemaValue) -> SchemaValue {
        let prefix = node["items"]?.arrayValue ?? node["prefixItems"]?.arrayValue
        if let prefix {
            guard case .array(let items) = value else { return value }
            let rest = node["items"]?.arrayValue == nil ? node["items"] : nil
            return .array(mapItems(items) { item, i in
                let sub = i < prefix.count ? prefix[i] : rest
                guard let sub else { return item }
                return at(String(i)) { $0.convert(sub, base, item) }
            })
        }
        if case .array(let items) = value {
            guard let sub = node["items"] else { return value }
            return .array(mapItems(items) { item, i in at(String(i)) { $0.convert(sub, base, item) } })
        }
        let item = node["items"]
        let converted: SchemaValue
        if let item, case .object = item { converted = reenter(item, base, value, false) }
        else { converted = value }
        return .array([converted])
    }

    // coerce.ts:286
    private mutating func convertObject(_ node: SchemaObject, _ base: String, _ value: SchemaValue) -> SchemaValue {
        guard case .object(let object) = value else { return value }
        let properties = node["properties"]?.objectValue ?? SchemaObject()
        let patterns = node["patternProperties"]?.objectValue ?? SchemaObject()
        let additional = node["additionalProperties"]?.objectValue.map(SchemaValue.object)
        var out: SchemaObject? = nil
        for (key, current) in object {
            var next = current
            var matched = properties[key] != nil
            if let sub = properties[key] { next = at(key) { $0.convert(sub, base, next) } }
            for (pattern, sub) in patterns where schemaRegexMatches(pattern, key) {
                matched = true
                next = at(key) { $0.convert(sub, base, next) }
            }
            if !matched, let additional { next = at(key) { $0.convert(additional, base, next) } }
            if !jsStrictEqual(next, current) {
                if out == nil { out = object }
                out?[key] = next
            }
        }
        return .object(out ?? object)
    }

    // coerce.ts:318
    private mutating func coerceTypes(_ value: SchemaValue, _ schema: SchemaValue, _ base: String) -> SchemaValue {
        guard case .object(let node) = schema else { return value }
        let b = baseOf(schema, base)
        var next = value
        if let members = node["allOf"]?.arrayValue { for member in members { next = coerceTypes(next, member, b) } }
        if let branches = node["anyOf"]?.arrayValue { next = coerceUnion(next, branches, b) }
        if let branches = node["oneOf"]?.arrayValue { next = coerceUnion(next, branches, b) }
        let types = typesOf(node)
        let matchesUnionMember = types.count > 1 && types.contains(where: { matchesType(next, $0) })
        if !types.isEmpty && !matchesUnionMember {
            for type in types {
                let candidate = coercePrimitive(next, type)
                if !jsStrictEqual(candidate, next) { next = candidate; break }
            }
        }
        if types.contains("object"), case .object(let object) = next { next = .object(coerceProperties(object, node, b)) }
        if types.contains("array"), case .array(let items) = next { next = .array(coerceItems(items, node, b)) }
        return next
    }

    // coerce.ts:341
    private mutating func coerceUnion(_ value: SchemaValue, _ branches: [SchemaValue], _ base: String) -> SchemaValue {
        for branch in branches where passes(branch, base, value) == true { return value }
        for branch in branches {
            let coerced = coerceTypes(value, branch, base)
            if passes(branch, base, coerced) == true { return coerced }
        }
        return value
    }

    // coerce.ts:350
    private mutating func coerceProperties(_ value: SchemaObject, _ schema: SchemaObject, _ base: String) -> SchemaObject {
        let properties = schema["properties"]?.objectValue ?? SchemaObject()
        let patterns = schema["patternProperties"]?.objectValue ?? SchemaObject()
        let additional = schema["additionalProperties"]?.objectValue.map(SchemaValue.object)
        var out: SchemaObject? = nil
        func set(_ key: String, _ next: SchemaValue) {
            if next == (out ?? value)[key] { return }
            if out == nil { out = value }
            out?[key] = next
        }
        for (key, sub) in properties {
            if let current = value[key] { set(key, at(key) { $0.coerceTypes(current, sub, base) }) }
        }
        for (key, current) in value {
            var matched = properties[key] != nil
            for (pattern, sub) in patterns where schemaRegexMatches(pattern, key) {
                matched = true
                let prior = (out ?? value)[key] ?? current
                set(key, at(key) { $0.coerceTypes(prior, sub, base) })
            }
            if !matched, let additional { set(key, at(key) { $0.coerceTypes(current, additional, base) }) }
        }
        return out ?? value
    }

    // coerce.ts:381
    private mutating func coerceItems(_ value: [SchemaValue], _ schema: SchemaObject, _ base: String) -> [SchemaValue] {
        mapItems(value) { item, i in
            guard let sub = itemSchemaAt(schema, i), case .object = sub else { return item }
            return at(String(i)) { $0.coerceTypes(item, sub, base) }
        }
    }
}

// coerce.ts:393
private func itemSchemaAt(_ schema: SchemaObject, _ index: Int) -> SchemaValue? {
    if let items = schema["items"]?.arrayValue { return index < items.count ? items[index] : nil }
    if let prefix = schema["prefixItems"]?.arrayValue, index < prefix.count { return prefix[index] }
    return schema["items"]
}

// coerce.ts:400
private func mapItems(_ items: [SchemaValue], _ map: (SchemaValue, Int) -> SchemaValue) -> [SchemaValue] {
    var out: [SchemaValue]? = nil
    for (index, item) in items.enumerated() {
        let next = map(item, index)
        if jsStrictEqual(next, item) { continue }
        if out == nil { out = items }
        out?[index] = next
    }
    return out ?? items
}

// coerce.ts:417
private func orValue(_ result: SchemaValue?, _ value: SchemaValue) -> SchemaValue { result ?? value }

// coerce.ts:422
private func convertLiteral(_ literal: SchemaValue, _ value: SchemaValue) -> SchemaValue {
    if jsStrictEqual(literal, value) { return value }
    let result: SchemaValue?
    switch literal {
    case .string: result = tryString(value)
    case .number: result = tryNumber(value)
    case .bool: result = tryBoolean(value)
    default: result = nil
    }
    if let result, jsStrictEqual(result, literal) { return result }
    return value
}

// coerce.ts:437
private func tryString(_ value: SchemaValue) -> SchemaValue? {
    switch value {
    case .bool: return jsString(value).map(SchemaValue.string)
    case .number where isFiniteNumber(value): return jsString(value).map(SchemaValue.string)
    case .null: return .string("null")
    case .string: return value
    default: return nil
    }
}

// coerce.ts:449
private func tryNumber(_ value: SchemaValue) -> SchemaValue? {
    switch value {
    case .bool(let b): return .number(b ? 1 : 0)
    case .number(let n): return n.isFinite ? value : nil
    case .null: return .number(0)
    case .string(let text):
        let n = jsNumber(text)
        if n.isFinite { return .number(n) }
        let lower = text.lowercased()
        if lower == "false" { return .number(0) }
        if lower == "true" { return .number(1) }
        if let big = bigIntOfString(text), jsBigIntIsSafe(big) { return .number(jsNumber(big)) }
        return nil
    default: return nil
    }
}

// coerce.ts:466
private func bigIntOfString(_ value: String) -> String? {
    let pattern = #"^-?(?:0|[1-9][0-9]*)(?:n|\.[0-9]+)?$"#
    guard value.range(of: pattern, options: .regularExpression) != nil else { return nil }
    let digits = value.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)[0]
    let whole = digits.hasSuffix("n") ? String(digits.dropLast()) : String(digits)
    return jsBigInt(whole)
}

// coerce.ts:474
private func tryBigInt(_ value: SchemaValue) -> SchemaValue? {
    // Upstream returns a JavaScript bigint; SchemaValue has no bigint case.
    nil
}

// coerce.ts:487
private func tryUndefined(_ value: SchemaValue) -> SchemaValue? {
    // Upstream returns undefined for null, false, zero and the documented strings; no JSON value represents it.
    nil
}

// coerce.ts:497
private func tryBoolean(_ value: SchemaValue) -> SchemaValue? {
    switch value {
    case .bool: return value
    case .number(let n): return n == 0 ? .bool(false) : n == 1 ? .bool(true) : nil
    case .null: return .bool(false)
    case .string(let text):
        let lower = text.lowercased()
        if lower == "false" || text == "0" { return .bool(false) }
        if lower == "true" || text == "1" { return .bool(true) }
        return nil
    default: return nil
    }
}

// coerce.ts:509
private func tryNull(_ value: SchemaValue) -> SchemaValue? {
    switch value {
    case .null: return .null
    case .bool(false): return .null
    case .number(let n) where n == 0: return .null
    case .string(let text):
        let lower = text.lowercased()
        return lower == "undefined" || lower == "null" || text == "" || text == "0" ? .null : nil
    default: return nil
    }
}

// coerce.ts:521
private func isFiniteNumber(_ value: SchemaValue) -> Bool {
    if case .number(let n) = value { return n.isFinite }
    return false
}

// coerce.ts:529
private func typesOf(_ schema: SchemaObject) -> [String] {
    if let type = schema["type"]?.stringValue { return [type] }
    return schema["type"]?.arrayValue?.compactMap(\.stringValue) ?? []
}

// coerce.ts:535
private func matchesType(_ value: SchemaValue, _ type: String) -> Bool {
    switch type {
    case "number": return isFiniteNumber(value)
    case "integer": if case .number(let n) = value { return jsIsInteger(n) }; return false
    case "boolean": if case .bool = value { return true }; return false
    case "string": if case .string = value { return true }; return false
    case "null": return value == .null
    case "array": if case .array = value { return true }; return false
    case "object": return isPlainObject(value)
    default: return false
    }
}

// coerce.ts:560
private func coercePrimitive(_ value: SchemaValue, _ type: String) -> SchemaValue {
    switch type {
    case "number", "integer":
        if value == .null { return .number(0) }
        if case .string(let text) = value, !jsTrim(text).isEmpty {
            let parsed = jsNumber(text)
            if type == "number" ? parsed.isFinite : jsIsInteger(parsed) { return .number(parsed) }
        }
        if case .bool(let b) = value { return .number(b ? 1 : 0) }
        return value
    case "boolean":
        if value == .null { return .bool(false) }
        if value == .string("true") || value == .number(1) { return .bool(true) }
        if value == .string("false") || value == .number(0) { return .bool(false) }
        return value
    case "string":
        if value == .null { return .string("") }
        return jsString(value).map(SchemaValue.string) ?? value
    case "null":
        if value == .string("") || value == .number(0) || value == .bool(false) { return .null }
        return value
    default: return value
    }
}

// coerce.ts:588
private func isPlainObject(_ value: SchemaValue) -> Bool {
    if case .object = value { return true }
    return false
}

// JavaScript operations used by coerce.ts. Inputs are checked against Node fixture vectors.
func jsStrictEqual(_ a: SchemaValue, _ b: SchemaValue) -> Bool {
    switch (a, b) {
    case (.array, .array), (.object, .object): return a == b // JSON values have no shared references.
    default: return a == b
    }
}

func jsTrunc(_ n: Double) -> Double { n.rounded(.towardZero) }
func jsIsInteger(_ n: Double) -> Bool { n.isFinite && jsTrunc(n) == n }
func jsIsSafeInteger(_ n: Double) -> Bool { jsIsInteger(n) && abs(n) <= 9_007_199_254_740_991 }

// The decimal text is exact, including integers larger than binary64 can hold.
func jsBigInt(_ text: String) -> String? {
    var source = jsTrim(text)
    if source.isEmpty { return "0" }
    let negative = source.first == "-"
    let signed = source.first == "-" || source.first == "+"
    if source.first == "-" || source.first == "+" { source.removeFirst() }
    if source.isEmpty { return nil }
    var radix = 10
    if source.hasPrefix("0x") || source.hasPrefix("0X") { radix = 16; source.removeFirst(2) }
    else if source.hasPrefix("0b") || source.hasPrefix("0B") { radix = 2; source.removeFirst(2) }
    else if source.hasPrefix("0o") || source.hasPrefix("0O") { radix = 8; source.removeFirst(2) }
    if radix != 10 && signed { return nil }
    guard !source.isEmpty else { return nil }
    var decimal = [Int](arrayLiteral: 0) // least significant digit first
    for byte in source.utf8 {
        let digit = byte >= 48 && byte <= 57 ? Int(byte - 48) :
            byte >= 65 && byte <= 70 ? Int(byte - 65 + 10) :
            byte >= 97 && byte <= 102 ? Int(byte - 97 + 10) : -1
        if digit < 0 || digit >= radix { return nil }
        var carry = digit
        for index in decimal.indices {
            let next = decimal[index] * radix + carry
            decimal[index] = next % 10
            carry = next / 10
        }
        while carry > 0 { decimal.append(carry % 10); carry /= 10 }
    }
    while decimal.count > 1 && decimal.last == 0 { decimal.removeLast() }
    let result = decimal.reversed().map(String.init).joined()
    return negative && result != "0" ? "-" + result : result
}

private func jsBigIntIsSafe(_ text: String) -> Bool {
    let magnitude = text.hasPrefix("-") ? String(text.dropFirst()) : text
    return magnitude.count < 16 || (magnitude.count == 16 && magnitude <= "9007199254740991")
}

func jsTrim(_ text: String) -> String {
    let whitespace: Set<UInt32> = [9, 10, 11, 12, 13, 32, 160, 0x1680, 0x2000, 0x2001, 0x2002, 0x2003, 0x2004,
        0x2005, 0x2006, 0x2007, 0x2008, 0x2009, 0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000, 0xFEFF]
    let scalars = Array(text.unicodeScalars)
    let start = scalars.firstIndex(where: { !whitespace.contains($0.value) }) ?? scalars.count
    let end = scalars.lastIndex(where: { !whitespace.contains($0.value) }).map { $0 + 1 } ?? start
    return String(String.UnicodeScalarView(scalars[start..<end]))
}

func jsNumber(_ text: String) -> Double {
    let source = jsTrim(text)
    if source.isEmpty { return 0 }
    if source == "Infinity" || source == "+Infinity" { return .infinity }
    if source == "-Infinity" { return -.infinity }
    if source.count > 2, source.first == "0" {
        let bytes = Array(source.utf8)
        let radix: UInt8 = bytes[1] == 120 || bytes[1] == 88 ? 16 : bytes[1] == 98 || bytes[1] == 66 ? 2 : bytes[1] == 111 || bytes[1] == 79 ? 8 : 0
        if radix > 0 {
            var number = 0.0
            for byte in bytes.dropFirst(2) {
                let digit: UInt8 = byte >= 48 && byte <= 57 ? byte - 48 : byte >= 65 && byte <= 70 ? byte - 65 + 10 : byte >= 97 && byte <= 102 ? byte - 97 + 10 : 255
                if digit >= radix { return .nan }
                number = number * Double(radix) + Double(digit)
            }
            return bytes.count > 2 ? number : .nan
        }
    }
    let pattern = #"^[+-]?(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)(?:[eE][+-]?[0-9]+)?$"#
    guard source.range(of: pattern, options: .regularExpression) != nil else { return .nan }
    return Double(source) ?? .nan
}

func jsString(_ value: SchemaValue) -> String? {
    switch value {
    case .number(let n):
        if n.isNaN { return "NaN" }
        if n == .infinity { return "Infinity" }
        if n == -.infinity { return "-Infinity" }
        return value.stringify()
    case .bool(let b): return b ? "true" : "false"
    case .string(let s): return s
    case .null: return "null"
    default: return nil
    }
}
