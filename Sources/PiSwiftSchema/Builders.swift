// Ported from packages/schema/src/builders.ts, pi-mono v1.5.2.

/// Creates ordered JSON Schema values. Options are copied after the builder keywords.
/// TypeScript type brands have no Swift equivalent. These builders return schema data.
public enum SchemaBuilder {
    /// A schema for an optional object property. Only `obj` reads this wrapper.
    public struct Optional: Sendable {
        /// The schema for the property value.
        public let schema: SchemaValue

        /// Creates an optional property schema.
        public init(_ schema: SchemaValue) { self.schema = schema }
    }

    /// One named object property. An array of properties preserves source order.
    public struct Property: Sendable {
        /// The property name.
        public let name: String
        /// The schema for the property value.
        public let schema: SchemaValue
        /// Whether the object can omit the property.
        public let isOptional: Bool

        /// Creates a required object property.
        public init(_ name: String, _ schema: SchemaValue) {
            self.name = name
            self.schema = schema
            self.isOptional = false
        }

        /// Creates an optional object property.
        public init(_ name: String, _ optional: Optional) {
            self.name = name
            self.schema = optional.schema
            self.isOptional = true
        }
    }

    private static func merge(_ base: SchemaObject, _ options: SchemaObject) -> SchemaValue {
        var object = base
        for (key, value) in options { object[key] = value }
        return .object(object)
    }

    /// Creates a string schema with optional bounds, pattern, format, and annotations.
    public static func str(_ options: SchemaObject = [:]) -> SchemaValue {
        merge(["type": .string("string")], options)
    }

    /// Creates a number schema with optional bounds and annotations.
    public static func num(_ options: SchemaObject = [:]) -> SchemaValue {
        merge(["type": .string("number")], options)
    }

    /// Creates an integer schema with optional bounds and annotations.
    public static func int(_ options: SchemaObject = [:]) -> SchemaValue {
        merge(["type": .string("integer")], options)
    }

    /// Creates a bigint extension schema. JSON values cannot represent native bigints.
    public static func bigint(_ options: SchemaObject = [:]) -> SchemaValue {
        merge(["type": .string("bigint")], options)
    }

    /// Creates a boolean schema with optional annotations.
    public static func bool(_ options: SchemaObject = [:]) -> SchemaValue {
        merge(["type": .string("boolean")], options)
    }

    /// Creates a null schema with optional annotations.
    public static func nul(_ options: SchemaObject = [:]) -> SchemaValue {
        merge(["type": .string("null")], options)
    }

    /// Creates an unconstrained schema with optional annotations.
    public static func unknown(_ options: SchemaObject = [:]) -> SchemaValue {
        .object(options)
    }

    /// Creates a schema that accepts exactly the supplied JSON value.
    public static func lit(_ value: SchemaValue, _ options: SchemaObject = [:]) -> SchemaValue {
        merge(["const": value], options)
    }

    /// Creates a schema that accepts one of the supplied JSON values.
    public static func oneOf(_ values: [SchemaValue], _ options: SchemaObject = [:]) -> SchemaValue {
        merge(["enum": .array(values)], options)
    }

    /// Creates a schema that accepts any supplied schema.
    public static func union(_ schemas: [SchemaValue], _ options: SchemaObject = [:]) -> SchemaValue {
        merge(["anyOf": .array(schemas)], options)
    }

    /// Creates a schema that accepts the supplied schema or null.
    public static func nullable(_ schema: SchemaValue, _ options: SchemaObject = [:]) -> SchemaValue {
        union([schema, nul()], options)
    }

    /// Creates an array schema with optional item bounds, uniqueness, and annotations.
    public static func arr(_ items: SchemaValue, _ options: SchemaObject = [:]) -> SchemaValue {
        merge(["type": .string("array"), "items": items], options)
    }

    /// Creates a fixed-length array schema with one schema for each item.
    public static func tuple(_ items: [SchemaValue], _ options: SchemaObject = [:]) -> SchemaValue {
        merge(["type": .string("array"), "prefixItems": .array(items), "items": .bool(false),
               "minItems": .number(Double(items.count))], options)
    }

    /// Creates a string-keyed object schema with one schema for all values.
    public static func map(_ value: SchemaValue, _ options: SchemaObject = [:]) -> SchemaValue {
        merge(["type": .string("object"), "additionalProperties": value], options)
    }

    /// Returns a schema unchanged. Swift does not attach a static value type to it.
    public static func unsafe(_ schema: SchemaValue = .object([:])) -> SchemaValue { schema }

    /// Creates a recursive schema. The closure receives a reference to the supplied identifier.
    /// The identifier must be unique among recursive schemas in the same schema.
    public static func recursive(_ id: String, _ build: (SchemaValue) throws -> SchemaValue) rethrows -> SchemaValue {
        let built = try build(.object(["$ref": .string(id)]))
        var object: SchemaObject
        if case let .object(value) = built { object = value } else { object = [:] }
        object["$id"] = .string(id)
        return .object(object)
    }

    /// Creates a bytes extension schema. JSON values cannot represent native byte arrays.
    public static func bytes(_ options: SchemaObject = [:]) -> SchemaValue {
        merge(["type": .string("bytes")], options)
    }

    /// Marks an object property as optional.
    public static func opt(_ schema: SchemaValue) -> Optional { Optional(schema) }

    /// Creates an object schema with required properties in the supplied order.
    /// Set the `open` option to true to permit other properties.
    public static func obj(_ properties: SchemaObject, _ options: SchemaObject = [:]) -> SchemaValue {
        obj(properties.map { Property($0.key, $0.value) }, options)
    }

    /// Creates an object schema with required and optional properties in source order.
    /// Set the `open` option to true to permit other properties. The option is omitted from the schema.
    public static func obj(_ properties: [Property], _ options: SchemaObject = [:]) -> SchemaValue {
        var names = SchemaObject()
        for property in properties { names[property.name] = .null }
        var props = SchemaObject()
        var required: [SchemaValue] = []
        for name in names.keys {
            guard let property = properties.last(where: { $0.name.utf16.elementsEqual(name.utf16) }) else { continue }
            // The upstream builder assigns to a plain object. This name changes its prototype.
            if !name.utf16.elementsEqual("__proto__".utf16) { props[name] = property.schema }
            if !property.isOptional { required.append(.string(name)) }
        }
        var object: SchemaObject = ["type": .string("object"), "properties": .object(props)]
        if !required.isEmpty { object["required"] = .array(required) }
        if options["open"] != .bool(true) { object["additionalProperties"] = .bool(false) }
        for (key, value) in options where !key.utf16.elementsEqual("open".utf16) { object[key] = value }
        return .object(object)
    }
}
