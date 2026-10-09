extension Delta {
    /// Applies each operation in order. On error, earlier operations remain applied.
    public static func apply(_ ops: [Op], to value: inout JSONValue?) throws {
        for op in ops {
            try op.validate()
            try applyValidated(op, to: &value)
        }
    }

    /// Applies a batch to a copy. The input and operation payloads remain unchanged.
    public static func applyImmutable(_ value: JSONValue?, _ ops: [Op]) throws -> JSONValue? {
        try applyImmutableBatches(value, [ops])
    }

    /// Replays batches in one copy-on-write scope and returns only the final result.
    public static func applyImmutableBatches(_ value: JSONValue?, _ batches: some Sequence<[Op]>) throws -> JSONValue? {
        var result = value
        for ops in batches {
            for op in ops {
                try op.validate()
                if case .replace = op {
                    try applyValidated(op, to: &result)
                    continue
                }
                // Upstream copyContainers tests own membership before array key type.
                // Keep its error order, then use Swift copy-on-write for ownership.
                try checkImmutableContainers(result, path: op.containerPath)
                try applyValidated(op, to: &result)
            }
        }
        return result
    }

    private static func applyValidated(_ op: Op, to value: inout JSONValue?) throws {
        if case .replace(let replacement) = op { value = replacement; return }
        let path = op.path
        let containerPath = op.containerPath
        guard value != nil else { throw DeltaError.unresolvablePath(containerPath) }
        try withContainer(&value!, path: containerPath) { container in
            switch op {
            case .splice(_, let index, let remove, let items):
                guard let _: Void = container.withArray({ array in
                    let start = min(index, array.count)
                    let end = start + min(remove, array.count - start)
                    array.replaceSubrange(start..<end, with: items)
                }) else { throw DeltaError.unresolvablePath(path) }
            case .move(_, let permutation):
                guard let _: Void = try container.withArray({ array in
                    guard array.count == permutation.count else { throw DeltaError.unresolvablePath(path) }
                    let previous = array
                    for index in permutation.indices { array[index] = previous[permutation[index]] }
                }) else { throw DeltaError.unresolvablePath(path) }
            default:
                let key = path[path.count - 1]
                if container.isArray {
                    guard case .index(let index) = key else { throw DeltaError.unsafeSegment(key) }
                    _ = try container.withArray { array in
                        // Source checks this for every member verb, including delete.
                        if index > array.count { throw DeltaError.unsafeSegment(key) }
                        switch op {
                        case .set(_, let newValue):
                            if index == array.count { array.append(newValue) }
                            else { array[index] = newValue }
                        case .delete:
                            guard index < array.count else { throw DeltaError.unresolvablePath(path) }
                            array.remove(at: index)
                        default:
                            guard index < array.count else { throw DeltaError.unresolvablePath(path) }
                            try applyString(op, to: &array[index])
                        }
                    }
                } else if container.isObject {
                    _ = try container.withObject { object in
                        let key = key.propertyKey
                        switch op {
                        case .set(_, let newValue): object[key] = newValue
                        case .delete: object.removeValue(forKey: key)
                        default:
                            guard let _: Void = try object.withValue(forKey: key, { member in
                                try applyString(op, to: &member)
                            }) else { throw DeltaError.unresolvablePath(path) }
                        }
                    }
                } else { throw DeltaError.unresolvablePath(containerPath) }
            }
        }
    }

    private static func applyString(_ op: Op, to value: inout JSONValue) throws {
        guard case .string(let string) = value else { throw DeltaError.unresolvablePath(op.path) }
        switch op {
        case .append(_, let text): value = .string(string + text)
        case .trim(_, let count):
            let units = Array(string.utf16)
            let start = min(count, units.count)
            if start > 0 && start < units.count && (0xD800...0xDBFF).contains(units[start - 1])
                && (0xDC00...0xDFFF).contains(units[start]) {
                throw DeltaError.invalidOperation("t splits a surrogate pair")
            }
            value = .string(String(decoding: units[start...], as: UTF16.self))
        default: preconditionFailure("Expected a string operation")
        }
    }

    private struct ContainerParent {
        var value: JSONValue
        let segment: PathSegment
    }

    // Take each child out before descent. This keeps owned storage unique.
    // Restore the parent stack on both success and failure.
    private static func withContainer(
        _ node: inout JSONValue, path: Path,
        _ body: (inout JSONValue) throws -> Void
    ) throws {
        var current = node
        node = .null
        var parents: [ContainerParent] = []
        defer {
            while !parents.isEmpty {
                let segment = parents.last!.segment
                var parent = parents.removeLast().value
                if parent.isArray {
                    if case .index(let index) = segment {
                        _ = parent.withArray { $0[index] = current }
                    }
                } else {
                    _ = parent.withObject { $0[segment.propertyKey] = current }
                }
                current = parent
            }
            node = current
        }
        for segment in path {
            if current.isArray {
                guard case .index(let index) = segment else { throw DeltaError.unsafeSegment(segment) }
                let child = try current.withArray { array in
                    guard array.indices.contains(index) else { throw DeltaError.unresolvablePath(path) }
                    let child = array[index]
                    array[index] = .null
                    return child
                }!
                parents.append(ContainerParent(value: current, segment: segment))
                current = child
            } else if current.isObject {
                let child = try current.withObject { object in
                    guard let child = object[segment.propertyKey] else { throw DeltaError.unresolvablePath(path) }
                    object[segment.propertyKey] = .null
                    return child
                }!
                parents.append(ContainerParent(value: current, segment: segment))
                current = child
            } else { throw DeltaError.unresolvablePath(path) }
        }
        guard current.isContainer else { throw DeltaError.unresolvablePath(path) }
        try body(&current)
    }

    private static func checkImmutableContainers(_ root: JSONValue?, path: Path) throws {
        guard var node = root, node.isContainer else { throw DeltaError.unresolvablePath(path) }
        for segment in path {
            switch node {
            case .array(let array):
                switch segment {
                case .index(let index):
                    guard array.indices.contains(index) else { throw DeltaError.unresolvablePath(path) }
                    node = array[index]
                case .key(let key):
                    let isElement = Int(key).map { $0 >= 0 && $0 < array.count && String($0) == key } ?? false
                    if key == "length" || isElement { throw DeltaError.unsafeSegment(segment) }
                    throw DeltaError.unresolvablePath(path)
                }
            case .object(let object):
                guard let child = object[segment.propertyKey] else { throw DeltaError.unresolvablePath(path) }
                node = child
            default: throw DeltaError.unresolvablePath(path)
            }
            guard node.isContainer else { throw DeltaError.unresolvablePath(path) }
        }
    }
}

private extension JSONValue {
    var isArray: Bool { if case .array = self { true } else { false } }
    var isObject: Bool { if case .object = self { true } else { false } }
    var isContainer: Bool {
        switch self {
        case .array, .object: true
        default: false
        }
    }
}
