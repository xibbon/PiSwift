// Ported from packages/schema/src/checks.ts, pi-mono v1.5.2.
// Check factories capture their arguments and do not retain the compiler.
import Foundation
import Synchronization

typealias Check = @Sendable (SchemaValue) -> Bool

// checks.ts:7-18
let ALWAYS: Check = { _ in true }
let NEVER: Check = { _ in false }
let IS_STRING: Check = { if case .string = $0 { return true }; return false }
let IS_NUMBER: Check = { if case .number(let n) = $0 { return n.isFinite }; return false }
let IS_INTEGER: Check = { if case .number(let n) = $0 { return n.isFinite && n.rounded(.towardZero) == n }; return false }
let IS_BOOLEAN: Check = { if case .bool = $0 { return true }; return false }
let IS_NULL: Check = { if case .null = $0 { return true }; return false }
let IS_ARRAY: Check = { if case .array = $0 { return true }; return false }
// bytes, bigint, and undefined are valid schema names but no SchemaValue has these types.
let IS_BYTES: Check = { _ in false }
let IS_BIGINT: Check = { _ in false }
let IS_UNDEFINED: Check = { _ in false }
let IS_OBJECT: Check = { isObject($0) }

// checks.ts:21
func isObject(_ value: SchemaValue) -> Bool {
    if case .object = value { return true }
    return false
}

// checks.ts:30
let TYPE_CHECKS: [String: Check] = [
    "string": IS_STRING, "number": IS_NUMBER, "integer": IS_INTEGER,
    "boolean": IS_BOOLEAN, "null": IS_NULL, "array": IS_ARRAY,
    "object": IS_OBJECT, "bytes": IS_BYTES, "bigint": IS_BIGINT,
    "undefined": IS_UNDEFINED,
]

struct Bounds: Sendable {
    let min: Double
    let max: Double
    let xmin: Double
    let xmax: Double
    init(_ min: Double, _ max: Double, _ xmin: Double, _ xmax: Double) {
        self.min = min; self.max = max; self.xmin = xmin; self.xmax = xmax
    }
}

enum LeafArgument: Sendable {
    case none
    case value(SchemaValue)
    case values([SchemaValue])
    case mask(Int)
    case bounds(Bounds)
    case regex(NSRegularExpression)
}

// checks.ts:47
struct Leaf: Sendable {
    let code: Int
    let argument: LeafArgument
    init(_ code: Int, _ argument: LeafArgument = .none) {
        self.code = code; self.argument = argument
    }
}

// checks.ts:59
// Swift closures have no stable weak-key identity. The source schema is a sound
// sidecar for the leaf metadata; only an exact assertion shape gets a leaf.
func leafOf(_ check: Check, schema: SchemaValue) -> Leaf? {
    _ = check
    if case .bool(true) = schema { return Leaf(6) }
    guard case .object(let object) = schema else { return nil }
    let neutral: Set<String> = [
        "$schema", "$comment", "title", "description", "default", "examples",
        "deprecated", "readOnly", "writeOnly", "$defs", "definitions",
        "contentEncoding", "contentMediaType", "minContains", "maxContains", "$vocabulary",
    ]
    let assertions = object.keys.filter { !neutral.contains($0) }
    if assertions.isEmpty { return Leaf(6) }
    if assertions == ["type"], case .string(let name)? = object["type"] {
        switch name {
        case "string": return Leaf(1)
        case "number": return Leaf(2)
        case "integer": return Leaf(3)
        case "boolean": return Leaf(4)
        case "null": return Leaf(5)
        default: return nil
        }
    }
    if assertions == ["const"], let value = object["const"], value.isPrimitive {
        return Leaf(7, .value(value))
    }
    if assertions == ["enum"], case .array(let values)? = object["enum"],
       values.count <= 8, values.allSatisfy(\.isPrimitive) {
        return Leaf(8, .values(values))
    }
    if assertions == ["type"], case .array(let types)? = object["type"] {
        return Leaf(9, .mask(typeMask(types)))
    }
    let numeric = Set(["type", "minimum", "maximum", "exclusiveMinimum", "exclusiveMaximum"])
    if !assertions.isEmpty, Set(assertions).isSubset(of: numeric),
       let name = object["type"]?.stringValue, name == "integer" || name == "number",
       object["minimum"] != nil || object["maximum"] != nil ||
       object["exclusiveMinimum"] != nil || object["exclusiveMaximum"] != nil {
        let b = Bounds(object["minimum"]?.numberValue ?? -.infinity,
                       object["maximum"]?.numberValue ?? .infinity,
                       object["exclusiveMinimum"]?.numberValue ?? -.infinity,
                       object["exclusiveMaximum"]?.numberValue ?? .infinity)
        return Leaf(name == "integer" ? 10 : 11, .bounds(b))
    }
    let lengths = Set(["type", "minLength", "maxLength"])
    if !assertions.isEmpty, Set(assertions).isSubset(of: lengths),
       object["type"]?.stringValue == "string",
       object["minLength"] != nil || object["maxLength"] != nil {
        let b = Bounds(object["minLength"]?.numberValue ?? 0,
                       object["maxLength"]?.numberValue ?? .infinity, 0, 0)
        return Leaf(12, .bounds(b))
    }
    if Set(assertions) == Set(["type", "pattern"]),
       object["type"]?.stringValue == "string",
       let source = object["pattern"]?.stringValue,
       let regex = try? schemaCompileRegex(source) {
        return Leaf(13, .regex(regex))
    }
    return nil
}

