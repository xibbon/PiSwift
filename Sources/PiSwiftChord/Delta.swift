/// Decoded JSON operations. Port of chord `delta/index.ts`, v1.1.0.
public enum Delta {
    /// An object key or a non-negative array index.
    public enum PathSegment: Sendable, Hashable, ExpressibleByStringLiteral, ExpressibleByIntegerLiteral {
        case key(String)
        case index(Int)

        public init(stringLiteral value: String) { self = .key(value) }
        public init(integerLiteral value: Int) { self = .index(value) }

        public static func == (lhs: Self, rhs: Self) -> Bool {
            switch (lhs, rhs) {
            case let (.key(a), .key(b)): a.utf16.elementsEqual(b.utf16)
            case let (.index(a), .index(b)): a == b
            default: false
            }
        }
        public func hash(into hasher: inout Hasher) {
            switch self {
            case .key(let key):
                hasher.combine(0)
                for unit in key.utf16 { hasher.combine(unit) }
            case .index(let index): hasher.combine(1); hasher.combine(index)
            }
        }
        var json: JSONValue {
            switch self {
            case .key(let key): .string(key)
            case .index(let index): .number(Double(index))
            }
        }
        var propertyKey: String {
            switch self {
            case .key(let key): key
            case .index(let index): JSONValue.number(Double(index)).description
            }
        }
    }

    public typealias Path = [PathSegment]

    /// Operations use the upstream JSON tuple form at storage boundaries.
    public enum Op: Sendable, Equatable, Codable {
        case replace(JSONValue)
        case set(Path, JSONValue)
        case delete(Path)
        case append(Path, String)
        case trim(Path, Int)
        case splice(Path, index: Int, remove: Int, items: [JSONValue])
        case move(Path, permutation: [Int])

        public var json: JSONValue {
            switch self {
            case .replace(let value): ["r", value]
            case .set(let path, let value): ["s", .array(path.map(\.json)), value]
            case .delete(let path): ["d", .array(path.map(\.json))]
            case .append(let path, let text): ["a", .array(path.map(\.json)), .string(text)]
            case .trim(let path, let count): ["t", .array(path.map(\.json)), .number(Double(count))]
            case .splice(let path, let index, let remove, let items):
                ["p", .array(path.map(\.json)), .number(Double(index)), .number(Double(remove)), .array(items)]
            case .move(let path, let permutation):
                ["m", .array(path.map(\.json)), .array(permutation.map { .number(Double($0)) })]
            }
        }

        /// Validates tuple shape and path safety, without walking payload values.
        public init(json: JSONValue) throws {
            guard case .array(let tuple) = json, !tuple.isEmpty else {
                throw DeltaError.invalidOperation("op is not a tuple")
            }
            func arity(_ count: Int, _ text: String) throws {
                guard tuple.count == count else { throw DeltaError.invalidOperation(text) }
            }
            func path(_ nonEmpty: Bool = false) throws -> Path {
                guard case .array(let segments) = tuple[1] else {
                    throw DeltaError.invalidOperation("path is not an array")
                }
                if nonEmpty && segments.isEmpty { throw DeltaError.invalidOperation("path is empty") }
                return try segments.map { segment in
                    let result: PathSegment
                    switch segment {
                    case .string(let key): result = .key(key)
                    case .number(let number):
                        guard let index = Int(exactly: number) else {
                            throw DeltaError.unsafeSegment(.key(try Delta.jsString(segment)))
                        }
                        result = .index(index)
                    default: throw DeltaError.unsafeSegment(.key(try Delta.jsString(segment)))
                    }
                    try Delta.assertSafePath([result])
                    return result
                }
            }
            switch tuple[0].stringValue {
            case "r": try arity(2, "r arity"); self = .replace(tuple[1])
            case "s": try arity(3, "s arity"); self = .set(try path(true), tuple[2])
            case "d": try arity(2, "d arity"); self = .delete(try path(true))
            case "a":
                guard tuple.count == 3, let text = tuple[2].stringValue else {
                    throw DeltaError.invalidOperation("a shape")
                }
                self = .append(try path(true), text)
            case "t":
                guard tuple.count == 3, let count = tuple[2].intValue, count >= 0 else {
                    throw DeltaError.invalidOperation("t shape")
                }
                self = .trim(try path(true), count)
            case "p":
                try arity(5, "p arity")
                let path = try path()
                guard let index = tuple[2].intValue, index >= 0 else { throw DeltaError.invalidOperation("p index") }
                guard let remove = tuple[3].intValue, remove >= 0 else { throw DeltaError.invalidOperation("p remove") }
                guard let items = tuple[4].arrayValue else { throw DeltaError.invalidOperation("p items") }
                self = .splice(path, index: index, remove: remove, items: items)
            case "m":
                try arity(3, "m arity")
                let path = try path()
                guard let values = tuple[2].arrayValue else { throw DeltaError.invalidOperation("m permutation is not an array") }
                let permutation = try values.map { value in
                    guard let index = value.intValue else { throw DeltaError.invalidOperation("m permutation is not a bijection") }
                    return index
                }
                try Delta.assertPermutation(permutation)
                self = .move(path, permutation: permutation)
            default: throw DeltaError.invalidOperation("unknown op verb: \(try Delta.jsString(tuple[0]))")
            }
        }

