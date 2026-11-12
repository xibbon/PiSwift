// Ported from packages/schema/src/compiler.ts, pi-mono v1.5.2.
import Foundation
import Synchronization

/// The restart signal of compiler.ts:71.
enum CompilerRestart: Error { case restart }

/// Scope exists only after a bookended dynamic reference restarts compilation.
final class DynamicScope: Sendable {
    private let values = Mutex<[String]>([])
    func push(_ uri: String) { values.withLock { $0.append(uri) } }
    func pop() { values.withLock { if !$0.isEmpty { $0.removeLast() } } }
    func snapshot() -> [String] { values.withLock { $0 } }
}

private enum DynamicResult<T: Sendable>: Sendable {
    case missing
    case found(T)
}

/// One compilation of a schema. Its caches are used only while checks are built.
final class Compiler: Sendable {
    let schema: SchemaValue
    let options: CompileOptions
    let draft: SchemaDraft
    let formats: [String: FormatCheck]?
    let dynamic: Bool
    let scope: DynamicScope?
    private let resolver: Mutex<SchemaResolver>
    // S1b and S3 can inspect the resolver state produced by this compile.
    var r: SchemaResolver { resolver.withLock { $0 } }
    // Swift String equality folds canonically equivalent spellings. JavaScript keys do not.
    private struct CacheKey: Hashable, Sendable { let units: [UInt16]; init(_ value: String) { units = Array(value.utf16) } }
    private let cache = Mutex<[CacheKey: Check]>([:])
    private let annotatingCache = Mutex<[CacheKey: AnnotatingCheck]>([:])

    // compiler.ts:86
    init(_ schema: SchemaValue, options: CompileOptions, dynamic: Bool) {
        self.schema = schema
        self.options = options
        self.draft = options.draft
        self.formats = options.formats
        self.dynamic = dynamic
        self.scope = dynamic ? DynamicScope() : nil
        self.resolver = Mutex(SchemaResolver(root: schema, options: options))
    }

    // compiler.ts:95
    func root() throws -> Check { try check(schema, base: defaultSchemaBase) }

    // compiler.ts:100
    func check(_ node: SchemaValue, base: String) throws -> Check {
        if case .bool(true) = node { return ALWAYS }
        if case .bool(false) = node { return NEVER }
        guard case .object(let object) = node else {
            throw SchemaCompileError.malformedSchema("A schema must be an object or a boolean, got \(node.stringify())")
        }
        let key = cacheKey(node, base)
        if let cached = cache.withLock({ $0[key] }) { return cached }
        if let bare = bareType(object) { return bare }
        let slot = CheckSlot()
        cache.withLock { $0[key] = indirect(slot) }
        do {
            let current = resolver.withLock { $0.baseFor(object, base) }
            let compiled = try build(object, base: current)
            slot.install(compiled)
            cache.withLock { $0[key] = compiled }
            return compiled
        } catch {
            _ = cache.withLock { $0.removeValue(forKey: key) }
            throw error
        }
    }

    // compiler.ts:118
    private func build(_ node: SchemaObject, base: String) throws -> Check {
        if draft == .draft7, let reference = node["$ref"]?.stringValue { return try ref(reference, base: base) }
        if draft != .draft7, node["unevaluatedProperties"] != nil || node["unevaluatedItems"] != nil {
            return withFreshAnnotations(try annotating(.object(node), base: base))
        }
        let compiled = try plain(node, base: base)
        if let scope, isResource(node, at: base) { return scopedCheck(scope, base, compiled) }
        return compiled
    }

    // compiler.ts:131
    private func bareType(_ node: SchemaObject) -> Check? {
        var type: SchemaValue?
        for (key, value) in node {
            if key == "type" { type = value }
            else if !neutralKeywords.contains(key) { return nil }
        }
        guard let type else { return ALWAYS }
        guard let name = type.stringValue else { return nil }
        return TYPE_CHECKS[name]
    }

