import Foundation
import Testing
import PiSwiftChord

@Suite struct DeltaDeepPathTests {
    private static func assertWorkerThread() { #expect(!Thread.isMainThread) }

    // Member operations add one segment to this container path.
    private static func parentPath(mixedArrays: Bool) -> Delta.Path {
        (0..<1_999).map { depth in
            if mixedArrays && depth.isMultiple(of: 2) { return .index(0) }
            return depth.isMultiple(of: 3) ? .key("child") : .index(7)
        }
    }

    private static func tree(path: Delta.Path, leaf: JSONValue, mixedArrays: Bool) -> JSONValue {
        var node = leaf
        for depth in path.indices.reversed() {
            if mixedArrays && depth.isMultiple(of: 2) {
                node = .array([node])
            } else {
                let key: String
                switch path[depth] {
                case .key(let value): key = value
                case .index(let value): key = String(value)
                }
                node = .object(JSONObject([(key, node)]))
            }
        }
        return node
    }

    private static func child(_ node: JSONValue, at segment: Delta.PathSegment) -> JSONValue? {
        switch (node, segment) {
        case (.array(let values), .index(let index)):
            return values.indices.contains(index) ? values[index] : nil
        case (.object(let object), .key(let key)): return object[key]
        case (.object(let object), .index(let index)): return object[String(index)]
        default: return nil
        }
    }

    private static func leaf(_ root: JSONValue?, path: Delta.Path) throws -> JSONValue {
        var node = try #require(root)
        for segment in path { node = try #require(child(node, at: segment)) }
        return node
    }

    // Retain descendants before releasing ancestors. This tests the path walk
    // without also requiring JSONValue to destroy a deep tree recursively.
    private static func release(_ root: inout JSONValue?, path: Delta.Path) {
        guard var node = root else { return }
        var retained = [node]
        for segment in path {
            guard let next = child(node, at: segment) else { break }
            retained.append(next)
            node = next
        }
        node = .null
        root = nil
        for index in retained.indices { retained[index] = .null }
    }

    @Test(arguments: [false, true])
    func appliesTwoThousandSegmentPathsInTask(mixedArrays: Bool) async throws {
        try await Task.detached {
            Self.assertWorkerThread()
            let path = Self.parentPath(mixedArrays: mixedArrays)
            let originalLeaf: JSONValue = ["set": 0, "remove": true, "text": "a", "values": [1, 2]]
            let payload: JSONValue = ["score": 5]
            let inserted: JSONValue = ["id": 3]
            let ops: [Delta.Op] = [
                .set(path + ["set"], payload),
                .delete(path + ["remove"]),
                .append(path + ["text"], "😀"),
                .splice(path + ["values"], index: 1, remove: 1, items: [inserted, 4]),
                .set(path + ["set", "score"], 9),
                .set(path + ["values", 1, "id"], 30)
            ]
            var base: JSONValue? = Self.tree(path: path, leaf: originalLeaf, mixedArrays: mixedArrays)
            var mutable = base
            var immutable: JSONValue?
            var batched: JSONValue?
            defer {
                Self.release(&mutable, path: path)
                Self.release(&immutable, path: path)
                Self.release(&batched, path: path)
                Self.release(&base, path: path)
            }

            try Delta.apply(ops, to: &mutable)
            immutable = try Delta.applyImmutable(base, ops)
            batched = try Delta.applyImmutableBatches(base, [Array(ops.prefix(2)), [], Array(ops.dropFirst(2))])
            let expected: JSONValue = ["set": ["score": 9], "text": "a😀", "values": [1, ["id": 30], 4]]
            #expect(try Self.leaf(mutable, path: path) == expected)
            #expect(try Self.leaf(immutable, path: path) == expected)
            #expect(try Self.leaf(batched, path: path) == expected)
            #expect(try Self.leaf(base, path: path) == originalLeaf)
            #expect(payload == ["score": 5])
            #expect(inserted == ["id": 3])
        }.value
    }

    @Test(arguments: [false, true])
    func deepFailuresKeepErrorOrderAndRestoreContainers(mixedArrays: Bool) async throws {
        try await Task.detached {
            Self.assertWorkerThread()
            let path = Self.parentPath(mixedArrays: mixedArrays)
            let originalLeaf: JSONValue = ["text": "a", "values": [["value": 1]], "scalar": 2]
            var base: JSONValue? = Self.tree(path: path, leaf: originalLeaf, mixedArrays: mixedArrays)
            var mutable = base
            defer {
                Self.release(&mutable, path: path)
                Self.release(&base, path: path)
            }

            let missingPath = path + ["values", "missing", "value"]
            let missing = Delta.Op.set(missingPath, 3)
            #expect(throws: DeltaError.unsafeSegment("missing")) {
                try Delta.apply([.append(path + ["text"], "b"), missing], to: &mutable)
            }
            #expect(try Self.leaf(mutable, path: path)["text"] == "ab")
            let missingContainer = Array(missingPath.dropLast())
            #expect(throws: DeltaError.unresolvablePath(missingContainer)) {
                try Delta.applyImmutable(base, [missing])
            }
            #expect(throws: DeltaError.unresolvablePath(missingContainer)) {
                try Delta.applyImmutableBatches(base, [[], [missing]])
            }

            let stringIndex = Delta.Op.set(path + ["values", "0", "value"], 3)
            #expect(throws: DeltaError.unsafeSegment("0")) { try Delta.apply([stringIndex], to: &mutable) }
            #expect(throws: DeltaError.unsafeSegment("0")) { try Delta.applyImmutable(base, [stringIndex]) }
            #expect(throws: DeltaError.unsafeSegment("0")) { try Delta.applyImmutableBatches(base, [[stringIndex]]) }

            // Validation checks the full path before a missing member is read.
            let reserved = Delta.Op.set(path + ["missing", "constructor"], 3)
            #expect(throws: DeltaError.unsafeSegment("constructor")) { try Delta.apply([reserved], to: &mutable) }
            #expect(throws: DeltaError.unsafeSegment("constructor")) { try Delta.applyImmutable(base, [reserved]) }
            #expect(throws: DeltaError.unsafeSegment("constructor")) { try Delta.applyImmutableBatches(base, [[reserved]]) }

            let primitivePath = path + ["scalar", "value"]
            let primitive = Delta.Op.set(primitivePath, 3)
            let primitiveContainer = Array(primitivePath.dropLast())
            #expect(throws: DeltaError.unresolvablePath(primitiveContainer)) { try Delta.apply([primitive], to: &mutable) }
            #expect(throws: DeltaError.unresolvablePath(primitiveContainer)) { try Delta.applyImmutable(base, [primitive]) }
            #expect(throws: DeltaError.unresolvablePath(primitiveContainer)) { try Delta.applyImmutableBatches(base, [[primitive]]) }

            try Delta.apply([.set(path + ["values", 0, "value"], 7)], to: &mutable)
            #expect(try Self.leaf(mutable, path: path) == ["text": "ab", "values": [["value": 7]], "scalar": 2])
            #expect(try Self.leaf(base, path: path) == originalLeaf)
        }.value
    }
}
