import Foundation

/// Errors that can occur during JSON Schema validation.
public struct SchemaValidationError: Error, LocalizedError, Sendable {
    public let path: String
    public let message: String

    public var errorDescription: String? {
        "  - \(path): \(message)"
    }

    public init(path: String, message: String) {
        self.path = path
        self.message = message
    }
}

/// Result of JSON Schema validation.
public struct ValidationResult {
    public let isValid: Bool
    public let errors: [SchemaValidationError]
    /// The coerced value as a plain dictionary (for objects) or array.
    public let coercedValue: Any?

    public static func valid(_ value: Any? = nil) -> ValidationResult {
        ValidationResult(isValid: true, errors: [], coercedValue: value)
    }

    public static func invalid(_ errors: [SchemaValidationError]) -> ValidationResult {
        ValidationResult(isValid: false, errors: errors, coercedValue: nil)
    }

    public static func invalid(_ error: SchemaValidationError) -> ValidationResult {
        ValidationResult(isValid: false, errors: [error], coercedValue: nil)
    }
}

/// JSON Schema validator for tool arguments.
///
/// SAFETY: this type has no mutable instance state; validation uses local
/// variables only, so sharing `shared` across tasks is safe.
public final class JSONSchemaValidator: Sendable {
    public static let shared = JSONSchemaValidator()

    public init() {}

    /// Validate a value against a JSON Schema.
    /// - Parameters:
    ///   - value: The value to validate
    ///   - schema: The JSON Schema as a dictionary
    ///   - path: The current path in the object (for error messages)
    ///   - coerceTypes: Whether to attempt type coercion
    /// - Returns: A validation result with any errors and the potentially coerced value
    public func validate(
        _ value: Any?,
        against schema: [String: Any],
        path: String = "root",
        coerceTypes: Bool = true
    ) -> ValidationResult {
        validate(value, against: schema, path: path, coerceTypes: coerceTypes,
                 context: ValidationContext(root: schema))
    }

    /// Validate a sub-schema whose local references resolve against `root`.
    func validate(_ value: Any?, against schema: [String: Any], root: [String: Any],
                  coerceTypes: Bool) -> ValidationResult {
        validate(value, against: schema, path: "root", coerceTypes: coerceTypes,
                 context: ValidationContext(root: root))
    }

    /// Resolve a local JSON pointer reference such as `#/$defs/Item` or `#/anyOf/0`.
    static func resolveLocalReference(_ reference: String, in root: [String: Any]) -> Any? {
        ValidationContext(root: root).resolve(reference)
    }

    private struct ReferenceLocation: Hashable {
        let reference: String
        let valueDepth: Int
    }

    private struct ValidationContext {
        let root: [String: Any]
        var depth = 0
        var valueDepth = 0
        var references: Set<ReferenceLocation> = []

        func childValue() -> ValidationContext {
            var child = self
            child.valueDepth += 1
            return child
        }

        func resolve(_ reference: String) -> Any? {
            if reference == "#" {
                return root
            }
            guard reference.hasPrefix("#/"),
                  let pointer = String(reference.dropFirst()).removingPercentEncoding else {
                return nil
            }
            var current: Any = root
            for rawSegment in pointer.dropFirst().split(separator: "/", omittingEmptySubsequences: false) {
                let segment = String(rawSegment)
                guard segment.range(of: "~(?![01])", options: .regularExpression) == nil else {
                    return nil
                }
                let key = segment.replacingOccurrences(of: "~1", with: "/")
                    .replacingOccurrences(of: "~0", with: "~")
                if let dictionary = current as? [String: Any] {
                    guard let next = dictionary[key] else {
                        return nil
                    }
                    current = next
                } else if let array = current as? [Any], let index = Self.arrayIndex(key), index < array.count {
                    current = array[index]
                } else {
                    return nil
                }
            }
            return current
        }

        /// RFC 6901 array indexes are "0" or digits without a leading zero.
        private static func arrayIndex(_ segment: String) -> Int? {
            guard let first = segment.first, first.isASCII, first.isNumber,
                  segment.allSatisfy({ $0.isASCII && $0.isNumber }),
                  segment == "0" || first != "0" else {
                return nil
            }
            return Int(segment)
        }
    }

