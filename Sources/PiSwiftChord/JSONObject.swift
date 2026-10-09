/// Ordered JSON members. Ports chord object keys and `delta/tracker.ts` key order.
public struct JSONObject: Sendable, Equatable, ExpressibleByDictionaryLiteral, Sequence {
    private struct ScalarKey: Sendable, Hashable {
        let text: String
        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.text.unicodeScalars.elementsEqual(rhs.text.unicodeScalars)
        }
        func hash(into hasher: inout Hasher) {
            for byte in text.utf8 { hasher.combine(byte) }
        }
    }
    private var order: [ScalarKey] = []
    private var members: [ScalarKey: JSONValue] = [:]

    /// Creates an empty object.
    public init() {}

    /// Creates members in pair order. A duplicate replaces its first value.
    public init(_ pairs: [(String, JSONValue)]) {
        for (key, value) in pairs { self[key] = value }
    }

    /// Creates members in literal order, then applies the JavaScript key rule.
    public init(dictionaryLiteral elements: (String, JSONValue)...) { self.init(elements) }

    /// Gets or sets a member. Assign `nil` to remove it; use `.null` for JSON null.
    public subscript(key: String) -> JSONValue? {
        get { members[ScalarKey(text: key)] }
        set {
            let identity = ScalarKey(text: key)
            if let newValue {
                if members[identity] == nil { order.append(identity) }
                members[identity] = newValue
            } else { removeValue(forKey: key) }
        }
    }

    private var orderedKeys: [ScalarKey] {
        let indices = order.compactMap { key in Self.arrayIndex(key.text).map { (key, $0) } }
        return indices.sorted { $0.1 < $1.1 }.map(\.0) + order.filter { Self.arrayIndex($0.text) == nil }
    }

    private static func arrayIndex(_ text: String) -> UInt64? {
        let bytes = Array(text.utf8)
        guard !bytes.isEmpty, bytes.count <= 10 else { return nil }
        if bytes == [48] { return 0 }
        guard (49...57).contains(bytes[0]) else { return nil }
        var result: UInt64 = 0
        for byte in bytes {
            guard (48...57).contains(byte) else { return nil }
            result = result * 10 + UInt64(byte - 48)
        }
        return result < 4_294_967_295 ? result : nil
    }

    /// The keys in JavaScript property order.
    public var keys: [String] { orderedKeys.map(\.text) }
    /// The values in JavaScript property order.
    public var values: [JSONValue] { orderedKeys.compactMap { members[$0] } }
    /// The number of members.
    public var count: Int { members.count }
    /// Returns true when there are no members.
    public var isEmpty: Bool { members.isEmpty }
    /// Tests key identity by Unicode scalars.
    public func contains(_ key: String) -> Bool { members[ScalarKey(text: key)] != nil }
    /// Removes a member and returns its previous value.
    @discardableResult public mutating func removeValue(forKey key: String) -> JSONValue? {
        let identity = ScalarKey(text: key)
        guard let value = members.removeValue(forKey: identity) else { return nil }
        order.removeAll { $0 == identity }
        return value
    }
    /// Compares members without regard to key order.
    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.members == rhs.members }
    /// Iterates over members in JavaScript property order.
    public func makeIterator() -> IndexingIterator<[(key: String, value: JSONValue)]> {
        orderedKeys.compactMap { key in members[key].map { (key: key.text, value: $0) } }.makeIterator()
    }
    /// Writes compact JSON in JavaScript property order.
    public func jsonText() throws -> String { try JSONValue.object(self).jsonText() }
}
