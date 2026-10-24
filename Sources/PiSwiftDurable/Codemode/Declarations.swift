// Declaration rendering copied from Sources/PiSwiftCodingAgent/Codemode/Declarations.swift.
import Foundation
import CoreFoundation
import PiSwiftAI
import PiSwiftChord

public let defaultCodemodeInputSchemaMaxChars = 16_000

/// The script-visible description of a tool or global. C5b can attach execution separately.
public struct CodemodeDeclaration: Sendable {
    public var name: String
    public var description: String?
    public var inputSchema: AnyCodable?
    public var outputSchema: AnyCodable?
    public var signature: String?

    public init(name: String, description: String? = nil, inputSchema: AnyCodable? = nil,
                outputSchema: AnyCodable? = nil, signature: String? = nil) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
        self.outputSchema = outputSchema
        self.signature = signature
    }


}

public func toCodemodeIdentifier(_ name: String) -> String {
    var result = ""
    for scalar in name.unicodeScalars {
        let ascii = scalar.value
        let valid = (65...90).contains(ascii) || (97...122).contains(ascii) || ascii == 95 || ascii == 36 ||
            (!result.isEmpty && (48...57).contains(ascii))
        result += valid ? String(scalar) : "_"
    }
    return result.isEmpty ? "_" : result
}

/// Return a diagnostic when two names resolve to the same JavaScript property.
public func codemodeToolIdentifierCollision(_ names: [String]) -> String? {
    codemodeToolIdentifierCollision(names.map { ($0, toCodemodeIdentifier($0)) })
}

func codemodeToolIdentifierCollision(_ entries: [(name: String, identifier: String)]) -> String? {
    var namesByIdentifier: [String: String] = [:]
    for (name, identifier) in entries {
        if let previous = namesByIdentifier[identifier] {
            return "Tools \"\(previous)\" and \"\(name)\" use the same JavaScript identifier \"\(identifier)\"."
        }
        namesByIdentifier[identifier] = name
    }
    return nil
}

private func object(_ value: Any?) -> [String: Any]? { value as? [String: Any] }
private func string(_ value: Any?) -> String? { value as? String }
private func array(_ value: Any?) -> [Any]? { value as? [Any] }
private func boolean(_ value: Any?) -> Bool? {
    guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
    return number.boolValue
}
private func number(_ value: Any?) -> NSNumber? {
    guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
    return number
}
private func jsonString(_ value: Any) -> String? {
    guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .withoutEscapingSlashes, .sortedKeys]) else { return nil }
    return String(data: data, encoding: .utf8)
}

// JavaScript uses decimal notation from 1e-6 through values below 1e21.
private func constraintNumberText(_ number: Double) -> String {
    if number.isNaN { return "NaN" }
    if number == .infinity { return "Infinity" }
    if number == -.infinity { return "-Infinity" }
    if number == 0 { return "0" }
    let negative = number < 0 ? "-" : ""
    let parts = String(abs(number)).lowercased().split(separator: "e")
    let mantissa = String(parts[0])
    let exponent = parts.count == 2 ? Int(parts[1]) ?? 0 : 0
    let decimal = mantissa.split(separator: ".", omittingEmptySubsequences: false)
    let whole = String(decimal[0])
    var digits = whole + (decimal.count == 2 ? String(decimal[1]) : "")
    let decimalPosition = whole.count + exponent
    while digits.count > 1 && digits.last == "0" { digits.removeLast() }
    if abs(number) >= 1e-6 && abs(number) < 1e21 {
        if decimalPosition <= 0 {
            return negative + "0." + String(repeating: "0", count: -decimalPosition) + digits
        }
        if decimalPosition >= digits.count {
            return negative + digits + String(repeating: "0", count: decimalPosition - digits.count)
        }
        let position = digits.index(digits.startIndex, offsetBy: decimalPosition)
        return negative + digits[..<position] + "." + digits[position...]
    }
    let fraction = digits.count > 1 ? "." + digits.dropFirst() : ""
    return negative + String(digits.prefix(1)) + fraction + "e" + (exponent >= 0 ? "+" : "") + String(exponent)
}