    private func validate(
        _ value: Any?,
        against schema: [String: Any],
        path: String,
        coerceTypes: Bool,
        context parentContext: ValidationContext
    ) -> ValidationResult {
        guard parentContext.depth < 128 else {
            return .invalid(SchemaValidationError(path: path, message: "schema validation depth limit exceeded"))
        }
        var context = parentContext
        context.depth += 1
        if let reference = schema["$ref"] {
            guard let reference = reference as? String, let target = context.resolve(reference) else {
                return .invalid(SchemaValidationError(path: path, message: "unresolved local schema reference"))
            }
            let location = ReferenceLocation(reference: reference, valueDepth: context.valueDepth)
            guard context.references.insert(location).inserted else {
                return .invalid(SchemaValidationError(path: path, message: "cyclic schema reference without value progress"))
            }
            let result: ValidationResult
            if let target = target as? [String: Any] {
                result = validate(value, against: target, path: path, coerceTypes: coerceTypes, context: context)
            } else if let allowed = jsonBoolean(target) {
                result = allowed ? .valid(value) : .invalid(SchemaValidationError(path: path, message: "schema rejects all values"))
            } else {
                return .invalid(SchemaValidationError(path: path, message: "schema reference must identify a schema"))
            }
            guard result.isValid else {
                return result
            }
            // The reference is complete. Siblings can use the same target again.
            context.references.remove(location)
            var siblings = schema
            siblings.removeValue(forKey: "$ref")
            guard !siblings.isEmpty else {
                return result
            }
            return validate(result.coercedValue ?? value, against: siblings, path: path,
                            coerceTypes: coerceTypes, context: context)
        }
        if let anyOf = schema["anyOf"] as? [[String: Any]] {
            for subSchema in anyOf {
                let exact = validate(value, against: subSchema, path: path, coerceTypes: false, context: context)
                if exact.isValid {
                    return exact
                }
            }
            if coerceTypes {
                for subSchema in anyOf {
                    let result = validate(value, against: subSchema, path: path, coerceTypes: true, context: context)
                    if result.isValid {
                        return result
                    }
                }
            }
            return .invalid(SchemaValidationError(path: path, message: "does not match any of the allowed schemas"))
        }

        if let oneOf = schema["oneOf"] as? [[String: Any]] {
            let exactMatches = oneOf.compactMap { subSchema -> ValidationResult? in
                let result = validate(value, against: subSchema, path: path, coerceTypes: false, context: context)
                return result.isValid ? result : nil
            }
            if exactMatches.count == 1 {
                return exactMatches[0]
            }
            if exactMatches.count > 1 {
                return .invalid(SchemaValidationError(path: path, message: "matches multiple oneOf schemas"))
            }

            guard coerceTypes else {
                return .invalid(SchemaValidationError(path: path, message: "does not match any of the oneOf schemas"))
            }
            let coercedMatches = oneOf.compactMap { subSchema -> ValidationResult? in
                let result = validate(value, against: subSchema, path: path, coerceTypes: true, context: context)
                return result.isValid ? result : nil
            }
            if coercedMatches.count == 1 {
                return coercedMatches[0]
            }
            if coercedMatches.isEmpty {
                return .invalid(SchemaValidationError(path: path, message: "does not match any of the oneOf schemas"))
            }
            return .invalid(SchemaValidationError(path: path, message: "matches multiple oneOf schemas"))
        }

        // A JSON null is a value. An absent Swift value is a missing argument.
        if value == nil || value is NSNull {
            if let allOf = schema["allOf"] as? [[String: Any]] {
                for branch in allOf {
                    let result = validate(value, against: branch, path: path, coerceTypes: false, context: context)
                    if !result.isValid { return result }
                }
            }
            let types = schema["type"] as? [String] ?? (schema["type"] as? String).map { [$0] } ?? []
            if value == nil && !schemaAllowsNull(schema) && jsonBoolean(schema["nullable"]) != true {
                return .invalid(SchemaValidationError(path: path, message: "value is required"))
            }
            if !types.isEmpty && !types.contains("null") && jsonBoolean(schema["nullable"]) != true {
                return .invalid(SchemaValidationError(path: path, message: "value is required"))
            }
            if let constant = schema["const"], !(constant is NSNull) {
                return .invalid(SchemaValidationError(path: path, message: "must be equal to constant value"))
            }
            if let values = schema["enum"] as? [Any], !values.contains(where: { $0 is NSNull }) {
                return .invalid(SchemaValidationError(path: path, message: "must be one of the allowed values"))
            }
            return .valid(NSNull())
        }

        guard let value = value else {
            return .invalid(SchemaValidationError(path: path, message: "value is required"))
        }

        // Get the expected type(s)
        let expectedTypes: [String]
        if let typeArray = schema["type"] as? [String] {
            expectedTypes = typeArray
        } else if let typeString = schema["type"] as? String {
            expectedTypes = [typeString]
        } else {
            // No type specified, accept any
            expectedTypes = []
        }

        // Handle allOf
        if let allOf = schema["allOf"] as? [[String: Any]] {
            var currentValue: Any = value
            for subSchema in allOf {
                let result = validate(currentValue, against: subSchema, path: path, coerceTypes: coerceTypes, context: context)
                if !result.isValid {
                    return result
                }
                if let coerced = result.coercedValue {
                    currentValue = coerced
                }
            }
            return .valid(currentValue)
        }

        // Handle const
        if let constValue = schema["const"] {
            if !valuesEqual(value, constValue) {
                return .invalid(SchemaValidationError(path: path, message: "must be equal to constant value"))
            }
            return .valid(value)
        }

        // Handle enum
        if let enumValues = schema["enum"] as? [Any] {
            let matches = enumValues.contains { valuesEqual(value, $0) }
            if !matches {
                return .invalid(SchemaValidationError(path: path, message: "must be one of the allowed values"))
            }
            return .valid(value)
        }

        // Without a type, assertions apply only to values of the relevant type.
        if expectedTypes.isEmpty {
            if value is String {
                return validateString(value, schema: schema, path: path, coerceTypes: false)
            }
            if value is [String: Any] {
                return validateObject(value, schema: schema, path: path, coerceTypes: coerceTypes, context: context)
            }
            if value is [Any] {
                return validateArray(value, schema: schema, path: path, coerceTypes: coerceTypes, context: context)
            }
            if let number = value as? NSNumber, CFGetTypeID(number as CFTypeRef) != CFBooleanGetTypeID() {
                let result = validateNumber(value, schema: schema, path: path, coerceTypes: false, allowInteger: false)
                return result.isValid ? .valid(value) : result
            }
            return .valid(value)
        }

        // Try each expected type
        var lastError: SchemaValidationError?
        for expectedType in expectedTypes {
            let result = validateType(value, expectedType: expectedType, schema: schema, path: path, coerceTypes: coerceTypes, context: context)
            if result.isValid {
                return result
            }
            if let error = result.errors.first {
                lastError = error
            }
        }

        return .invalid(lastError ?? SchemaValidationError(path: path, message: "type mismatch"))
    }