    // compiler.ts:141
    private func plain(_ node: SchemaObject, base: String) throws -> Check {
        var parts: [Check] = []
        let types = node["type"].map { $0.arrayValue ?? [$0] }
        let single = types?.count == 1 ? types?.first?.stringValue : nil
        var typeInGroup = false
        if single == "bytes" {
            parts.append(bytesCheck(node["minLength"]?.numberValue ?? 0, node["maxLength"]?.numberValue ?? .infinity))
            typeInGroup = true
        } else {
            let string = try stringGroup(node, strict: single == "string")
            if let string { parts.append(string) }
            let numeric = single == "number" || single == "integer" || single == "bigint"
            let mode = single == "number" ? 1 : single == "integer" ? 2 : single == "bigint" ? 3 : 0
            let number = numberGroup(node, mode: mode)
            if let number { parts.append(number) }
            let object = try objectGroup(node, base: base, strict: single == "object")
            if let object { parts.append(object) }
            let array = try arrayGroup(node, base: base, strict: single == "array")
            if let array { parts.append(array) }
            typeInGroup = (single == "string" && string != nil) || (numeric && number != nil) ||
                (single == "object" && object != nil) || (single == "array" && array != nil)
        }
        if let types, !typeInGroup { parts.insert(typeCheck(types), at: 0) }
        try inPlace(node, base: base, parts: &parts)
        return and(parts)
    }

    // compiler.ts:172
    private func inPlace(_ node: SchemaObject, base: String, parts: inout [Check]) throws {
        if let values = node["enum"]?.arrayValue { parts.append(enumCheck(values)) }
        if let constant = node["const"] { parts.append(constCheck(constant)) }
        if let list = node["allOf"]?.arrayValue { parts.append(and(try list.map { try check($0, base: base) })) }
        if let list = node["anyOf"]?.arrayValue { parts.append(try union(list, base: base, exactlyOne: false)) }
        if let list = node["oneOf"]?.arrayValue { parts.append(try union(list, base: base, exactlyOne: true)) }
        if let not = node["not"] { parts.append(notCheck(try check(not, base: base))) }
        if let condition = node["if"], node["then"] != nil || node["else"] != nil {
            let yes = try node["then"].map { try check($0, base: base) } ?? ALWAYS
            let no = try node["else"].map { try check($0, base: base) } ?? ALWAYS
            parts.append(ifCheck(try check(condition, base: base), yes, no))
        }
        if let reference = node["$ref"]?.stringValue { parts.append(try ref(reference, base: base)) }
        if draft != .draft7, let reference = node["$dynamicRef"]?.stringValue {
            parts.append(try dynamicRef(reference, base: base))
        }
    }

    // compiler.ts:191
    private func union(_ branches: [SchemaValue], base: String, exactlyOne: Bool) throws -> Check {
        if let optimized = constUnion(branches, exactlyOne: exactlyOne) { return optimized }
        if let optimized = try tagged(branches, base: base) { return optimized }
        let checks = try branches.map { try check($0, base: base) }
        return exactlyOne ? oneCheck(checks) : anyOf(checks, branches: branches)
    }

    // compiler.ts:200
    private func ref(_ reference: String, base: String) throws -> Check {
        let target = try resolve(reference, base: base)
        let compiled = try check(target.node, base: target.base)
        if let scope, target.base != base { return scopedCheck(scope, target.base, compiled) }
        return compiled
    }

    // compiler.ts:206
    private func dynamicRef(_ reference: String, base: String) throws -> Check {
        guard let resolved = try bookended(reference, base: base) else { return try ref(reference, base: base) }
        let fallback = try check(resolved.initial.node, base: resolved.initial.base)
        let lookup = dynamicLookup(name: resolved.name, failure: NEVER) { node, base in try self.check(node, base: base) }
        guard let scope else { return fallback }
        return { value in
            for uri in scope.snapshot() { if let compiled = lookup(uri) { return compiled(value) } }
            return fallback(value)
        }
    }

