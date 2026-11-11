// Ported from packages/schema/src/validator.ts, pi-mono v1.5.2.
import Synchronization

private final class DynamicCheckGate: Sendable {
    private let mutex = Mutex<Void>(())
    func run(_ check: Check, _ value: SchemaValue) -> Bool {
        mutex.withLock { _ in check(value) }
    }
    func runErrors(_ explainer: Explainer, _ value: SchemaValue) -> [SchemaIssue] {
        mutex.withLock { _ in explainer.errors(value) }
    }
    func runValue(_ body: () -> SchemaValue) -> SchemaValue {
        mutex.withLock { _ in body() }
    }
}

/// A compiled schema whose check is safe to call from concurrent tasks.
public final class Validator: Sendable {
    let compiler: Compiler
    private let checkFunction: Check
    private let dynamicGate: DynamicCheckGate?
    private let explainer = Mutex<Explainer?>(nil)
    let schemaDepth: Int

    init(compiler: Compiler, check: @escaping Check) {
        self.compiler = compiler
        self.checkFunction = check
        self.dynamicGate = compiler.dynamic ? DynamicCheckGate() : nil
        self.schemaDepth = schemaNestingDepth(compiler.schema, stoppingAt: schemaMaximumSchemaDepth)
    }

    /// Returns whether value passes this schema.
    public func check(_ value: SchemaValue) -> Bool {
        let depth = schemaNestingDepth(value, stoppingAt: schemaMaximumValueDepth)
        if depth > schemaMaximumValueDepth { return false }
        if max(depth, schemaDepth) > schemaLargeStackThreshold {
            return schemaOnLargeStack { self.checkUnchecked(value) } ?? false
        }
        return checkUnchecked(value)
    }

    private func checkUnchecked(_ value: SchemaValue) -> Bool {
        if let dynamicGate { return dynamicGate.run(checkFunction, value) }
        return checkFunction(value)
    }

    /// Returns ordered issues for a failed value, or an empty array for a valid value.
    public func errors(_ value: SchemaValue) -> [SchemaIssue] {
        let depth = schemaNestingDepth(value, stoppingAt: schemaMaximumValueDepth)
        if depth > schemaMaximumValueDepth { return [schemaValueTooDeepIssue] }
        if max(depth, schemaDepth) > schemaLargeStackThreshold {
            return schemaOnLargeStack { self.errorsUnchecked(value) } ?? [schemaValueTooDeepIssue]
        }
        return errorsUnchecked(value)
    }

    private func errorsUnchecked(_ value: SchemaValue) -> [SchemaIssue] {
        if checkUnchecked(value) { return [] }
        let source = explainer.withLock { cached -> Explainer in
            if let cached { return cached }
            let created = Explainer(c: compiler, schema: compiler.schema)
            cached = created
            return created
        }
        if let dynamicGate { return dynamicGate.runErrors(source, value) }
        return source.errors(value)
    }

    /// Returns the original value when it passes, or its ordered issues.
    public func validate(_ value: SchemaValue) -> SchemaParseResult {
        let depth = schemaNestingDepth(value, stoppingAt: schemaMaximumValueDepth)
        if depth > schemaMaximumValueDepth { return .failed([schemaValueTooDeepIssue]) }
        if max(depth, schemaDepth) > schemaLargeStackThreshold {
            return schemaOnLargeStack { self.validateUnchecked(value) } ?? .failed([schemaValueTooDeepIssue])
        }
        return validateUnchecked(value)
    }

    func validateUnchecked(_ value: SchemaValue) -> SchemaParseResult {
        if checkUnchecked(value) { return .ok(value) }
        return .failed(errorsUnchecked(value))
    }

    func withCoercionGate(_ body: () -> SchemaValue) -> SchemaValue {
        if let dynamicGate { return dynamicGate.runValue(body) }
        return body()
    }
}