private func constraintDefaultJSON(_ value: Any) -> String? {
    if value is NSNull { return "null" }
    if let flag = boolean(value) { return flag ? "true" : "false" }
    if let number = number(value) {
        return number.doubleValue.isFinite ? constraintNumberText(number.doubleValue) : "null"
    }
    if let values = array(value) {
        var items: [String] = []
        for value in values {
            guard let item = constraintDefaultJSON(value) else { return nil }
            items.append(item)
        }
        return "[" + items.joined(separator: ",") + "]"
    }
    if let fields = object(value) {
        var members: [String] = []
        for key in fields.keys.sorted() {
            guard let name = jsonString(key), let item = constraintDefaultJSON(fields[key]!) else { return nil }
            members.append(name + ":" + item)
        }
        return "{" + members.joined(separator: ",") + "}"
    }
    return jsonString(value)
}
private func union(_ members: [String]) -> String {
    var unique: [String] = []
    for member in members where !unique.contains(member) { unique.append(member) }
    if unique.contains("unknown") { return "unknown" }
    return unique.isEmpty ? "never" : unique.joined(separator: " | ")
}

private struct SchemaContext {
    let root: Any
    let tags: Bool
    var resolving: Set<String> = []
    var expansions = 0

    func resolve(_ ref: String) -> Any? {
        guard ref == "#" || ref.hasPrefix("#/") else { return nil }
        var current: Any = root
        for segment in ref.dropFirst(2).split(separator: "/").filter({ !$0.isEmpty }) {
            let key = (String(segment).removingPercentEncoding ?? String(segment))
                .replacingOccurrences(of: "~1", with: "/").replacingOccurrences(of: "~0", with: "~")
            guard let next = object(current)?[key] else { return nil }
            current = next
        }
        return boolean(current) != nil || object(current) != nil ? current : nil
    }
}

public func schemaToType(_ schema: AnyCodable, maxChars: Int? = nil) -> String {
    func render(tags: Bool) -> String {
        var context = SchemaContext(root: schema.value, tags: tags)
        return typeText(schema.value, &context)
    }
    let rendered = render(tags: true)
    guard let maxChars, rendered.utf16.count > maxChars else { return rendered }
    let untagged = render(tags: false)
    return untagged.utf16.count <= maxChars ? untagged : "unknown"
}

public func schemaToType(_ schema: [String: AnyCodable], maxChars: Int? = nil) -> String {
    schemaToType(AnyCodable(schema.mapValues(\.value)), maxChars: maxChars)
}

private func typeText(_ value: Any, _ context: inout SchemaContext) -> String {
    if let flag = boolean(value) { return flag ? "unknown" : "never" }
    guard let schema = object(value) else { return "unknown" }
    if let ref = string(schema["$ref"]) {
        guard !context.resolving.contains(ref), context.expansions < 32,
              let target = context.resolve(ref) else { return "unknown" }
        context.expansions += 1
        context.resolving.insert(ref)
        defer { context.resolving.remove(ref) }
        return typeText(target, &context)
    }
    if let constant = schema["const"] { return jsonString(constant) ?? "unknown" }
    if let values = array(schema["enum"]) { return union(values.map { jsonString($0) ?? "unknown" }) }
    if let variants = array(schema["anyOf"]) ?? array(schema["oneOf"]) {
        return union(variants.map { typeText($0, &context) })
    }
    if let all = array(schema["allOf"]) {
        let parts = all.map { typeText($0, &context) }.filter { $0 != "unknown" }
        return parts.isEmpty ? "unknown" : parts.map { $0.contains(" | ") ? "(\($0))" : $0 }.joined(separator: " & ")
    }
    if let types = array(schema["type"]) {
        return union(types.map { entry in
            var copy = schema
            copy["type"] = entry
            return typeText(copy, &context)
        })
    }
    switch string(schema["type"]) {
    case "string": return "string"
    case "number", "integer": return "number"
    case "boolean": return "boolean"
    case "null": return "null"
    case "array": return arrayType(schema, &context)
    case "object": return objectType(schema, &context)
    case nil:
        if schema["properties"] != nil || schema["additionalProperties"] != nil || schema["required"] != nil {
            return objectType(schema, &context)
        }
        if schema["items"] != nil || schema["prefixItems"] != nil { return arrayType(schema, &context) }
        return "unknown"
    default: return "unknown"
    }
}

private func arrayType(_ schema: [String: Any], _ context: inout SchemaContext) -> String {
    if let items = schema["items"], array(items) == nil { return "Array<\(typeText(items, &context))>" }
    let tuple = array(schema["prefixItems"]) ?? array(schema["items"]) ?? []
    return tuple.isEmpty ? "unknown[]" : "[\(tuple.map { typeText($0, &context) }.joined(separator: ", "))]"
}

private func propertyKey(_ name: String) -> String {
    let valid = !name.isEmpty && toCodemodeIdentifier(name) == name
    return valid ? name : (jsonString(name) ?? "\"\(name)\"")
}

