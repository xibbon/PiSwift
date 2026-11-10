// Ported from packages/schema/src/validator.ts, pi-mono v1.5.2.
import Synchronization

private final class DynamicCheckGate: Sendable {
    private let mutex = Mutex<Void>(())
    func run(_ check: Check, _ value: SchemaValue) -> Bool {
        mutex.withLock { _ in check(value) }
    }
}

/// A compiled schema whose check is safe to call from concurrent tasks.
public final class Validator: Sendable {
    let compiler: Compiler
    private let checkFunction: Check
    private let dynamicGate: DynamicCheckGate?

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
