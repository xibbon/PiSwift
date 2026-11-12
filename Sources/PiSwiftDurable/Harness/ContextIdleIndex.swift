/// v1.5.2 D7 scheduler.ts:974-1023. Ordered idle periods with constant work
/// for a normal insertion, removal or unexpired deadline check.
internal struct ContextIdleIndex<ID: Hashable & Sendable>: Sendable {
    private struct Node: Sendable {
        var since: Int64
        var previous: ID?
        var next: ID?
    }
    private var nodes: [ID: Node] = [:]
    private var first: ID?
    private var last: ID?
    private var newest: Int64?
    private(set) var visited = 0

    var count: Int { nodes.count }
    var oldest: Int64? { first.flatMap { nodes[$0]?.since } }

    mutating func remove(_ id: ID) {
        guard let node = nodes.removeValue(forKey: id) else { return }
        if let previous = node.previous { nodes[previous]?.next = node.next } else { first = node.next }
        if let next = node.next { nodes[next]?.previous = node.previous } else { last = node.previous }
        newest = last.flatMap { nodes[$0]?.since }
    }

    mutating func mark(_ id: ID, since: Int64) {
        let previousNewest = newest
        remove(id)
        append(id, since: since)
        if let previousNewest, since < previousNewest { // The Session clock moved backwards.
            let sorted = nodes.map { ($0.key, $0.value.since) }.sorted { $0.1 < $1.1 }
            nodes.removeAll(keepingCapacity: true); first = nil; last = nil; self.newest = nil
            for (key, time) in sorted { append(key, since: time) }
        }
    }

    private mutating func append(_ id: ID, since: Int64) {
        nodes[id] = Node(since: since, previous: last, next: nil)
        if let last { nodes[last]?.next = id } else { first = id }
        last = id; newest = since
    }

    mutating func expire(now: Int64, retention: Int64) -> [ID] {
        var expired: [ID] = []
        while let id = first, let node = nodes[id] {
            visited += 1
            if retention > 0 && now - node.since < retention { break }
            expired.append(id)
            remove(id)
        }
        return expired
    }

    mutating func clear() { nodes.removeAll(); first = nil; last = nil; newest = nil }
}