    private func validateType(
        _ value: Any,
        expectedType: String,
        schema: [String: Any],
        path: String,
        coerceTypes: Bool,
        context: ValidationContext
    ) -> ValidationResult {
        switch expectedType {
        case "string":
            return validateString(value, schema: schema, path: path, coerceTypes: coerceTypes)
        case "number":
            return validateNumber(value, schema: schema, path: path, coerceTypes: coerceTypes, allowInteger: false)
        case "integer":
            return validateNumber(value, schema: schema, path: path, coerceTypes: coerceTypes, allowInteger: true)
        case "boolean":
            return validateBoolean(value, path: path, coerceTypes: coerceTypes)
        case "array":
            return validateArray(value, schema: schema, path: path, coerceTypes: coerceTypes, context: context)
        case "object":
            return validateObject(value, schema: schema, path: path, coerceTypes: coerceTypes, context: context)
        case "null":
            if value is NSNull {
                return .valid(NSNull())
            }
            return .invalid(SchemaValidationError(path: path, message: "must be null"))
        default:
            return .invalid(SchemaValidationError(path: path, message: "unknown type '\(expectedType)'"))
        }
    }

    // MARK: - String Validation

    private func validateString(_ value: Any, schema: [String: Any], path: String, coerceTypes: Bool) -> ValidationResult {
        var stringValue: String

        if let str = value as? String {
            stringValue = str
        } else if coerceTypes {
            // Coerce to string
            if let bool = jsonBoolean(value) {
                stringValue = bool ? "true" : "false"
            } else if let num = value as? NSNumber {
                stringValue = "\(num)"
            } else {
                return .invalid(SchemaValidationError(path: path, message: "must be a string"))
            }
        } else {
            return .invalid(SchemaValidationError(path: path, message: "must be a string"))
        }

        // Validate minLength
        if let minLength = schema["minLength"] as? Int {
            if stringValue.count < minLength {
                return .invalid(SchemaValidationError(path: path, message: "must have at least \(minLength) characters"))
            }
        }

        // Validate maxLength
        if let maxLength = schema["maxLength"] as? Int {
            if stringValue.count > maxLength {
                return .invalid(SchemaValidationError(path: path, message: "must have at most \(maxLength) characters"))
            }
        }

        // Validate pattern
        if let pattern = schema["pattern"] as? String {
            do {
                let regex = try NSRegularExpression(pattern: pattern)
                let range = NSRange(stringValue.startIndex..., in: stringValue)
                if regex.firstMatch(in: stringValue, range: range) == nil {
                    return .invalid(SchemaValidationError(path: path, message: "must match pattern '\(pattern)'"))
                }
            } catch {
                return .invalid(SchemaValidationError(path: path, message: "invalid regex pattern '\(pattern)'"))
            }
        }

        // Validate format
        if let format = schema["format"] as? String {
            let formatResult = validateStringFormat(stringValue, format: format, path: path)
            if !formatResult.isValid {
                return formatResult
            }
        }

        return .valid(stringValue)
    }

