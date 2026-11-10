// Ported from packages/schema/src/resolver.ts, pi-mono v1.5.2.
import Foundation

let defaultSchemaBase = "https://json-schema.invalid/root.json"

func schemaDocument(_ uri: String) -> String {
    String(uri.prefix { $0 != "#" })
}

func schemaResolveURI(_ ref: String, _ base: String) -> String {
    if let baseURL = URL(string: base), let url = URL(string: ref, relativeTo: baseURL)?.absoluteURL {
        return url.absoluteString
    }
    return ref.hasPrefix("#") ? schemaDocument(base) + ref : ref
}

struct SchemaResolver: Sendable {
    let draft: SchemaDraft
    let rootBase = defaultSchemaBase
    let options: CompileOptions
    var registry: [String: SchemaValue] = [:]
    var resources: [String: SchemaValue] = [:]
    var anchors: [String: SchemaValue] = [:]
    var anchorBases: [String: String] = [:]
    var dynamicAnchors: Set<String> = []
    var unresolved: Set<String> = []

    init(root: SchemaValue, options: CompileOptions) {
        self.options = options
        self.draft = options.draft
        resources[defaultSchemaBase] = root
        index(root, base: defaultSchemaBase)
        for (uri, schema) in options.schemas {
            let document = schemaDocument(schemaResolveURI(uri, defaultSchemaBase))
            registry[document] = schema
        }
    }

    func baseFor(_ object: SchemaObject, _ base: String) -> String {
        if base != defaultSchemaBase, resources[base] == .object(object) { return base }
        guard case .string(let id) = object["$id"], !(draft == .draft7 && (object["$ref"]?.stringValue != nil || id.hasPrefix("#"))) else { return base }
        return schemaDocument(schemaResolveURI(id, base))
    }

    mutating func index(_ node: SchemaValue, base: String) {
        guard case .object(let object) = node else { return }
        let refOnly = draft == .draft7 && object["$ref"]?.stringValue != nil
        var current = base
        if !refOnly, case .string(let id) = object["$id"] {
            if draft == .draft7 && id.hasPrefix("#") {
                anchors[schemaDocument(base) + id] = node
                anchorBases[schemaDocument(base) + id] = base
            } else {
                let uri = schemaResolveURI(id, base)
                current = schemaDocument(uri)
                resources[current] = node
                if uri.count > current.count + 1 { anchors[uri] = node; anchorBases[uri] = current }
            }
        }
        if refOnly { return }
        if draft != .draft7 {
            for key in ["$anchor", "$dynamicAnchor"] {
                if case .string(let name) = object[key] {
                    let uri = current + "#" + name
                    anchors[uri] = node
                    anchorBases[uri] = current
                    if key == "$dynamicAnchor" { dynamicAnchors.insert(uri) }
                }
            }
        }
        for key in ["additionalProperties", "propertyNames", "contains", "not", "if", "then", "else", "unevaluatedProperties", "unevaluatedItems", "additionalItems", "contentSchema", "items"] {
            if let child = object[key] { index(child, base: current) }
        }
        for key in ["properties", "patternProperties", "$defs", "definitions", "dependentSchemas", "dependencies"] {
            if case .object(let map) = object[key] { for (_, child) in map { index(child, base: current) } }
        }
        for key in ["allOf", "anyOf", "oneOf", "prefixItems", "items"] {
            if case .array(let children) = object[key] { for child in children { index(child, base: current) } }
        }
    }

    mutating func loadIfNeeded(_ ref: String, base: String) {
        let document = schemaDocument(schemaResolveURI(ref, base))
        if resources[document] == nil, let schema = registry[document] {
            resources[document] = schema
            index(schema, base: document)
        }
    }

    mutating func resolve(_ ref: String, base: String) throws -> (SchemaValue, String) {
        do { return try find(ref, base: base) }
        catch {
            if options.unresolvedRefs == .reject {
                unresolved.insert(schemaResolveURI(ref, base))
                return (.bool(false), base)
            }
            throw error
        }
    }

    func isUnresolved(_ ref: String, base: String) -> Bool {
        unresolved.contains(schemaResolveURI(ref, base))
    }

    private func find(_ ref: String, base: String) throws -> (SchemaValue, String) {
        let uri = schemaResolveURI(ref, base)
        let document = schemaDocument(uri)
        let raw = uri.count > document.count ? String(uri.dropFirst(document.count + 1)) : ""
        let fragment = raw.removingPercentEncoding ?? raw
        guard var node = resources[document] else { throw SchemaCompileError.unresolvedReference("Unresolved $ref \(ref) (no schema registered for \(document))") }
        if fragment.isEmpty { return (node, document) }
        if !fragment.hasPrefix("/") {
            guard let found = anchors[document + "#" + fragment] else { throw SchemaCompileError.unresolvedReference("Unresolved $ref \(ref) (no anchor \(fragment) in \(document))") }
            return (found, anchorBases[document + "#" + fragment] ?? document)
        }
        var current = document
        for part in fragment.dropFirst().split(separator: "/", omittingEmptySubsequences: false) {
            let key = String(part).replacingOccurrences(of: "~1", with: "/").replacingOccurrences(of: "~0", with: "~")
            let next: SchemaValue?
            switch node {
            case .object(let object): next = object[key]
            case .array(let values): next = Int(key).flatMap { $0 >= 0 && $0 < values.count ? values[$0] : nil }
            default: next = nil
            }
            guard let next else { throw SchemaCompileError.unresolvedReference("Unresolved $ref #\(fragment) in \(base)") }
            node = next
            if case .object(let object) = node { current = baseFor(object, current) }
        }
        return (node, current)
    }
}

extension SchemaValue {
    var stringValue: String? { if case .string(let v) = self { return v }; return nil }
    var numberValue: Double? { if case .number(let v) = self { return v }; return nil }
    var arrayValue: [SchemaValue]? { if case .array(let v) = self { return v }; return nil }
    var objectValue: SchemaObject? { if case .object(let v) = self { return v }; return nil }
}