    // compiler.ts:222
    private func bookended(_ reference: String, base: String) throws -> (initial: (node: SchemaValue, base: String), name: String)? {
        let initial = try resolve(reference, base: base)
        let uri = schemaResolveURI(reference, base)
        let document = schemaDocument(uri)
        let name = uri.count > document.count ? String(uri.dropFirst(document.count + 1)) : ""
        let anchored = initial.node.objectValue?["$dynamicAnchor"]?.stringValue == name
        if name.isEmpty || name.hasPrefix("/") || !anchored { return nil }
        if !dynamic { throw CompilerRestart.restart }
        return (initial, name)
    }

    // compiler.ts:236
    // A runtime compile error cannot leave nonthrowing Validator.check. It becomes NEVER.
    private func dynamicLookup<T: Sendable>(name: String, failure: T, compile: @escaping @Sendable (SchemaValue, String) throws -> T)
        -> @Sendable (String) -> T? {
        let found = Mutex<[String: DynamicResult<T>]>([:])
        return { uri in
            let key = uri + "#" + name
            if let hit = found.withLock({ $0[key] }) {
                switch hit { case .missing: return nil; case .found(let value): return value }
            }
            guard let target = self.dynamicAnchor(key) else {
                found.withLock { $0[key] = .missing }
                return nil
            }
            let value = (try? compile(target.node, target.base)) ?? failure
            found.withLock { $0[key] = .found(value) }
            return value
        }
    }

    // compiler.ts:251
    private func tagged(_ branches: [SchemaValue], base: String) throws -> Check? {
        if branches.count < 2 { return nil }
        var resolved: [SchemaObject] = []
        for branch in branches {
            guard case .object(let object) = branch else { return nil }
            let pureRef = object.count == 1 ? object["$ref"]?.stringValue : nil
            let node = try pureRef.map { try resolve($0, base: resolver.withLock { $0.baseFor(object, base) }).node } ?? branch
            guard case .object(let target) = node else { return nil }
            resolved.append(target)
        }
        guard let first = resolved.first?["properties"]?.objectValue else { return nil }
        for (key, _) in first {
            let tags = resolved.map { tagOf($0, key: key) }
            if tags.contains(where: { $0 == nil }) { continue }
            let values = tags.compactMap { $0 }
            if values.indices.contains(where: { i in values[..<i].contains(where: { schemaEqual($0, values[i]) }) }) { continue }
            return taggedCheck(key, values, try branches.map { try check($0, base: base) })
        }
        return nil
    }

    // compiler.ts:276
    private func stringGroup(_ node: SchemaObject, strict: Bool) throws -> Check? {
        let min = node["minLength"]?.numberValue ?? 0
        let max = node["maxLength"]?.numberValue ?? .infinity
        let regex = try node["pattern"]?.stringValue.map { try schemaCompileRegex($0) }
        let format = node["format"]?.stringValue.flatMap { formats?[$0] }
        if min == 0 && max == .infinity && regex == nil && format == nil { return nil }
        return stringCheck(strict, min, max, regex, format)
    }

    // compiler.ts:288
    private func numberGroup(_ node: SchemaObject, mode: Int) -> Check? {
        let min = bound(node["minimum"])
        let max = bound(node["maximum"])
        let xmin = bound(node["exclusiveMinimum"])
        let xmax = bound(node["exclusiveMaximum"])
        let multipleOf = bound(node["multipleOf"])
        if min == nil && max == nil && xmin == nil && xmax == nil && multipleOf == nil { return nil }
        return numberCheck(mode, min ?? -.infinity, max ?? .infinity, xmin ?? -.infinity, xmax ?? .infinity, multipleOf)
    }