extension SchemaValue {
    fileprivate var isPrimitive: Bool {
        switch self {
        case .null, .bool, .number, .string: return true
        case .array, .object: return false
        }
    }
}

// checks.ts:63
// The metadata is carried beside the check, so this factory returns its check.
func leaf(_ code: Int, _ argument: LeafArgument, _ check: @escaping Check) -> Check {
    _ = code; _ = argument
    return check
}

// checks.ts:68
// Bounds is above Leaf so its typed argument can refer to it.

// checks.ts:84
func leafOk(_ leaf: Leaf, _ value: SchemaValue) -> Bool {
    switch leaf.code {
    case 1: return IS_STRING(value)
    case 2: return IS_NUMBER(value)
    case 3: return IS_INTEGER(value)
    case 4: return IS_BOOLEAN(value)
    case 5: return IS_NULL(value)
    case 6: return true
    case 7:
        if case .value(let target) = leaf.argument { return value == target }
        return false
    case 8:
        if case .values(let list) = leaf.argument { return list.contains(value) }
        return false
    case 9:
        if case .mask(let mask) = leaf.argument { return typeBits(value) & mask != 0 }
        return false
    case 10, 11:
        guard case .bounds(let bounds) = leaf.argument else { return false }
        return (leaf.code == 10 ? IS_INTEGER(value) : IS_NUMBER(value)) &&
            value.numberValue.map { inBounds($0, bounds) } == true
    case 12:
        guard case .bounds(let bounds) = leaf.argument,
              case .string(let text) = value else { return false }
        return lengthOk(text, bounds.min, bounds.max)
    case 13:
        guard case .regex(let regex) = leaf.argument,
              case .string(let text) = value else { return false }
        return regexTest(regex, text)
    default: return true
    }
}

// checks.ts:118
func inBounds(_ value: Double, _ bounds: Bounds) -> Bool {
    value >= bounds.min && value <= bounds.max &&
    value > bounds.xmin && value < bounds.xmax
}

// checks.ts:123-131
enum Guard: Sendable { case none, strict, loose }
let GUARD_NONE = Guard.none
let GUARD_STRICT = Guard.strict
let GUARD_LOOSE = Guard.loose
let CODE = 15
let REQUIRED = 16
let INHERITED = 32

// checks.ts:134
func and(_ parts: [Check]) -> Check {
    switch parts.count {
    case 0: return ALWAYS
    case 1: return parts[0]
    case 2:
        let a = parts[0], b = parts[1]
        return { a($0) && b($0) }
    case 3:
        let a = parts[0], b = parts[1], c = parts[2]
        return { a($0) && b($0) && c($0) }
    default:
        return { value in
            for part in parts where !part(value) { return false }
            return true
        }
    }
}

// A set-once slot is needed only for recursive references.
final class CheckSlot: Sendable {
    private final class Box: Sendable {
        let check: Check
        init(_ check: @escaping Check) { self.check = check }
    }
    private let stored = Mutex<Box?>(nil)
    func install(_ check: @escaping Check) { stored.withLock { $0 = Box(check) } }
    func run(_ value: SchemaValue) -> Bool {
        guard let box = stored.withLock({ $0 }) else { return false }
        return box.check(value)
    }
}

