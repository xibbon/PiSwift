/// Idle documents in order of last use. Updates and removal have constant cost.
internal struct SessionDocumentIdleMap: Sendable {
    typealias Key = [UInt8]
    private struct Entry: Sendable {
        let since: Double
        var previous: Key?
        var next: Key?
    }
    private var entries: [Key: Entry] = [:]
    private var head: Key?
    private var tail: Key?
    var count: Int { entries.count }
    var first: (key: Key, since: Double)? {
        guard let head, let entry = entries[head] else { return nil }
        return (head, entry.since)
    }
    func since(_ key: Key) -> Double? { entries[key]?.since }
    mutating func touch(_ key: Key, at time: Double) {
        remove(key)
        let previous = tail
        // Concurrent readers can sample time before they acquire the cache lock.
        // Keep the times in list order when those readers finish in reverse order.
        let since = max(time, previous.flatMap { entries[$0]?.since } ?? time)
        entries[key] = Entry(since: since, previous: previous)
        if let previous { entries[previous]?.next = key } else { head = key }
        tail = key
    }
    mutating func remove(_ key: Key) {
        guard let entry = entries.removeValue(forKey: key) else { return }
        if let previous = entry.previous { entries[previous]?.next = entry.next } else { head = entry.next }
        if let next = entry.next { entries[next]?.previous = entry.previous } else { tail = entry.previous }
    }
    mutating func removeAll() { entries.removeAll(); head = nil; tail = nil }
}