    // compiler.ts:299
    private func objectGroup(_ node: SchemaObject, base: String, strict: Bool) throws -> Check? {
        let onlyCore = objectExtras.allSatisfy { node[$0] == nil }
        let guardMode: Guard = onlyCore ? (strict ? GUARD_STRICT : GUARD_LOOSE) : GUARD_NONE
        let core = try objectCore(node, base: base, guardMode: guardMode)
        if let core, onlyCore { return core }
        var parts: [Check] = core.map { [$0] } ?? []
        if let names = node["propertyNames"] { parts.append(propertyNamesCheck(try check(names, base: base))) }
        let minProperties = number(node["minProperties"])
        let maxProperties = number(node["maxProperties"])
        if minProperties != nil || maxProperties != nil {
            parts.append(propertyCountCheck(minProperties ?? 0, maxProperties ?? .infinity))
        }
        var required: [(String, [SchemaValue])] = []
        var schemas: [(String, Check)] = []
        if draft != .draft7 {
            for (key, list) in entries(node["dependentRequired"]) {
                if let items = list.arrayValue { required.append((key, items)) }
            }
            for (key, item) in entries(node["dependentSchemas"]) { schemas.append((key, try check(item, base: base))) }
        }
        for (key, dependency) in entries(node["dependencies"]) {
            if let items = dependency.arrayValue { required.append((key, items)) }
            else { schemas.append((key, try check(dependency, base: base))) }
        }
        if !required.isEmpty { parts.append(dependentRequiredCheck(required)) }
        if !schemas.isEmpty { parts.append(dependentSchemasCheck(schemas)) }
        if parts.isEmpty { return strict ? IS_OBJECT : nil }
        return guardObject(and(parts), strict)
    }

    // compiler.ts:328
    private func objectCore(_ node: SchemaObject, base: String, guardMode: Guard) throws -> Check? {
        let properties = node["properties"]?.objectValue ?? SchemaObject()
        let required = node["required"]?.arrayValue?.compactMap(\.stringValue) ?? []
        let patterns = node["patternProperties"]?.objectValue ?? SchemaObject()
        let additional = node["additionalProperties"]
        let keys = properties.keys
        let patternKeys = patterns.keys
        if keys.count + required.count + patternKeys.count == 0 &&
            (additional == nil || additional == .bool(true)) { return nil }

        var propertyEntries: [PropertyEntry] = []
        for (key, schema) in properties {
            let compiled = try check(schema, base: base)
            let leaf = leafOf(compiled, schema: schema)
            let isRequired = required.contains { sameKey($0, key) }
            let inherited = prototypeNames.contains(key)
            let flags = (leaf?.code ?? 0) | (isRequired ? REQUIRED : 0) | (inherited ? INHERITED : 0)
            propertyEntries.append(PropertyEntry(key: key, check: compiled, leaf: leaf, flags: flags))
        }
        let extraRequired = required.filter { requiredKey in !keys.contains { sameKey($0, requiredKey) } }
        var patternChecks: [(NSRegularExpression, Check)] = []
        for (pattern, schema) in patterns {
            patternChecks.append((try schemaCompileRegex(pattern), try check(schema, base: base)))
        }
        let extra = try (additional == nil || additional == .bool(true)) ? nil : check(additional ?? .bool(true), base: base)
        if patternChecks.isEmpty && extraRequired.isEmpty && (extra == nil || additional == .bool(false)) {
            let count = keys.filter { key in required.contains { sameKey($0, key) } }.count
            return declaredObject(propertyEntries, count, additional == .bool(false), guardMode)
        }
        return openObject(propertyEntries, keys, extraRequired, patternChecks, extra, guardMode)
    }