// checks.ts:157
func indirect(_ slot: CheckSlot) -> Check { { slot.run($0) } }

// checks.ts:162
// Only the restarted dynamic validator calls this; Validator serializes its checks.
func scopedCheck(_ scope: DynamicScope, _ uri: String, _ check: @escaping Check) -> Check {
    return { value in
        scope.push(uri)
        defer { scope.pop() }
        return check(value)
    }
}

// checks.ts:172
func typeCheck(_ types: [SchemaValue]) -> Check {
    if types.count == 1 {
        guard case .string(let name) = types[0] else { return NEVER }
        return TYPE_CHECKS[name] ?? NEVER
    }
    return maskCheck(typeMask(types))
}

// checks.ts:177
let TYPE_BITS: [String: Int] = [
    "string": 1, "number": 2, "integer": 4, "boolean": 8, "null": 16,
    "array": 32, "object": 64, "bytes": 128, "bigint": 256, "undefined": 512,
]

// checks.ts:191
func typeMask(_ types: [SchemaValue]) -> Int {
    var mask = 0
    for type in types {
        if case .string(let name) = type { mask |= TYPE_BITS[name] ?? 0 }
    }
    return mask
}

// checks.ts:198
// SchemaValue has no JavaScript bytes, bigint, or undefined value cases.
func typeBits(_ value: SchemaValue) -> Int {
    switch value {
    case .string: return 1
    case .number(let n):
        if n.isFinite && n.rounded(.towardZero) == n { return 6 }
        return n.isFinite ? 2 : 0
    case .bool: return 8
    case .null: return 16
    case .array: return 32
    case .object: return 64
    }
}

// checks.ts:217
func maskCheck(_ mask: Int) -> Check {
    leaf(9, .mask(mask), { typeBits($0) & mask != 0 })
}

// checks.ts:222
func maskedAnyCheck(_ mask: Int, _ checks: [Check]) -> Check {
    if checks.isEmpty { return maskCheck(mask) }
    let rest = checks.count == 1 ? checks[0] : anyCheck(checks)
    return { value in typeBits(value) & mask != 0 || rest(value) }
}

// checks.ts:229
func bytesCheck(_ min: Double, _ max: Double) -> Check {
    _ = min; _ = max
    return NEVER
}

// checks.ts:234
// Swift strings contain Unicode scalars, never lone UTF-16 surrogates.
func codePoints(_ text: String) -> Int { text.unicodeScalars.count }

// checks.ts:248
func lengthOk(_ text: String, _ min: Double, _ max: Double) -> Bool {
    let units = Double(text.utf16.count)
    if units < min { return false }
    if units < 2 * min && Double(codePoints(text)) < min { return false }
    return units <= max || Double(codePoints(text)) <= max
}

func regexTest(_ regex: NSRegularExpression, _ text: String) -> Bool {
    regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
}

// checks.ts:256
func stringCheck(_ strict: Bool, _ min: Double, _ max: Double,
                 _ regex: NSRegularExpression?, _ format: FormatCheck?) -> Check {
    if let regex, min == 0, max == .infinity, format == nil {
        if strict {
            let check: Check = { value in
                guard case .string(let text) = value else { return false }
                return regexTest(regex, text)
            }
            return leaf(13, .regex(regex), check)
        }
        return { value in
            guard case .string(let text) = value else { return true }
            return regexTest(regex, text)
        }
    }
    if regex == nil && format == nil {
        if strict {
            let check: Check = { value in
                guard case .string(let text) = value else { return false }
                return lengthOk(text, min, max)
            }
            return leaf(12, .bounds(Bounds(min, max, 0, 0)), check)
        }
        return { value in
            guard case .string(let text) = value else { return true }
            return lengthOk(text, min, max)
        }
    }
    return { value in
        guard case .string(let text) = value else { return !strict }
        return lengthOk(text, min, max) &&
            (regex.map { regexTest($0, text) } ?? true) &&
            (format.map { $0(text) } ?? true)
    }
}