/// A compiled validator that can coerce loosely typed JSON values.
public final class CoercingValidator: Sendable {
    private let validator: Validator
    private let coercer: Mutex<Coercer?> = Mutex(nil)

    init(validator: Validator) { self.validator = validator }

    /// Returns whether a value satisfies the schema without coercion.
    public func check(_ value: SchemaValue) -> Bool { validator.check(value) }

    /// Returns the ordered schema issues for a value without coercion.
    public func errors(_ value: SchemaValue) -> [SchemaIssue] { validator.errors(value) }

    /// Validates a value without coercion.
    public func validate(_ value: SchemaValue) -> SchemaParseResult { validator.validate(value) }

    // validator.ts:72
    /// Coerces a value according to the schema. This does not throw.
    public func coerce(_ value: SchemaValue) -> SchemaValue {
        let depth = schemaNestingDepth(value, stoppingAt: schemaMaximumValueDepth)
        if depth > schemaMaximumValueDepth { return value }
        if max(depth, validator.schemaDepth) > schemaLargeStackThreshold {
            return schemaOnLargeStack { self.coerceUnchecked(value) } ?? value
        }
        return coerceUnchecked(value)
    }

    private func coerceUnchecked(_ value: SchemaValue) -> SchemaValue {
        let source = coercer.withLock { cached -> Coercer in
            if let cached { return cached }
            let created = Coercer(c: validator.compiler, schema: validator.compiler.schema)
            cached = created
            return created
        }
        return validator.withCoercionGate { source.coerceUnchecked(value) }
    }

    // validator.ts:84
    /// Coerces and validates a value, returning the value or ordered issues.
    public func parse(_ value: SchemaValue) -> SchemaParseResult {
        let depth = schemaNestingDepth(value, stoppingAt: schemaMaximumValueDepth)
        if depth > schemaMaximumValueDepth { return .failed([schemaValueTooDeepIssue]) }
        if max(depth, validator.schemaDepth) > schemaLargeStackThreshold {
            return schemaOnLargeStack { self.parseUnchecked(value) } ?? .failed([schemaValueTooDeepIssue])
        }
        return parseUnchecked(value)
    }

    private func parseUnchecked(_ value: SchemaValue) -> SchemaParseResult {
        validator.validateUnchecked(coerceUnchecked(value))
    }
}

/// Compiles a schema into a validator.
public func compile(_ schema: SchemaValue, options: CompileOptions = .init()) throws -> Validator {
    let depth = schemaNestingDepth(schema, stoppingAt: schemaMaximumSchemaDepth)
    if depth > schemaMaximumSchemaDepth { throw SchemaCompileError.nestedTooDeep }
    let result: (Compiler, Check)
    if depth > schemaLargeStackThreshold {
        guard let completed = schemaOnLargeStack({ Result { try compileCheck(schema, options: options) } }) else {
            throw SchemaCompileError.nestedTooDeep
        }
        result = try completed.get()
    } else {
        result = try compileCheck(schema, options: options)
    }
    let (compiled, check) = result
    return Validator(compiler: compiled, check: check)
}

/// Compiles a schema with coercion enabled. Plain `compile` always returns a `Validator`.
public func compileCoercing(_ schema: SchemaValue, options: CompileOptions = .init()) throws -> CoercingValidator {
    var enabled = options
    enabled.coerce = true
    return CoercingValidator(validator: try compile(schema, options: enabled))
}

// validator.ts:90
private func compileCheck(_ schema: SchemaValue, options: CompileOptions) throws -> (Compiler, Check) {
    let result = try compiler(schema, options: options)
    return (result, try result.root())
}

// validator.ts:94
private func compiler(_ schema: SchemaValue, options: CompileOptions) throws -> Compiler {
    let plain = Compiler(schema, options: options, dynamic: false)
    do {
        _ = try plain.root()
        return plain
    } catch CompilerRestart.restart {
        return Compiler(schema, options: options, dynamic: true)
    }
}