    // compiler.ts:361
    private func arrayGroup(_ node: SchemaObject, base: String, strict: Bool) throws -> Check? {
        var prefix: [SchemaValue] = []
        var rest: SchemaValue?
        if let items = node["items"]?.arrayValue {
            prefix = items
            rest = node["additionalItems"]
        } else {
            if draft != .draft7 { prefix = node["prefixItems"]?.arrayValue ?? [] }
            rest = node["items"]
        }
        let prefixChecks = try prefix.map { try check($0, base: base) }
        let restCheck = try (rest == nil || rest == .bool(true)) ? nil : check(rest ?? .bool(true), base: base)
        let restLeaf: Leaf?
        if let rest, let restCheck { restLeaf = leafOf(restCheck, schema: rest) }
        else { restLeaf = nil }
        let min = number(node["minItems"])
        let max = number(node["maxItems"])
        if node["contains"] == nil && node["uniqueItems"] != .bool(true) &&
            (!prefixChecks.isEmpty || restCheck != nil) {
            return listCheck(strict ? GUARD_STRICT : GUARD_LOOSE, min ?? 0, max ?? .infinity, prefixChecks, restCheck, restLeaf: restLeaf)
        }
        var parts: [Check] = []
        if !prefixChecks.isEmpty || restCheck != nil { parts.append(itemsCheck(prefixChecks, restCheck)) }
        if min != nil || max != nil { parts.append(lengthCheck(min ?? 0, max ?? .infinity)) }
        if let contains = node["contains"] {
            let minContains = draft == .draft7 ? 1 : (number(node["minContains"]) ?? 1)
            let maxContains = draft == .draft7 ? Double.infinity : (number(node["maxContains"]) ?? .infinity)
            parts.append(containsCheck(try check(contains, base: base), minContains, maxContains))
        }
        if node["uniqueItems"] == .bool(true) { parts.append(uniqueCheck) }
        if parts.isEmpty { return strict ? IS_ARRAY : nil }
        return guardArray(and(parts), strict)
    }

    // compiler.ts:400
    func annotating(_ node: SchemaValue, base: String) throws -> AnnotatingCheck {
        if case .bool(true) = node { return ANNOTATING_TRUE }
        if case .bool(false) = node { return ANNOTATING_FALSE }
        guard case .object(let object) = node else {
            throw SchemaCompileError.malformedSchema("A schema must be an object or a boolean, got \(node.stringify())")
        }
        let key = cacheKey(node, base)
        if let cached = annotatingCache.withLock({ $0[key] }) { return cached }
        let slot = AnnotatingSlot()
        annotatingCache.withLock { $0[key] = indirectAnnotating(slot) }
        do {
            let current = resolver.withLock { $0.baseFor(object, base) }
            let compiled = try buildAnnotating(object, base: current)
            slot.install(compiled)
            annotatingCache.withLock { $0[key] = compiled }
            return compiled
        } catch {
            _ = annotatingCache.withLock { $0.removeValue(forKey: key) }
            throw error
        }
    }

    // compiler.ts:416
    private func buildAnnotating(_ node: SchemaObject, base: String) throws -> AnnotatingCheck {
        var rest = SchemaObject()
        var annotates = false
        for (key, value) in node {
            if annotatingKeywords.contains(key) { annotates = true }
            else { rest[key] = value }
        }
        let plainCheck = try plain(rest, base: base)
        var parts: [AnnotatingCheck] = []
        if annotates { try annotatingParts(node, base: base, parts: &parts) }
        let all = parts.isEmpty ? ignoreAnnotations(plainCheck) : annotateAll(plainCheck, parts)
        let own = node["unevaluatedProperties"] != nil || node["unevaluatedItems"] != nil ? isolateAnnotations(all) : all
        if let scope, isResource(node, at: base) { return scopedAnnotating(scope: scope, uri: base, check: own) }
        return own
    }