// checks.ts:280
// JSON schemas carry Double bounds. JavaScript bigint bounds have no SchemaValue.
typealias Bound = Double

// checks.ts:286
// Bound is Double because JSON schemas cannot hold JavaScript bigint bounds.
func numberCheck(_ mode: Int, _ min: Bound, _ max: Bound,
                 _ xmin: Bound, _ xmax: Bound, _ multipleOf: Bound?) -> Check {
    let check: Check = { value in
        guard case .number(let number) = value else { return mode == 0 }
        if mode == 3 { return false }
        if mode != 0 && !number.isFinite { return false }
        if mode == 2 && !(number.isFinite && number.rounded(.towardZero) == number) { return false }
        return number >= min && number <= max && number > xmin && number < xmax &&
            (multipleOf.map { isMultiple(number, $0) } ?? true)
    }
    if mode == 0 || mode == 3 || multipleOf != nil { return check }
    return leaf(mode == 2 ? 10 : 11, .bounds(Bounds(min, max, xmin, xmax)), check)
}

// checks.ts:313
// Decimal digit arrays replace upstream BigInt mantissas for exact modulus.
func isMultiple(_ value: Bound, _ divisor: Bound) -> Bool {
    let quotient = value / divisor
    if quotient.isFinite && quotient.rounded(.towardZero) == quotient { return true }
    if !quotient.isFinite { return value.truncatingRemainder(dividingBy: divisor) == 0 }
    guard let (numerator, numeratorExponent) = decimal(value),
          let (denominator, denominatorExponent) = decimal(divisor) else { return false }
    var dividend = numerator
    var divisorDigits = denominator
    let difference = numeratorExponent - denominatorExponent
    if difference >= 0 { dividend.append(contentsOf: repeatElement(0, count: difference)) }
    else { divisorDigits.append(contentsOf: repeatElement(0, count: -difference)) }
    return decimalRemainderIsZero(dividend, divisorDigits)
}

// checks.ts:328
// BigInt mantissas are adapted to decimal digit arrays, with the same modulus.
func decimal(_ number: Double) -> ([Int], Int)? {
    guard number.isFinite else { return nil }
    let components = String(abs(number)).lowercased().split(separator: "e")
    guard let first = components.first else { return nil }
    let mantissa = String(first)
    let exponent = components.count > 1 ? (Int(components[1]) ?? 0) : 0
    let fraction = mantissa.split(separator: ".", omittingEmptySubsequences: false).dropFirst().first?.count ?? 0
    let digits = mantissa.utf8.compactMap { byte -> Int? in
        byte >= 48 && byte <= 57 ? Int(byte - 48) : nil
    }
    return (digits, exponent - fraction)
}

private func decimalRemainderIsZero(_ dividend: [Int], _ divisor: [Int]) -> Bool {
    func normalized(_ digits: [Int]) -> [Int] {
        let rest = digits.drop(while: { $0 == 0 })
        return rest.isEmpty ? [0] : Array(rest)
    }
    let divisor = normalized(divisor)
    guard divisor != [0] else { return false }
    var remainder = [0]
    for digit in dividend {
        remainder = normalized(remainder + [digit])
        while remainder.count > divisor.count ||
              (remainder.count == divisor.count && !remainder.lexicographicallyPrecedes(divisor)) {
            var difference = remainder
            var borrow = 0
            for offset in 0..<difference.count {
                let index = difference.count - 1 - offset
                let other = divisor.count - 1 - offset
                var next = difference[index] - borrow - (other >= 0 ? divisor[other] : 0)
                if next < 0 { next += 10; borrow = 1 } else { borrow = 0 }
                difference[index] = next
            }
            remainder = normalized(difference)
        }
    }
    return remainder == [0]
}

// checks.ts:336
func guardObject(_ inner: @escaping Check, _ strict: Bool) -> Check {
    if strict { return { value in isObject(value) && inner(value) } }
    return { value in !isObject(value) || inner(value) }
}

// checks.ts:341
func guardArray(_ inner: @escaping Check, _ strict: Bool) -> Check {
    if strict { return { value in IS_ARRAY(value) && inner(value) } }
    return { value in !IS_ARRAY(value) || inner(value) }
}