private func constraintTags(_ value: Any?) -> String {
    guard let property = object(value) else { return "" }
    let variants = array(property["anyOf"]) ?? array(property["oneOf"]) ?? []
    let nonNull = variants.filter { string(object($0)?["type"]) != "null" }
    var schemas = [property]
    if nonNull.count == 1, let branch = object(nonNull[0]) { schemas.append(branch) }
    // Draft-04 uses boolean exclusive bounds with minimum and maximum.
    schemas = schemas.map { schema in
        var copy = schema
        if boolean(schema["exclusiveMinimum"]) == true {
            copy["exclusiveMinimum"] = schema["minimum"]
            copy.removeValue(forKey: "minimum")
        }
        if boolean(schema["exclusiveMaximum"]) == true {
            copy["exclusiveMaximum"] = schema["maximum"]
            copy.removeValue(forKey: "maximum")
        }
        return copy
    }
    var tags: [String] = []
    if schemas.contains(where: { string($0["type"]) == "integer" || (array($0["type"]) ?? []).contains { string($0) == "integer" } }) {
        tags.append("@integer")
    }
    let keywords = ["minimum", "exclusiveMinimum", "maximum", "exclusiveMaximum", "multipleOf",
                    "minLength", "maxLength", "pattern", "format", "minItems", "maxItems"]
    let lowerBounds: Set<String> = ["minimum", "exclusiveMinimum", "minLength", "minItems"]
    let upperBounds: Set<String> = ["maximum", "exclusiveMaximum", "maxLength", "maxItems"]
    for keyword in keywords {
        let values = schemas.compactMap { $0[keyword] }
        if lowerBounds.contains(keyword) || upperBounds.contains(keyword) {
            let numbers = values.compactMap { number($0)?.doubleValue }
            let bound = numbers.first { $0.isNaN } ?? (lowerBounds.contains(keyword) ? numbers.max() : numbers.min())
            if let bound { tags.append("@\(keyword) \(constraintNumberText(bound))") }
            continue
        }
        var seenNumbers: [Double] = []
        var seenStrings: Set<[UInt16]> = []
        for value in values {
            if let number = number(value)?.doubleValue,
               !seenNumbers.contains(where: { $0 == number || ($0.isNaN && number.isNaN) }) {
                seenNumbers.append(number)
                tags.append("@\(keyword) \(constraintNumberText(number))")
            } else if let text = string(value), seenStrings.insert(Array(text.utf16)).inserted {
                tags.append("@\(keyword) \(text)")
            }
        }
    }
    if schemas.contains(where: { boolean($0["uniqueItems"]) == true }) { tags.append("@uniqueItems") }
    // Annotations come from the property, rather than its nullable branch.
    if let value = property["default"], !(value is NSNull), let text = constraintDefaultJSON(value) {
        tags.append("@default \(text)")
    }
    if boolean(property["deprecated"]) == true { tags.append("@deprecated") }
    return tags.filter { $0.utf16.count <= 80 }.map { tag in
        tag.replacingOccurrences(of: "\r", with: "\\u000d")
            .replacingOccurrences(of: "\n", with: "\\u000a")
            .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
            .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
    }.joined(separator: " ")
}