        public init(from decoder: any Decoder) throws { try self.init(json: JSONValue(from: decoder)) }
        public func encode(to encoder: any Encoder) throws {
            try validate()
            try json.encode(to: encoder)
        }

        public static func == (lhs: Self, rhs: Self) -> Bool {
            switch (lhs, rhs) {
            case let (.replace(a), .replace(b)): a == b
            case let (.set(ap, a), .set(bp, b)): ap == bp && a == b
            case let (.delete(a), .delete(b)): a == b
            case let (.append(ap, a), .append(bp, b)): ap == bp && a.utf16.elementsEqual(b.utf16)
            case let (.trim(ap, a), .trim(bp, b)): ap == bp && a == b
            case let (.splice(ap, ai, ar, av), .splice(bp, bi, br, bv)):
                ap == bp && ai == bi && ar == br && av == bv
            case let (.move(ap, a), .move(bp, b)): ap == bp && a == b
            default: false
            }
        }

        var path: Path {
            switch self {
            case .replace: []
            case .set(let path, _), .append(let path, _), .trim(let path, _),
                 .splice(let path, _, _, _), .move(let path, _), .delete(let path): path
            }
        }
        var containerPath: Path {
            switch self {
            case .replace: []
            case .splice, .move: path
            default: Array(path.dropLast())
            }
        }
        func validate() throws {
            switch self {
            case .replace: return
            case .set, .delete, .append:
                if path.isEmpty { throw DeltaError.invalidOperation("path is empty") }
                try Delta.assertSafePath(path)
            case .trim(_, let count):
                if count < 0 || Double(exactly: count) == nil { throw DeltaError.invalidOperation("t shape") }
                if path.isEmpty { throw DeltaError.invalidOperation("path is empty") }
                try Delta.assertSafePath(path)
            case .splice(_, let index, let remove, _):
                try Delta.assertSafePath(path)
                if index < 0 || Double(exactly: index) == nil { throw DeltaError.invalidOperation("p index") }
                if remove < 0 || Double(exactly: remove) == nil { throw DeltaError.invalidOperation("p remove") }
            case .move(_, let permutation):
                try Delta.assertSafePath(path)
                try Delta.assertPermutation(permutation)
            }
        }
    }

    /// Keys that upstream rejects to protect the JavaScript prototype chain.
    public static let reservedSegments: Set<String> = ["__proto__", "constructor", "prototype"]

    public static func assertSafePath(_ path: Path) throws {
        for segment in path {
            switch segment {
            case .key(let key): if reservedSegments.contains(key) { throw DeltaError.unsafeSegment(segment) }
            case .index(let index):
                if index < 0 || Double(exactly: index) == nil { throw DeltaError.unsafeSegment(segment) }
            }
        }
    }

    private static func assertPermutation(_ permutation: [Int]) throws {
        var seen = [Bool](repeating: false, count: permutation.count)
        for index in permutation {
            guard seen.indices.contains(index), !seen[index] else {
                throw DeltaError.invalidOperation("m permutation is not a bijection")
            }
            seen[index] = true
        }
    }

    // String(value) for invalid JSON tuple fields. Values need not be strict JSON.
    private static func jsString(_ value: JSONValue) throws -> String {
        switch value {
        case .string(let string): return string
        case .object(let object):
            // JSON cannot supply a callable own toString. Such a member hides
            // Object.prototype.toString, and String(value) then throws.
            if object.contains("toString") {
                throw DeltaError.invalidOperation("Cannot convert object to primitive value")
            }
            return "[object Object]"
        case .array(let array): return try array.map { $0.isNull ? "" : try jsString($0) }.joined(separator: ",")
        default: return value.description
        }
    }
}

/// Errors use the upstream decoded-operation texts.
public enum DeltaError: Error, Sendable, Equatable, CustomStringConvertible {
    case unresolvablePath(Delta.Path)
    case unsafeSegment(Delta.PathSegment)
    case invalidOperation(String)

    public var description: String {
        switch self {
        case .unresolvablePath(let path): "unresolvable path: \(JSONValue.array(path.map(\.json)))"
        case .unsafeSegment(let segment): "unsafe path segment: \(segment.propertyKey)"
        case .invalidOperation(let text): text
        }
    }
}
