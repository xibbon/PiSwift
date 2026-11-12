import PiSwiftChord
import Synchronization

/// The newest visible entry and head marker for conversations owned by this Session.
internal final class SessionConversationTails: Sendable {
    private struct Lru<Value> {
        let capacity: Int
        var values: [ConversationID: (value: Value, used: UInt64)] = [:]
        var clock: UInt64 = 0
        var newest: ConversationID?
        init(_ capacity: Int) { self.capacity = capacity }
        var count: Int { values.count }
        mutating func get(_ id: ConversationID) -> Value? {
            guard var entry = values[id] else { return nil }
            if newest == id { return entry.value }
            clock &+= 1; entry.used = clock; values[id] = entry
            newest = id
            return entry.value
        }
        func peek(_ id: ConversationID) -> Value? { values[id]?.value }
        mutating func put(_ id: ConversationID, _ value: Value) {
            if newest == id, let previous = values[id] {
                values[id] = (value, previous.used)
                return
            }
            clock &+= 1; values[id] = (value, clock)
            newest = id
            if values.count > capacity, let oldest = values.min(by: { $0.value.used < $1.value.used })?.key {
                values.removeValue(forKey: oldest)
            }
        }
    }
    private struct State {
        // Double optionals distinguish an unknown conversation from a known empty one.
        var latest: Lru<EntryID?>
        var markers: Lru<EntryRecord?>
        init(latestCapacity: Int, markerCapacity: Int) {
            latest = Lru(latestCapacity); markers = Lru(markerCapacity)
        }
    }
    private let state: Mutex<State>
    init(latestCapacity: Int = 4096, markerCapacity: Int = 256) {
        state = Mutex(State(latestCapacity: max(1, min(latestCapacity, 4096)),
                            markerCapacity: max(1, min(markerCapacity, 256))))
    }
    var size: Int { state.withLock { $0.latest.count } }
    var markers: Int { state.withLock { $0.markers.count } }
    func peek(_ id: ConversationID) -> EntryID?? { state.withLock { $0.latest.peek(id) } }
    func latest(_ id: ConversationID, read: () async throws -> EntryID?) async throws -> EntryID? {
        if let known = state.withLock({ $0.latest.get(id) }) { return known }
        let value = try await read()
        state.withLock { $0.latest.put(id, value) }
        return value
    }
    func marker(_ id: ConversationID, atOrBefore cutoff: EntryID?,
                read: () async throws -> EntryRecord?) async throws -> EntryRecord? {
        let (known, latest) = state.withLock { s in (s.markers.get(id), s.latest.peek(id)) }
        if let known {
            if let marker = known {
                if cutoff == nil || cutoff! >= marker.id { return marker }
            } else { return nil }
        }
        let found = try await read()
        if cutoff == nil || (latest != nil && (latest! == nil || latest!! <= cutoff!)) {
            state.withLock { $0.markers.put(id, found) }
        }
        return found
    }
    func publishedEntry(_ value: EntryRecord) {
        state.withLock { s in
            s.latest.put(value.conversationId, value.id)
            if value.head != nil { s.markers.put(value.conversationId, value) }
        }
    }
    func apply(_ writes: [StorageWrite]) {
        state.withLock { s in
            for write in writes {
                switch write {
                case .conversation(let value, _) where value.parent == nil:
                    s.latest.put(value.id, nil); s.markers.put(value.id, nil)
                case .entry(let value, _):
                    s.latest.put(value.conversationId, value.id)
                    if value.head != nil { s.markers.put(value.conversationId, value) }
                default: break
                }
            }
        }
    }
}