private func objectType(_ schema: [String: Any], _ context: inout SchemaContext) -> String {
    let properties = object(schema["properties"]) ?? [:]
    let required = Set((array(schema["required"]) ?? []).compactMap { string($0) })
    // JavaScript's default Array.sort compares UTF-16 code units.
    let names = properties.keys.sorted { $0.utf16.lexicographicallyPrecedes($1.utf16) }
    var members = names.map { name in
        "\(propertyKey(name))\(required.contains(name) ? "" : "?"): \(typeText(properties[name]!, &context));"
    }
    if let additional = schema["additionalProperties"], boolean(additional) != false {
        members.append("[key: string]: \(boolean(additional) == true ? "unknown" : typeText(additional, &context));")
    } else if schema["additionalProperties"] == nil && names.isEmpty {
        members.append("[key: string]: unknown;")
    }
    if members.isEmpty { return "{}" }
    let comments = names.map { name -> [String] in
        let description = string(object(properties[name])?["description"]) ?? ""
        var lines = description.components(separatedBy: CharacterSet(charactersIn: "\r\n\u{2028}\u{2029}"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        let tags = context.tags ? constraintTags(properties[name]) : ""
        if !tags.isEmpty { lines.append(tags) }
        return lines
    }
    if !comments.contains(where: { !$0.isEmpty }) { return "{ \(members.joined(separator: " ")) }" }
    var lines = ["{"]
    for (index, comment) in comments.enumerated() {
        for line in comment { lines.append("  // \(line)") }
        lines.append("  " + members[index].replacingOccurrences(of: "\n", with: "\n  "))
    }
    for member in members.dropFirst(names.count) { lines.append("  " + member) }
    lines.append("}")
    return lines.joined(separator: "\n")
}

@available(*, deprecated, message: "Codemode renders output schemas as plain types.")
public func mcpStructuredContentSchema(_ schema: AnyCodable?) -> AnyCodable? {
    guard let schema, let properties = object(object(schema.value)?["properties"]),
          let content = object(properties["content"]), string(content["type"]) == "array",
          let items = object(content["items"]), string(items["type"]) == "object",
          string(object(properties["isError"])?["type"]) == "boolean",
          string(object(properties["_meta"])?["type"]) == "object" else { return nil }
    if let structured = properties["structuredContent"], object(structured) != nil || boolean(structured) != nil {
        return AnyCodable(structured)
    }
    return AnyCodable(true)
}

public func renderToolOutputType(_ schema: AnyCodable?) -> String {
    return schema.map { schemaToType($0) } ?? "unknown"
}

public func renderToolSignature(_ tool: CodemodeDeclaration, inputMaxChars: Int = defaultCodemodeInputSchemaMaxChars) -> String {
    let input = tool.inputSchema.map { schemaToType($0, maxChars: inputMaxChars) } ?? "unknown"
    return "\(toCodemodeIdentifier(tool.name))(args: \(input)): Promise<\(renderToolOutputType(tool.outputSchema))>;"
}

public func renderToolSample(_ tool: CodemodeDeclaration, inputMaxChars: Int = defaultCodemodeInputSchemaMaxChars) -> String {
    let declaration = "declare const tools: { \(renderToolSignature(tool, inputMaxChars: inputMaxChars)) };"
    return "\(tool.description?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")\n\ncodemode tool declaration:\n```ts\n\(declaration)\n```"
}

private func docComment(_ description: String?, indent: String) -> String {
    guard let text = description?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return "" }
    let lines = text.replacingOccurrences(of: "*/", with: "*\\/")
        .replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
    if lines.count == 1 { return "\(indent)/** \(lines[0]) */\n" }
    return "\(indent)/**\n" + lines.map { "\(indent) *\($0.isEmpty ? "" : " \($0)")" }.joined(separator: "\n") + "\n\(indent) */\n"
}

private func renderGlobal(_ head: String, _ global: CodemodeDeclaration, indent: String) -> String {
    if let signature = global.signature { return "\(docComment(global.description, indent: indent))\(indent)\(head)\(signature);" }
    let input = global.inputSchema.map { schemaToType($0) } ?? "unknown"
    let output = global.outputSchema.map { schemaToType($0) } ?? "unknown"
    return "\(docComment(global.description, indent: indent))\(indent)\(head)(args: \(input)): Promise<\(output)>;"
}

public func renderDeclarations(tools: [CodemodeDeclaration] = [], globals: [CodemodeDeclaration] = []) -> String {
    var sections: [String] = []
    if !tools.isEmpty {
        let members = tools.map { docComment($0.description, indent: "  ") + "  " + renderToolSignature($0) }
        sections.append("declare const tools: {\n\(members.joined(separator: "\n"))\n};")
    }
    var namespaces: [String: [String]] = [:]
    var namespaceOrder: [String] = []
    for global in globals {
        guard let dot = global.name.firstIndex(of: ".") else {
            sections.append(renderGlobal("declare function \(global.name)", global, indent: ""))
            continue
        }
        let namespace = String(global.name[..<dot])
        if namespaces[namespace] == nil { namespaces[namespace] = []; namespaceOrder.append(namespace) }
        namespaces[namespace]!.append(renderGlobal(String(global.name[global.name.index(after: dot)...]), global, indent: "  "))
    }
    for namespace in namespaceOrder {
        sections.append("declare const \(namespace): {\n\(namespaces[namespace]!.joined(separator: "\n"))\n};")
    }
    return sections.joined(separator: "\n\n")
}