    // compiler.ts:434
    private func annotatingParts(_ node: SchemaObject, base: String, parts: inout [AnnotatingCheck]) throws {
        if node["properties"] != nil || node["patternProperties"] != nil || node["additionalProperties"] != nil {
            var props: [(String, Check)] = []
            for (key, schema) in entries(node["properties"]) { props.append((key, try check(schema, base: base))) }
            var patterns: [(NSRegularExpression, Check)] = []
            for (pattern, schema) in entries(node["patternProperties"]) {
                patterns.append((try schemaCompileRegex(pattern), try check(schema, base: base)))
            }
            let extra = try node["additionalProperties"].map { try check($0, base: base) }
            parts.append(annotateObject(props, patterns, extra))
        }
        if node["prefixItems"] != nil || node["items"] != nil || node["contains"] != nil {
            let prefix = node["prefixItems"]?.arrayValue ?? node["items"]?.arrayValue ?? []
            let rest = node["items"]?.arrayValue != nil ? node["additionalItems"] : node["items"]
            let prefixChecks = try prefix.map { try check($0, base: base) }
            let restCheck = try rest.map { try check($0, base: base) }
            let containsCheckValue = try node["contains"].map { try check($0, base: base) }
            parts.append(annotateArray(prefixChecks, restCheck, containsCheckValue,
                                       number(node["minContains"]) ?? 1, number(node["maxContains"]) ?? .infinity))
        }
        if let list = node["allOf"]?.arrayValue {
            for child in list { parts.append(try annotating(child, base: base)) }
        }
        if let list = node["anyOf"]?.arrayValue {
            parts.append(annotateAny(try list.map { try annotating($0, base: base) }, false))
        }
        if let list = node["oneOf"]?.arrayValue {
            parts.append(annotateAny(try list.map { try annotating($0, base: base) }, true))
        }
        if let condition = node["if"] {
            let yes = try node["then"].map { try annotating($0, base: base) }
            let no = try node["else"].map { try annotating($0, base: base) }
            parts.append(annotateIf(try annotating(condition, base: base), yes, no))
        }
        if let reference = node["$ref"]?.stringValue { parts.append(try annotatingRef(reference, base: base)) }
        if let reference = node["$dynamicRef"]?.stringValue { parts.append(try annotatingDynamicRef(reference, base: base)) }
        for (key, schema) in entries(node["dependentSchemas"]) {
            parts.append(annotateDependent(key, try annotating(schema, base: base)))
        }
        if let unevaluated = node["unevaluatedProperties"] {
            parts.append(unevaluatedProperties(try check(unevaluated, base: base)))
        }
        if let unevaluated = node["unevaluatedItems"] {
            parts.append(unevaluatedItems(try check(unevaluated, base: base)))
        }
    }

    // compiler.ts:492
    private func annotatingRef(_ reference: String, base: String) throws -> AnnotatingCheck {
        let target = try resolve(reference, base: base)
        let compiled = try annotating(target.node, base: target.base)
        if let scope, target.base != base { return scopedAnnotating(scope: scope, uri: target.base, check: compiled) }
        return compiled
    }

    // compiler.ts:498
    private func annotatingDynamicRef(_ reference: String, base: String) throws -> AnnotatingCheck {
        guard let resolved = try bookended(reference, base: base) else { return try annotatingRef(reference, base: base) }
        let fallback = try annotating(resolved.initial.node, base: resolved.initial.base)
        let lookup = dynamicLookup(name: resolved.name, failure: ANNOTATING_FALSE) { node, base in
            try self.annotating(node, base: base)
        }
        guard let scope else { return fallback }
        return { value, annotations in
            for uri in scope.snapshot() {
                if let compiled = lookup(uri) { return compiled(value, &annotations) }
            }
            return fallback(value, &annotations)
        }
    }

    private func cacheKey(_ value: SchemaValue, _ base: String) -> CacheKey { CacheKey(base + "\u{0}" + value.stringify()) }
    func resolve(_ reference: String, base: String) throws -> (node: SchemaValue, base: String) {
        try resolver.withLock { state in
            state.loadIfNeeded(reference, base: base)
            let (node, foundBase) = try state.resolve(reference, base: base)
            return (node, foundBase)
        }
    }
    private func isResource(_ node: SchemaObject, at base: String) -> Bool {
        resolver.withLock { $0.resources[base] == .object(node) }
    }
    private func dynamicAnchor(_ key: String) -> (node: SchemaValue, base: String)? {
        resolver.withLock { state in
            guard state.dynamicAnchors.contains(key), let node = state.anchors[key] else { return nil }
            return (node, state.anchorBases[key] ?? schemaDocument(key))
        }
    }
}

