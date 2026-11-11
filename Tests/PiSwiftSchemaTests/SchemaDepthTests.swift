import Foundation
import Synchronization
import Testing
@testable import PiSwiftSchema

// Run each probe on the smallest stack that a Swift concurrency worker can have.
// Source guards must reject recursive work before it can exhaust this stack.
private func onSmallStack(_ body: @escaping @Sendable () -> [String]) -> [String] {
    let answer = Mutex<[String]?>(nil)
    let done = DispatchSemaphore(value: 0)
    let worker = Thread {
        let failures = body()
        answer.withLock { $0 = failures }
        done.signal()
    }
    worker.stackSize = 512 * 1024
    worker.start()
    done.wait()
    return answer.withLock { $0 ?? ["512 KB worker did not return a result"] }
}

private enum Nesting: String, Sendable, CaseIterable { case array, object }

private func levels(_ depth: Int, _ kind: Nesting) -> [SchemaValue] {
    var values: [SchemaValue] = [.null]
    values.reserveCapacity(depth + 1)
    for _ in 0..<depth {
        let child = values.last ?? .null
        values.append(kind == .array ? .array([child]) : .object(["x": child]))
    }
    return values
}

private func clearLevels(_ values: inout [SchemaValue]) {
    // Release the root before each child. This also prevents recursive ARC teardown
    // from consuming the worker stack after the probe has finished.
    while !values.isEmpty { values.removeLast() }
}

private func retainAndClear(_ root: inout SchemaValue) {
    var nodes: [SchemaValue] = []
    var cursor = root
    while true {
        nodes.append(cursor)
        switch cursor {
        case .array(let children):
            guard let child = children.first else { cursor = .null; break }
            cursor = child
        case .object(let object):
            guard let child = object["x"] else { cursor = .null; break }
            cursor = child
        default: cursor = .null
        }
        if cursor == .null { break }
    }
    cursor = .null
    root = .null
    nodes.reverse() // `nodes` was collected root-to-leaf; pop roots first.
    clearLevels(&nodes)
}

private func expectedText(_ depth: Int, _ kind: Nesting) -> String {
    switch kind {
    case .array: return String(repeating: "[", count: depth) + "null" + String(repeating: "]", count: depth)
    case .object: return String(repeating: "{\"x\":", count: depth) + "null" + String(repeating: "}", count: depth)
    }
}

@Test(arguments: [512, 513], Nesting.allCases)
private func emptyContainerJSONBoundaryOnSmallStack(depth: Int, kind: Nesting) {
    let failures = onSmallStack {
        let text: String
        switch kind {
        case .array: text = String(repeating: "[", count: depth) + String(repeating: "]", count: depth)
        case .object: text = String(repeating: "{\"x\":", count: depth - 1) + "{}" + String(repeating: "}", count: depth - 1)
        }
        do {
            _ = try SchemaValue.parse(json: text)
            return depth <= schemaMaximumValueDepth ? [] : ["accepted empty container at depth \(depth)"]
        } catch SchemaJSONError.nestingTooDeep {
            return depth > schemaMaximumValueDepth ? [] : ["rejected empty container at depth \(depth)"]
        } catch {
            return ["unexpected parse error at depth \(depth): \(error)"]
        }
    }
    #expect(failures.isEmpty, "\(failures.joined(separator: "; "))")
}

private let tooDeepIssue = SchemaIssue(path: "", keyword: "schema", message: "value is nested too deeply")

@Test(arguments: [24, 100, 512, 5_000, 100_000], Nesting.allCases)
private func valueDepthOnSmallStack(depth: Int, kind: Nesting) {
    let failures = onSmallStack {
        var issues: [String] = []
        var retained = levels(depth, kind)
        var value = retained.last ?? .null
        let text = expectedText(depth, kind)
        if value.stringify() != text { issues.append("stringify at depth \(depth)") }
        if value != value { issues.append("== at depth \(depth)") }
        if !schemaEqual(value, value) { issues.append("schemaEqual at depth \(depth)") }
        do {
            let type = kind == .array ? "array" : "object"
            let schema: SchemaValue = .object(["type": .string(type)])
            let plain = try compile(schema)
            let coercing = try compileCoercing(schema)
            let allowed = depth <= schemaMaximumValueDepth
            if plain.check(value) != allowed { issues.append("check at depth \(depth)") }
            if coercing.check(value) != allowed { issues.append("coercing check at depth \(depth)") }
            let expectedErrors = allowed ? [] : [tooDeepIssue]
            if plain.errors(value) != expectedErrors { issues.append("errors at depth \(depth)") }
            switch plain.validate(value) {
            case .ok(let next): if !allowed || next != value { issues.append("validate result at depth \(depth)") }
            case .failed(let errors): if allowed || errors != expectedErrors { issues.append("validate issues at depth \(depth)") }
            }
            let coerced = coercing.coerce(value)
            if coerced != value { issues.append("coerce at depth \(depth)") }
            switch coercing.parse(value) {
            case .ok(let next): if !allowed || next != value { issues.append("parse result at depth \(depth)") }
            case .failed(let errors): if allowed || errors != expectedErrors { issues.append("parse issues at depth \(depth)") }
            }
        } catch { issues.append("compile failed for simple schema: \(error)") }
        value = .null
        clearLevels(&retained)
        return issues
    }
    #expect(failures.isEmpty, "\(kind.rawValue) depth \(depth): \(failures.joined(separator: "; "))")
}