// checks.ts:350
// SchemaObject has only own JSON members, so inherited/undefined cases cannot occur.
struct PropertyEntry: Sendable {
    let key: String
    let check: Check
    let leaf: Leaf?
    let flags: Int
    init(key: String, check: @escaping Check, leaf: Leaf?, flags: Int) {
        self.key = key; self.check = check; self.leaf = leaf; self.flags = flags
    }
}

func declaredObject(_ entries: [PropertyEntry], _ requiredCount: Int,
                    _ closed: Bool, _ guardMode: Guard) -> Check {
    let count = entries.count
    return { value in
        guard case .object(let object) = value else { return guardMode != .strict }
        var required = 0
        var next = 0
        for (key, item) in object {
            var index = next
            if index >= count || !entries[index].key.utf16.elementsEqual(key.utf16) {
                index = 0
                while index < count && !entries[index].key.utf16.elementsEqual(key.utf16) { index += 1 }
                if index == count {
                    if closed { return false }
                    continue
                }
            }
            next = index + 1
            let entry = entries[index]
            if let leaf = entry.leaf {
                if !leafOk(leaf, item) { return false }
            } else if !entry.check(item) { return false }
            if entry.flags & REQUIRED != 0 { required += 1 }
        }
        return required == requiredCount
    }
}

// checks.ts:389
// The loop sees only SchemaObject's own members, in JavaScript property order.
func openObject(_ entries: [PropertyEntry], _ keys: [String], _ extraRequired: [String],
                _ patterns: [(NSRegularExpression, Check)], _ additional: Check?,
                _ guardMode: Guard) -> Check {
    let known: Set<[UInt16]>? =
        !patterns.isEmpty || additional != nil ? Set(keys.map { Array($0.utf16) }) : nil
    return { value in
        guard case .object(let object) = value else { return guardMode != .strict }
        for entry in entries {
            guard let item = object[entry.key] else {
                if entry.flags & REQUIRED != 0 { return false }
                continue
            }
            if let leaf = entry.leaf {
                if !leafOk(leaf, item) { return false }
            } else if !entry.check(item) { return false }
        }
        for key in extraRequired where object[key] == nil { return false }
        guard let known else { return true }
        for (key, item) in object {
            var matched = known.contains(Array(key.utf16))
            for (regex, check) in patterns where regexTest(regex, key) {
                matched = true
                if !check(item) { return false }
            }
            if !matched, let additional, !additional(item) { return false }
        }
        return true
    }
}

// checks.ts:430
func propertyNamesCheck(_ check: @escaping Check) -> Check {
    { value in
        guard case .object(let object) = value else { return true }
        for key in object.keys where !check(.string(key)) { return false }
        return true
    }
}

// checks.ts:438
func propertyCountCheck(_ min: Double, _ max: Double) -> Check {
    { value in
        guard case .object(let object) = value else { return true }
        let count = Double(object.count)
        return count >= min && count <= max
    }
}

// checks.ts:447
func dependentRequiredCheck(_ entries: [(String, [SchemaValue])]) -> Check {
    { value in
        guard case .object(let object) = value else { return true }
        for (key, list) in entries where object[key] != nil {
            for required in list where object[jsPropertyKey(required)] == nil { return false }
        }
        return true
    }
}

private func jsPropertyKey(_ value: SchemaValue) -> String {
    switch value {
    case .string(let text): return text
    case .null: return "null"
    case .bool(let flag): return flag ? "true" : "false"
    case .number(let number):
        if number.isNaN { return "NaN" }
        if number == .infinity { return "Infinity" }
        if number == -.infinity { return "-Infinity" }
        return value.stringify()
    case .array(let items):
        return items.map { item in
            if case .null = item { return "" }
            return jsPropertyKey(item)
        }.joined(separator: ",")
    case .object: return "[object Object]"
    }
}

// checks.ts:457
func dependentSchemasCheck(_ entries: [(String, Check)]) -> Check {
    { value in
        guard case .object(let object) = value else { return true }
        for (key, check) in entries where object[key] != nil {
            if !check(value) { return false }
        }
        return true
    }
}

// checks.ts:464
let NO_LEAF = Leaf(0)