// compiler.ts:515
let neutralKeywords: Set<String> = [
    "$schema", "$comment", "title", "description", "default", "examples",
    "deprecated", "readOnly", "writeOnly", "$defs", "definitions",
    "contentEncoding", "contentMediaType", "minContains", "maxContains", "$vocabulary",
]

// compiler.ts:535
private let objectExtras: [String] = [
    "propertyNames", "minProperties", "maxProperties",
    "dependentRequired", "dependentSchemas", "dependencies",
]

// compiler.ts:545
private let annotatingKeywords: Set<String> = [
    "properties", "patternProperties", "additionalProperties", "prefixItems",
    "items", "additionalItems", "contains", "minContains", "maxContains",
    "allOf", "anyOf", "oneOf", "if", "then", "else", "$ref", "$dynamicRef",
    "dependentSchemas", "unevaluatedProperties", "unevaluatedItems",
]

// compiler.ts:569
private func constUnion(_ branches: [SchemaValue], exactlyOne: Bool) -> Check? {
    var values: [SchemaValue] = []
    for branch in branches {
        guard case .object(let object) = branch, let constant = object["const"] else { return nil }
        for key in object.keys where key != "const" && !neutralKeywords.contains(key) { return nil }
        guard constant.isSchemaPrimitive else { return nil }
        if exactlyOne && values.contains(constant) { return nil }
        values.append(constant)
    }
    return enumCheck(values)
}

// compiler.ts:582
// Swift closures have no safe stable identity. Branch schemas identify bare types.
private func anyOf(_ checks: [Check], branches: [SchemaValue]) -> Check {
    var types: [SchemaValue] = []
    var rest: [Check] = []
    for (index, check) in checks.enumerated() {
        guard index < branches.count,
              case .object(let object) = branches[index],
              object.keys.allSatisfy({ $0 == "type" || neutralKeywords.contains($0) }),
              case .string? = object["type"] else {
            rest.append(check)
            continue
        }
        if let type = object["type"] { types.append(type) }
    }
    return types.isEmpty ? anyCheck(rest) : maskedAnyCheck(typeMask(types), rest)
}

// compiler.ts:596
private func tagOf(_ branch: SchemaObject, key: String) -> SchemaValue? {
    guard branch["type"]?.stringValue == "object",
          let required = branch["required"]?.arrayValue,
          required.contains(where: { $0.stringValue.map { sameKey($0, key) } ?? false }),
          let tag = branch["properties"]?.objectValue?[key]?.objectValue?["const"],
          tag.isSchemaPrimitive else { return nil }
    return tag
}

// compiler.ts:605
// JavaScript bigint bounds cannot occur in SchemaValue; JSON numbers are Double.
private func bound(_ value: SchemaValue?) -> Bound? { value?.numberValue }

// compiler.ts:610
private func number(_ value: SchemaValue?) -> Double? { value?.numberValue }

// compiler.ts:614
private func entries(_ value: SchemaValue?) -> [(String, SchemaValue)] {
    guard case .object(let object)? = value else { return [] }
    return Array(object)
}

private func sameKey(_ a: String, _ b: String) -> Bool { a.utf16.elementsEqual(b.utf16) }
private let prototypeNames: Set<String> = [
    "constructor", "toString", "toLocaleString", "valueOf", "hasOwnProperty",
    "isPrototypeOf", "propertyIsEnumerable", "__defineGetter__", "__defineSetter__",
    "__lookupGetter__", "__lookupSetter__", "__proto__",
]
private extension SchemaValue {
    var isSchemaPrimitive: Bool {
        switch self {
        case .null, .bool, .number, .string: return true
        case .array, .object: return false
        }
    }
}