    private func validateStringFormat(_ value: String, format: String, path: String) -> ValidationResult {
        switch format {
        case "email":
            let emailRegex = "^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}$"
            if let regex = try? NSRegularExpression(pattern: emailRegex) {
                let range = NSRange(value.startIndex..., in: value)
                if regex.firstMatch(in: value, range: range) == nil {
                    return .invalid(SchemaValidationError(path: path, message: "must be a valid email"))
                }
            }
        case "uri", "url":
            if URL(string: value) == nil {
                return .invalid(SchemaValidationError(path: path, message: "must be a valid URI"))
            }
        case "date":
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withFullDate]
            if formatter.date(from: value) == nil {
                return .invalid(SchemaValidationError(path: path, message: "must be a valid date (YYYY-MM-DD)"))
            }
        case "date-time":
            let formatter = ISO8601DateFormatter()
            if formatter.date(from: value) == nil {
                return .invalid(SchemaValidationError(path: path, message: "must be a valid date-time (ISO 8601)"))
            }
        case "uuid":
            if UUID(uuidString: value) == nil {
                return .invalid(SchemaValidationError(path: path, message: "must be a valid UUID"))
            }
        default:
            // Unknown format, accept the value
            break
        }
        return .valid(value)
    }

    // MARK: - Number Validation

    /// Extract a number from a schema value (handles both Int and Double storage).
    private func schemaNumber(_ value: Any?) -> Double? {
        guard jsonBoolean(value) == nil else { return nil }
        if let d = value as? Double { return d }
        if let i = value as? Int { return Double(i) }
        if let n = value as? NSNumber { return n.doubleValue }
        return nil
    }

    private func validateNumber(_ value: Any, schema: [String: Any], path: String, coerceTypes: Bool, allowInteger: Bool) -> ValidationResult {
        var numberValue: Double
        var isInteger = false

        // Reject booleans - they bridge to NSNumber but shouldn't be treated as numbers
        if let number = value as? NSNumber, CFGetTypeID(number as CFTypeRef) == CFBooleanGetTypeID() {
            return .invalid(SchemaValidationError(path: path, message: "must be a number"))
        }

        if let num = value as? Double {
            numberValue = num
            isInteger = num.truncatingRemainder(dividingBy: 1) == 0
        } else if let num = value as? Int {
            numberValue = Double(num)
            isInteger = true
        } else if let num = value as? NSNumber {
            // Check it's not a boolean (CFBoolean bridges to NSNumber)
            if CFGetTypeID(num as CFTypeRef) == CFBooleanGetTypeID() {
                return .invalid(SchemaValidationError(path: path, message: "must be a number"))
            }
            numberValue = num.doubleValue
            isInteger = num.doubleValue.truncatingRemainder(dividingBy: 1) == 0
        } else if coerceTypes, let str = value as? String {
            if let parsed = Double(str) ?? parseLenientNumber(str) {
                numberValue = parsed
                isInteger = parsed.truncatingRemainder(dividingBy: 1) == 0
            } else {
                return .invalid(SchemaValidationError(path: path, message: "must be a number"))
            }
        } else {
            return .invalid(SchemaValidationError(path: path, message: "must be a number"))
        }

        // Check if integer is required
        if allowInteger && !isInteger {
            return .invalid(SchemaValidationError(path: path, message: "must be an integer"))
        }

        // Validate minimum
        if let minimum = schemaNumber(schema["minimum"]) {
            let exclusive = jsonBoolean(schema["exclusiveMinimum"]) ?? false
            if exclusive {
                if numberValue <= minimum {
                    return .invalid(SchemaValidationError(path: path, message: "must be greater than \(minimum)"))
                }
            } else {
                if numberValue < minimum {
                    return .invalid(SchemaValidationError(path: path, message: "must be >= \(minimum)"))
                }
            }
        }

        // Validate exclusiveMinimum (draft 6+)
        if let exclusiveMinimum = schemaNumber(schema["exclusiveMinimum"]) {
            if numberValue <= exclusiveMinimum {
                return .invalid(SchemaValidationError(path: path, message: "must be greater than \(exclusiveMinimum)"))
            }
        }

        // Validate maximum
        if let maximum = schemaNumber(schema["maximum"]) {
            let exclusive = jsonBoolean(schema["exclusiveMaximum"]) ?? false
            if exclusive {
                if numberValue >= maximum {
                    return .invalid(SchemaValidationError(path: path, message: "must be less than \(maximum)"))
                }
            } else {
                if numberValue > maximum {
                    return .invalid(SchemaValidationError(path: path, message: "must be <= \(maximum)"))
                }
            }
        }

        // Validate exclusiveMaximum (draft 6+)
        if let exclusiveMaximum = schemaNumber(schema["exclusiveMaximum"]) {
            if numberValue >= exclusiveMaximum {
                return .invalid(SchemaValidationError(path: path, message: "must be less than \(exclusiveMaximum)"))
            }
        }

        // Validate multipleOf
        if let multipleOf = schemaNumber(schema["multipleOf"]), multipleOf > 0 {
            let remainder = numberValue.truncatingRemainder(dividingBy: multipleOf)
            if abs(remainder) > 1e-10 {
                return .invalid(SchemaValidationError(path: path, message: "must be a multiple of \(multipleOf)"))
            }
        }

        if allowInteger {
            return .valid(Int(numberValue))
        }
        return .valid(numberValue)
    }

    /// Attempt to parse a number from a string that may include trailing non-numeric characters.
    /// This is useful for recovering from partial or malformed tool-call arguments.
    private func parseLenientNumber(_ value: String) -> Double? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return nil
        }
        let pattern = #"^[+-]?(?:\d+\.?\d*|\.\d+)(?:[eE][+-]?\d+)?"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return nil
        }
        let range = NSRange(trimmed.startIndex..., in: trimmed)
        guard let match = regex.firstMatch(in: trimmed, options: [], range: range),
              let matchRange = Range(match.range, in: trimmed) else {
            return nil
        }
        let numberString = String(trimmed[matchRange])
        return Double(numberString)
    }

    // MARK: - Boolean Validation

    private func validateBoolean(_ value: Any, path: String, coerceTypes: Bool) -> ValidationResult {
        if let boolValue = jsonBoolean(value) {
            return .valid(boolValue)
        }

        if coerceTypes {
            if let str = value as? String {
                switch str.lowercased() {
                case "true", "yes", "1":
                    return .valid(true)
                case "false", "no", "0":
                    return .valid(false)
                default:
                    break
                }
            } else if let num = value as? NSNumber {
                return .valid(num.boolValue)
            }
        }

        return .invalid(SchemaValidationError(path: path, message: "must be a boolean"))
    }

    // MARK: - Array Validation

    private func validateArray(_ value: Any, schema: [String: Any], path: String, coerceTypes: Bool, context: ValidationContext) -> ValidationResult {
        guard let arrayValue = value as? [Any] else {
            return .invalid(SchemaValidationError(path: path, message: "must be an array"))
        }

        // Validate minItems
        if let minItems = schema["minItems"] as? Int {
            if arrayValue.count < minItems {
                return .invalid(SchemaValidationError(path: path, message: "must have at least \(minItems) items"))
            }
        }

        // Validate maxItems
        if let maxItems = schema["maxItems"] as? Int {
            if arrayValue.count > maxItems {
                return .invalid(SchemaValidationError(path: path, message: "must have at most \(maxItems) items"))
            }
        }

        // Validate uniqueItems
        if let uniqueItems = jsonBoolean(schema["uniqueItems"]), uniqueItems {
            // Simple uniqueness check using JSON encoding
            var seen: [String] = []
            for item in arrayValue {
                let encoded = encodeForComparison(item)
                if seen.contains(encoded) {
                    return .invalid(SchemaValidationError(path: path, message: "items must be unique"))
                }
                seen.append(encoded)
            }
        }

        var coercedItems: [Any] = []

        // Validate tuple forms. Draft 2020-12 uses `prefixItems`; draft-07
        // uses an array-valued `items` plus optional `additionalItems`.
        if let prefixItems = schema["prefixItems"] as? [[String: Any]] {
            for (index, itemSchema) in prefixItems.enumerated() where index < arrayValue.count {
                let result = validate(arrayValue[index], against: itemSchema, path: "\(path)[\(index)]", coerceTypes: coerceTypes, context: context.childValue())
                if !result.isValid { return result }
                coercedItems.append(result.coercedValue ?? arrayValue[index])
            }
            let remaining = arrayValue.dropFirst(prefixItems.count)
            if jsonBoolean(schema["items"]) == false, !remaining.isEmpty {
                return .invalid(SchemaValidationError(path: path, message: "must not have additional items"))
            }
            if let itemsSchema = schema["items"] as? [String: Any] {
                for (offset, item) in remaining.enumerated() {
                    let index = prefixItems.count + offset
                    let result = validate(item, against: itemsSchema, path: "\(path)[\(index)]", coerceTypes: coerceTypes, context: context.childValue())
                    if !result.isValid { return result }
                    coercedItems.append(result.coercedValue ?? item)
                }
            } else {
                coercedItems.append(contentsOf: remaining)
            }
            return .valid(coercedItems)
        }
        if let tupleItems = schema["items"] as? [[String: Any]] {
            for (index, itemSchema) in tupleItems.enumerated() where index < arrayValue.count {
                let result = validate(arrayValue[index], against: itemSchema, path: "\(path)[\(index)]", coerceTypes: coerceTypes, context: context.childValue())
                if !result.isValid { return result }
                coercedItems.append(result.coercedValue ?? arrayValue[index])
            }
            let remaining = arrayValue.dropFirst(tupleItems.count)
            if jsonBoolean(schema["additionalItems"]) == false, !remaining.isEmpty {
                return .invalid(SchemaValidationError(path: path, message: "must not have additional items"))
            }
            if let additionalItems = schema["additionalItems"] as? [String: Any] {
                for (offset, item) in remaining.enumerated() {
                    let index = tupleItems.count + offset
                    let result = validate(item, against: additionalItems, path: "\(path)[\(index)]", coerceTypes: coerceTypes, context: context.childValue())
                    if !result.isValid { return result }
                    coercedItems.append(result.coercedValue ?? item)
                }
            } else {
                coercedItems.append(contentsOf: remaining)
            }
            return .valid(coercedItems)
        }

        // Validate homogeneous items.
        if let itemsSchema = schema["items"] as? [String: Any] {
            for (index, item) in arrayValue.enumerated() {
                let itemPath = "\(path)[\(index)]"
                let result = validate(item, against: itemsSchema, path: itemPath, coerceTypes: coerceTypes, context: context.childValue())
                if !result.isValid {
                    return result
                }
                coercedItems.append(result.coercedValue ?? item)
            }
        } else {
            coercedItems = arrayValue
        }

        return .valid(coercedItems)
    }

    // MARK: - Object Validation

    private func validateObject(_ value: Any, schema: [String: Any], path: String, coerceTypes: Bool, context: ValidationContext) -> ValidationResult {
        guard let objectValue = value as? [String: Any] else {
            return .invalid(SchemaValidationError(path: path, message: "must be an object"))
        }

        var errors: [SchemaValidationError] = []
        var coercedObject: [String: Any] = [:]

        // Get properties schema
        let propertiesSchema = schema["properties"] as? [String: [String: Any]] ?? [:]

        // Validate required properties
        if let required = schema["required"] as? [String] {
            for requiredProp in required {
                if objectValue[requiredProp] == nil {
                    errors.append(SchemaValidationError(path: "\(path).\(requiredProp)", message: "is required"))
                }
            }
        }

        // Early return if there are missing required properties
        if !errors.isEmpty {
            return .invalid(errors)
        }

        // Validate each property
        for (key, propValue) in objectValue {
            let propPath = path == "root" ? key : "\(path).\(key)"

            if let propSchema = propertiesSchema[key] {
                let result = validate(propValue, against: propSchema, path: propPath, coerceTypes: coerceTypes, context: context.childValue())
                if !result.isValid {
                    errors.append(contentsOf: result.errors)
                } else {
                    coercedObject[key] = result.coercedValue ?? propValue
                }
            } else {
                // Check additionalProperties
                let additionalProperties = schema["additionalProperties"]
                if let allowed = jsonBoolean(additionalProperties) {
                    if !allowed {
                        errors.append(SchemaValidationError(path: propPath, message: "additional property not allowed"))
                    } else {
                        coercedObject[key] = propValue
                    }
                } else if let additionalSchema = additionalProperties as? [String: Any] {
                    let result = validate(propValue, against: additionalSchema, path: propPath, coerceTypes: coerceTypes, context: context.childValue())
                    if !result.isValid {
                        errors.append(contentsOf: result.errors)
                    } else {
                        coercedObject[key] = result.coercedValue ?? propValue
                    }
                } else {
                    // Default: allow additional properties
                    coercedObject[key] = propValue
                }
            }
        }

        // Validate minProperties
        if let minProperties = schema["minProperties"] as? Int {
            if objectValue.count < minProperties {
                errors.append(SchemaValidationError(path: path, message: "must have at least \(minProperties) properties"))
            }
        }

        // Validate maxProperties
        if let maxProperties = schema["maxProperties"] as? Int {
            if objectValue.count > maxProperties {
                errors.append(SchemaValidationError(path: path, message: "must have at most \(maxProperties) properties"))
            }
        }

        if errors.isEmpty {
            return .valid(coercedObject)
        }
        return .invalid(errors)
    }

    // MARK: - Helpers

    private func valuesEqual(_ a: Any, _ b: Any) -> Bool {
        // Handle nil/NSNull
        if a is NSNull && b is NSNull { return true }
        if a is NSNull || b is NSNull { return false }

        // Handle strings
        if let aStr = a as? String, let bStr = b as? String {
            return aStr == bStr
        }

        // Keep JSON booleans distinct from numbers before NSNumber equality.
        let aBool = jsonBoolean(a)
        let bBool = jsonBoolean(b)
        if aBool != nil || bBool != nil { return aBool == bBool }

        // Handle numbers
        if let aNum = a as? NSNumber, let bNum = b as? NSNumber {
            return aNum.isEqual(to: bNum)
        }

        // Handle arrays
        if let aArr = a as? [Any], let bArr = b as? [Any] {
            guard aArr.count == bArr.count else { return false }
            for (itemA, itemB) in zip(aArr, bArr) {
                if !valuesEqual(itemA, itemB) { return false }
            }
            return true
        }

        // Handle dictionaries
        if let aDict = a as? [String: Any], let bDict = b as? [String: Any] {
            guard aDict.keys.count == bDict.keys.count else { return false }
            for (key, valueA) in aDict {
                guard let valueB = bDict[key] else { return false }
                if !valuesEqual(valueA, valueB) { return false }
            }
            return true
        }

        return false
    }

    private func encodeForComparison(_ value: Any) -> String {
        // Simple JSON-like encoding for comparison
        if let dict = value as? [String: Any] {
            let sorted = dict.keys.sorted().map { key in
                "\"\(key)\":\(encodeForComparison(dict[key]!))"
            }
            return "{\(sorted.joined(separator: ","))}"
        }
        if let arr = value as? [Any] {
            return "[\(arr.map { encodeForComparison($0) }.joined(separator: ","))]"
        }
        if let str = value as? String {
            return "\"\(str)\""
        }
        if let bool = jsonBoolean(value) {
            return bool ? "true" : "false"
        }
        if let num = value as? NSNumber {
            return "\(num)"
        }
        if value is NSNull {
            return "null"
        }
        return String(describing: value)
    }
}