// checks.ts:467
func listCheck(_ guardMode: Guard, _ min: Double, _ max: Double,
               _ prefix: [Check], _ rest: Check?, restLeaf: Leaf? = nil) -> Check {
    let count = prefix.count
    let leaf = restLeaf ?? NO_LEAF
    return { value in
        guard case .array(let items) = value else { return guardMode == .loose }
        let length = items.count
        if Double(length) < min || Double(length) > max { return false }
        let limit = Swift.min(length, count)
        for index in 0..<limit where !prefix[index](items[index]) { return false }
        guard let rest else { return true }
        if count >= length { return true }
        if leaf.code != 0 {
            for index in count..<length where !leafOk(leaf, items[index]) { return false }
            return true
        }
        for index in count..<length where !rest(items[index]) { return false }
        return true
    }
}

// checks.ts:493
func itemsCheck(_ prefix: [Check], _ rest: Check?) -> Check {
    listCheck(GUARD_NONE, 0, .infinity, prefix, rest)
}

// checks.ts:498
func lengthCheck(_ min: Double, _ max: Double) -> Check {
    { value in
        guard case .array(let items) = value else { return true }
        let count = Double(items.count)
        return count >= min && count <= max
    }
}

// checks.ts:503
func containsCheck(_ check: @escaping Check, _ min: Double, _ max: Double) -> Check {
    { value in
        guard case .array(let items) = value else { return true }
        var count = 0
        for item in items {
            if check(item) {
                count += 1
                if Double(count) > max { return false }
            }
        }
        return Double(count) >= min
    }
}

// checks.ts:513
func uniqueCheck(_ value: SchemaValue) -> Bool {
    guard case .array(let items) = value else { return true }
    if items.count < 2 { return true }
    for index in 1..<items.count {
        for prior in 0..<index where schemaEqual(items[index], items[prior]) { return false }
    }
    return true
}

private enum PrimitiveKey: Hashable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string([UInt16])
    init?(_ value: SchemaValue) {
        switch value {
        case .null: self = .null
        case .bool(let flag): self = .bool(flag)
        case .number(let number): self = .number(number)
        case .string(let text): self = .string(Array(text.utf16))
        default: return nil
        }
    }
}

// checks.ts:520
// Swift's primitive key set replaces JavaScript Set for the large-enum path.
func enumCheck(_ values: [SchemaValue]) -> Check {
    let primitives = values.filter(\.isPrimitive)
    if primitives.count == values.count && primitives.count <= 8 {
        return leaf(8, .values(primitives), { value in
            for item in primitives where item == value { return true }
            return false
        })
    }
    let primitiveSet = Set(primitives.compactMap(PrimitiveKey.init))
    let objects = values.filter { !$0.isPrimitive }
    return { value in
        if let key = PrimitiveKey(value), primitiveSet.contains(key) { return true }
        if !value.isPrimitive {
            for object in objects where schemaEqual(value, object) { return true }
        }
        return false
    }
}

// checks.ts:534
func constCheck(_ target: SchemaValue) -> Check {
    if target.isPrimitive {
        return leaf(7, .value(target), { $0 == target })
    }
    return { schemaEqual($0, target) }
}

// checks.ts:540
func anyCheck(_ checks: [Check]) -> Check {
    { value in
        for check in checks where check(value) { return true }
        return false
    }
}

// checks.ts:548
func oneCheck(_ checks: [Check]) -> Check {
    { value in
        var count = 0
        for check in checks where check(value) {
            count += 1
            if count > 1 { return false }
        }
        return count == 1
    }
}

// checks.ts:557
func notCheck(_ check: @escaping Check) -> Check { { !check($0) } }

// checks.ts:562
func ifCheck(_ condition: @escaping Check, _ then: @escaping Check,
             _ otherwise: @escaping Check) -> Check {
    { value in condition(value) ? then(value) : otherwise(value) }
}

// checks.ts:567
func taggedCheck(_ key: String, _ tags: [SchemaValue], _ checks: [Check]) -> Check {
    { value in
        guard case .object(let object) = value else { return false }
        guard let tag = object[key] else { return false }
        for index in tags.indices where tags[index] == tag {
            return index < checks.count && checks[index](value)
        }
        return false
    }
}

// checks.ts:580
// The accepted public schemaEqual already implements this structural recursion.
func deepEqual(_ lhs: SchemaValue, _ rhs: SchemaValue) -> Bool {
    schemaEqual(lhs, rhs)
}