@Test(arguments: [24, 100, 512, 5_000, 100_000], Nesting.allCases)
private func jsonDepthOnSmallStack(depth: Int, kind: Nesting) {
    let failures = onSmallStack {
        var failures: [String] = []
        let text = expectedText(depth, kind)
        do {
            var value = try SchemaValue.parse(json: text)
            if depth > schemaMaximumValueDepth { failures.append("parse accepted depth \(depth)") }
            else if value.stringify() != text { failures.append("parse text at depth \(depth)") }
            retainAndClear(&value)
        } catch SchemaJSONError.nestingTooDeep {
            if depth <= schemaMaximumValueDepth { failures.append("parse rejected allowed depth \(depth)") }
        } catch { failures.append("parse unexpected error at depth \(depth): \(error)") }
        return failures
    }
    #expect(failures.isEmpty, "JSON \(kind.rawValue) depth \(depth): \(failures.joined(separator: "; "))")
}

@Test(arguments: [24, 100, 512, 5_000, 100_000], Nesting.allCases)
private func foundationDepthOnSmallStack(depth: Int, kind: Nesting) {
    let failures = onSmallStack {
        var failures: [String] = []
        var source: Any = NSNull()
        var retained: [Any] = [source]
        retained.reserveCapacity(depth + 1)
        for _ in 0..<depth {
            source = kind == .array ? [source] : ["x": source]
            retained.append(source)
        }
        do {
            var result = try SchemaValue(jsonObject: source)
            if result.stringify() != expectedText(depth, kind) { failures.append("Foundation text at depth \(depth)") }
            retainAndClear(&result)
        } catch { failures.append("Foundation init failed at depth \(depth): \(error)") }
        source = NSNull()
        while !retained.isEmpty { retained.removeLast() }
        return failures
    }
    #expect(failures.isEmpty, "Foundation \(kind.rawValue) depth \(depth): \(failures.joined(separator: "; "))")
}

private func schemaLevels(_ depth: Int) -> [SchemaValue] {
    var values: [SchemaValue] = [.bool(true)]
    values.reserveCapacity(depth + 1)
    for _ in 0..<depth { values.append(.object(["anyOf": .array([values.last ?? .bool(true)])])) }
    return values
}

@Test(arguments: [100, 512, 5_000])
private func schemaDepthOnSmallStack(depth: Int) {
    let failures = onSmallStack {
        var failures: [String] = []
        var retained = schemaLevels(depth)
        var schema = retained.last ?? .bool(true)
        let allowed = schemaNestingDepth(schema, stoppingAt: schemaMaximumSchemaDepth) <= schemaMaximumSchemaDepth
        do {
            let validator = try compile(schema)
            if !allowed { failures.append("compile accepted schema with \(depth) anyOf wrappers") }
            else if !validator.check(.null) { failures.append("compiled schema rejected null at depth \(depth)") }
        } catch SchemaCompileError.nestedTooDeep {
            if allowed { failures.append("compile rejected allowed schema with \(depth) anyOf wrappers") }
        } catch { failures.append("unexpected compile error at depth \(depth): \(error)") }
        schema = .null
        clearLevels(&retained)
        return failures
    }
    #expect(failures.isEmpty, "schema depth \(depth): \(failures.joined(separator: "; "))")
}

@Test(arguments: [24, 100, 512, 5_000])
private func recursiveReferenceOnSmallStack(depth: Int) {
    let failures = onSmallStack {
        var failures: [String] = []
        let schema: SchemaValue = .object([
            "$id": .string("https://example.test/depth.json"),
            "anyOf": .array([.object(["type": .string("null")]),
                              .object(["type": .string("array"), "items": .object(["$ref": .string("#")])])])
        ])
        var retained = levels(depth, .array)
        var value = retained.last ?? .null
        do {
            let validator = try compileCoercing(schema)
            let allowed = depth <= schemaMaximumValueDepth
            if validator.check(value) != allowed { failures.append("recursive check at depth \(depth)") }
            if !allowed {
                if validator.errors(value) != [tooDeepIssue] { failures.append("recursive errors at depth \(depth)") }
                if validator.coerce(value) != value { failures.append("recursive coerce at depth \(depth)") }
                if case let .failed(errors) = validator.parse(value) {
                    if errors != [tooDeepIssue] { failures.append("recursive parse issues at depth \(depth)") }
                } else { failures.append("recursive parse accepted depth \(depth)") }
            }
        } catch { failures.append("recursive schema compile failed: \(error)") }
        value = .null
        clearLevels(&retained)
        return failures
    }
    #expect(failures.isEmpty, "recursive depth \(depth): \(failures.joined(separator: "; "))")
}