/// The fixed model description. The injected engine supplies the sandbox implementation.
public func codemodeDescription(models: Bool) -> String {
    let intro = """
    Run JavaScript that calls other tools. The input is raw JavaScript (not JSON, no code fence), run as an async function body in an injected sandbox: top-level `await` and `return` work. No Node, file system, network, or timers.
    - `await tools.<name>({ ...args })` resolves to a string, or an object if the tool's declaration says so, and rejects with an Error on failure. A tool whose declaration returns an object resolves on failure too when it returned that object; check its fields. Calls still running when the script ends are cancelled.
    - The script survives a restart: it resumes where it was, without running finished calls again.
    - Optional first line: `// @options: {"max_output_tokens": 10000, "timeout_ms": 60000}`
    """
    let globals = """
    Globals:
    - `text(value)`, `image(dataUrlOrImageBlock)`, `console.log(...)`, and top-level `return` add output; `exit()` ends the script. With several text items, each starts with a `==> text N/M <==` line, and `console` lines follow the other output in one `<console_output>` block. `image()` also saves the image to a temp file and the result names its path.
    - `store(key, value)` and `load(key)` keep JSON values across codemode calls.
    - `ALL_TOOLS`, `await searchTools(query, { limit?, namespace? })`, `await describeTool(name)`, `await describeNamespace(name)`: find tools the `codemode` section does not list.
    """
    return ([intro, globals] + (models ? [codemodeModelsDescription] : []) + ["The `codemode` section of the system prompt lists the tools scripts can call, by namespace, as far as space allows."]).joined(separator: "\n\n")
}

public func codemodeSample(of tool: ToolRegistration) throws -> String {
    let parameters = try tool.currentOrderedDeclaration()["parameters"] ?? .object([:])
    return renderToolSample(CodemodeDeclaration(name: tool.name, description: tool.description,
        inputSchema: AnyCodable(try foundationJSON(from: parameters)),
        outputSchema: AnyCodable(try foundationJSON(from: tool.structuredOutputSchema.map(JSONValue.object) ?? ["type": "string"]))))
}

/// Selects declarations in rounds, so each namespace can have a tool within the budget.
public func codemodeSection(tools: [ToolRegistration], namespaces: [CodemodeNamespace], inlineBudget: Int) throws -> String? {
    guard !tools.isEmpty else { return nil }
    struct Entry { var name: String; var section: String; var cost: Int; var order: Int }
    struct Group { var namespace: CodemodeNamespace?; var entries: [Entry] }
    var groups: [[UInt16]: Group] = [[]: Group(namespace: nil, entries: [])]
    for (order, tool) in tools.enumerated() {
        let namespace = namespaces.filter { tool.name.utf16.starts(with: $0.prefix.utf16) }.max { $0.prefix.utf16.count < $1.prefix.utf16.count }
        let key = Array((namespace.map { "ns:" + $0.name } ?? "").utf16)
        let id = toCodemodeIdentifier(tool.name)
        let heading = id == tool.name ? "### `\(id)`" : "### `\(id)` (`\(tool.name)`)"
        let section = try heading + "\n" + codemodeSample(of: tool).trimmingCharacters(in: .whitespacesAndNewlines)
        if groups[key] == nil { groups[key] = Group(namespace: namespace, entries: []) }
        groups[key]!.entries.append(Entry(name: tool.name, section: section, cost: (section.utf16.count + 3) / 4, order: order))
    }
    let ordered = groups.values.sorted {
        if $0.namespace == nil { return $1.namespace != nil }
        if $1.namespace == nil { return false }
        return $0.namespace!.name.localizedCompare($1.namespace!.name) == .orderedAscending
    }
    let queues = ordered.map { $0.entries.sorted { $0.cost == $1.cost ? $0.order < $1.order : $0.cost < $1.cost } }
    var offsets = Array(repeating: 0, count: queues.count)
    var active = queues.indices.filter { !queues[$0].isEmpty }, remaining = inlineBudget
    var shown: Set<[UInt16]> = []
    while !active.isEmpty {
        active = active.filter { index in
            let entry = queues[index][offsets[index]]
            guard entry.cost <= remaining else { return false }
            shown.insert(Array(entry.name.utf16)); remaining -= entry.cost; offsets[index] += 1
            return offsets[index] < queues[index].count
        }
    }
    var sections = ["Tools scripts can call (`await tools.<name>(args)`):"]
    for group in ordered where !group.entries.isEmpty {
        let visible = group.entries.filter { shown.contains(Array($0.name.utf16)) }
        if let namespace = group.namespace {
            let suffix = visible.count == group.entries.count ? "" : visible.isEmpty ? " (tools not listed)" : " (some tools not listed)"
            let description = namespace.description?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            sections.append("## \(namespace.name)\(suffix)" + (description.isEmpty ? "" : "\n" + description))
        } else if visible.count < group.entries.count { sections.append("Some tools are not listed: find them with `searchTools()`.") }
        sections.append(contentsOf: visible.map(\.section))
    }
    return sections.joined(separator: "\n\n")
}
