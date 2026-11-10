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
}

/// A compiled schema whose check is safe to call from concurrent tasks.
public final class Validator: Sendable {
    let compiler: Compiler
    private let checkFunction: Check
    private let dynamicGate: DynamicCheckGate?
    private let explainer = Mutex<Explainer?>(nil)

    init(compiler: Compiler, check: @escaping Check) {
        self.compiler = compiler
        self.checkFunction = check
        self.dynamicGate = compiler.dynamic ? DynamicCheckGate() : nil
    }

    /// Returns whether value passes this schema.
    public func check(_ value: SchemaValue) -> Bool {
        if let dynamicGate { return dynamicGate.run(checkFunction, value) }
        return checkFunction(value)
    }

    /// Returns ordered issues for a failed value, or an empty array for a valid value.
    public func errors(_ value: SchemaValue) -> [SchemaIssue] {
        if check(value) { return [] }
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
        if check(value) { return .ok(value) }
        return .failed(errors(value))
    }
}

/// Compiles a schema into a validator.
public func compile(_ schema: SchemaValue, options: CompileOptions = .init()) throws -> Validator {
    let (compiled, check) = try compileCheck(schema, options: options)
    return Validator(compiler: compiled, check: check)
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
