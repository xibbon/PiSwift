import Synchronization

/// Errors from the chord revision tracker.
public enum TrackerError: Error, Sendable, Equatable, CustomStringConvertible {
    /// The draft overlay has settled.
    case settled
    /// The prepared overlay is read-only.
    case readOnly
    /// The change was already prepared or aborted.
    case changeSettled
    /// The candidate belongs to another tracker.
    case foreign
    /// The candidate was already adopted.
    case consumed
    /// The candidate was aborted.
    case aborted
    /// The candidate no longer matches the tracker revision.
    case stale
    /// The candidate has not been prepared.
    case notReady
    /// The operation would create an array hole.
    case holes
    /// The array index is outside the supported range.
    case indexOutOfRange
    /// The requested array length is invalid.
    case invalidLength
    /// An array operation was called on an object.
    case incompatibleReceiver
    /// The operation has an invalid shape or violates a draft rule.
    case invalidOperation(String)

    /// The text description of this value or error.
    public var description: String {
        switch self {
        case .settled: "Cannot use a settled overlay"
        case .readOnly: "Prepared overlays are read-only"
        case .changeSettled: "Change has already been settled"
        case .foreign: "Prepared change belongs to a different tracker"
        case .consumed: "Prepared change has already been used"
        case .aborted: "Prepared change has been aborted"
        case .stale: "Prepared change is stale"
        case .notReady: "Prepared change is not ready"
        case .holes: "Overlay arrays cannot contain holes"
        case .indexOutOfRange: "Array overlay index is out of range"
        case .invalidLength: "Invalid array length"
        case .incompatibleReceiver: "Array mutator called on incompatible receiver"
        case .invalidOperation(let text): text
        }
    }
}

/// A shared lifetime for draft handles from one or more changes.
/// Revocation waits for draft operations that are already in progress.
public final class DraftLifetime: Sendable {
    private let lock = Mutex(false)
    private let onAccess: (@Sendable () -> Void)?

    /// Creates an active lifetime for draft operations.
    public init() { onAccess = nil }

    // Tests can hold a real draft operation after lifetime admission.
    init(onAccess: @escaping @Sendable () -> Void) { self.onAccess = onAccess }

    /// Whether this lifetime rejects new draft operations.
    public var isRevoked: Bool { lock.withLock { $0 } }

    /// Rejects new draft operations after current operations finish.
    public func revoke() { lock.withLock { $0 = true } }

    fileprivate func withAccess<Result>(_ body: () throws -> Result) throws -> Result {
        try lock.withLock { revoked in
            guard !revoked else { throw TrackerError.settled }
            onAccess?()
            return try body()
        }
    }
}

private final class TrackerOwner: Sendable {}
private enum TrackerStatus { case open, prepared, consumed, aborted, stale }
private struct TrackerWeakContext { weak var value: DraftContext? }

/// An immutable JSON revision and its open changes.
public final class Tracker: Sendable {
    private struct State {
        var value: JSONValue
        var revision = 0
        var contexts: [TrackerWeakContext] = []
    }
    private let owner = TrackerOwner()
    private let lock: Mutex<State>
    fileprivate init(_ value: JSONValue) { lock = Mutex(State(value: value)) }
    /// The current immutable JSON revision.
    public var value: JSONValue { lock.withLock { $0.value } }
    /// The number of adopted revisions.
    public var revision: Int { lock.withLock { $0.revision } }

    /// Creates a draft from the current revision, with an optional shared lifetime.
    public func beginChange(lifetime: DraftLifetime? = nil) -> Change {
        lock.withLock { state in
            state.contexts.removeAll { $0.value == nil }
            let context = DraftContext(owner: owner, base: state.value, revision: state.revision, lifetime: lifetime)
            state.contexts.append(TrackerWeakContext(value: context))
            return Change(context)
        }
    }
    /// Prepares an object or array replacement without changing the current revision.
    public func prepareReplace(_ value: JSONValue) throws -> Prepared {
        try lock.withLock { state in
            try requireContainer(value)
            let context = DraftContext(owner: owner, base: state.value, revision: state.revision)
            let ops: [Delta.Op] = value == state.value ? [] : [.replace(value)]
            context.lock.withLock { $0.status = .prepared; $0.release() }
            state.contexts.removeAll { $0.value == nil }
            state.contexts.append(TrackerWeakContext(value: context))
            return Prepared(context, base: state.value, value: ops.isEmpty ? state.value : value, ops: ops)
        }
    }
    /// Adopts a candidate from this tracker and invalidates competing drafts.
    public func adopt(_ prepared: Prepared) throws {
        try lock.withLock { state in
            let context = prepared.context
            guard context.owner === owner else { throw TrackerError.foreign }
            try context.lock.withLock { draft in
                switch draft.status {
                case .consumed: throw TrackerError.consumed
                case .aborted: throw TrackerError.aborted
                case .stale: throw TrackerError.stale
                case .open: throw TrackerError.notReady
                case .prepared: break
                }
                guard context.baseRevision == state.revision else {
                    draft.status = .stale
                    throw TrackerError.stale
                }
                draft.status = .consumed
            }
            state.value = prepared.value
            state.revision += 1
            for reference in state.contexts {
                guard let other = reference.value, other !== context else { continue }
                other.lock.withLock { draft in
                    if draft.status == .open || draft.status == .prepared { draft.status = .stale }
                    draft.release()
                }
            }
            state.contexts.removeAll()
        }
    }
}

/// A change that can be prepared once.
public final class Change: Sendable {
    private let context: DraftContext
    fileprivate init(_ context: DraftContext) { self.context = context }
    /// Returns the root draft, or throws if the change has settled.
    public var state: JSONDraft {
        get throws {
            try context.withAccess { draft in
                try draft.readable()
                return JSONDraft(context, node: 0)
            }
        }
    }
    /// Materializes the candidate and operations, and revokes its draft handles.
    public func prepare() throws -> Prepared {
        try context.lock.withLock { draft in
            guard !draft.changeSettled else { throw TrackerError.changeSettled }
            try draft.writable()
            draft.status = .prepared
            do {
                let ops = draft.emit()
                let base = draft.base!
                let value = try Delta.applyImmutable(base, ops)!
                draft.changeSettled = true
                draft.release()
                return Prepared(context, base: base, value: value, ops: ops)
            } catch {
                draft.status = .aborted
                draft.changeSettled = true
                draft.release()
                throw error
            }
        }
    }
    /// Discards this candidate or change. Repeated calls have no effect.
    public func abort() {
        context.lock.withLock { draft in
            draft.changeSettled = true
            if draft.status == .open || draft.status == .prepared { draft.status = .aborted }
            draft.release()
        }
    }
}

/// A materialized candidate revision. Adoption does not run draft code.
public final class Prepared: Sendable {
    fileprivate let context: DraftContext
    /// The immutable revision from which this candidate was prepared.
    public let base: JSONValue
    /// The candidate revision produced by these operations.
    public let value: JSONValue
    /// The exact ordered operations for this revision.
    public let ops: [Delta.Op]
    /// The tracker revision from which this candidate was prepared.
    public var baseRevision: Int { context.baseRevision }
    fileprivate init(_ context: DraftContext, base: JSONValue, value: JSONValue, ops: [Delta.Op]) {
        self.context = context; self.base = base; self.value = value; self.ops = ops
    }
    /// Discards this candidate or change. Repeated calls have no effect.
    public func abort() {
        context.lock.withLock { draft in
            if draft.status == .open || draft.status == .prepared { draft.status = .aborted }
            draft.release()
        }
    }
}

extension Delta {
    /// The revision tracker available through the Delta namespace.
    public typealias Tracker = PiSwiftChord.Tracker
    /// The draft change available through the Delta namespace.
    public typealias Change = PiSwiftChord.Change
    /// The candidate revision available through the Delta namespace.
    public typealias Prepared = PiSwiftChord.Prepared
    /// Creates a tracker for an object or array root; rejects scalar roots.
    public static func track(_ initial: JSONValue) throws -> Tracker {
        try requireContainer(initial)
        return Tracker(initial)
    }
}

private func requireContainer(_ value: JSONValue) throws {
    switch value {
    case .array, .object: break
    default: throw TrackerError.invalidOperation("Tracker root must be an object or array")
    }
}

// All mutable nodes and slots are used only inside DraftContext.lock.
private struct DraftRef {
    var value: JSONValue
    var child: Int?
}
private struct DraftSlot {
    let id: Int
    let baseIndex: Int?
    var ref: DraftRef
}
private enum DraftParent {
    case object(Int, Delta.PathSegment)
    case array(Int, Int)
    var node: Int {
        switch self { case .object(let node, _), .array(let node, _): node }
    }
}
private final class DraftNode {
    let base: JSONValue
    let parent: DraftParent?
    let placement: Bool
    var baseChildren: [Delta.PathSegment: Int] = [:]
    var writes: [Delta.PathSegment: DraftRef] = [:]
    var writeOrder: [Delta.PathSegment] = []
    var deletes: Set<Delta.PathSegment> = []
    var deleteOrder: [Delta.PathSegment] = []
    var readded: Set<Delta.PathSegment> = []
    var readdOrder: [Delta.PathSegment] = []
    var slots: [DraftSlot] = []
    var head = 0
    var slotsReady = false
    var structural = false
    var overrideOrder: [Int] = []
    var overrides: Set<Int> = []
    var dirty = false
    init(_ base: JSONValue, parent: DraftParent? = nil, placement: Bool = false) {
        self.base = base; self.parent = parent; self.placement = placement
    }
    var isArray: Bool { if case .array = base { true } else { false } }
    var count: Int { slots.count - head }
}
private final class DraftContext: Sendable {
    let owner: TrackerOwner
    let baseRevision: Int
    let lock: Mutex<DraftState>
    private let lifetime: DraftLifetime?
    init(owner: TrackerOwner, base: JSONValue, revision: Int, lifetime: DraftLifetime? = nil) {
        self.owner = owner; self.baseRevision = revision; self.lifetime = lifetime
        self.lock = Mutex(DraftState(base: base, nodes: [DraftNode(base)]))
    }
    // The lifetime lock must be acquired before the change lock.
    func withAccess<Result: Sendable>(_ body: (inout sending DraftState) throws -> Result) throws -> Result {
        if let lifetime {
            return try lifetime.withAccess { try lock.withLock { draft in try body(&draft) } }
        }
        return try lock.withLock { draft in try body(&draft) }
    }
}
private struct DraftState {
    var status: TrackerStatus = .open
    var released = false
    var changeSettled = false
    var base: JSONValue?
    var nodes: [DraftNode]
    var dirty: [Int] = []
    var nextSlot = 0
    func readable() throws {
        if released || status == .consumed || status == .aborted || status == .stale { throw TrackerError.settled }
    }
    func writable() throws {
        try readable()
        if status != .open { throw TrackerError.readOnly }
    }
    mutating func release() { released = true; base = nil; nodes.removeAll(); dirty.removeAll() }
    mutating func mark(_ id: Int) {
        if !nodes[id].dirty { nodes[id].dirty = true; dirty.append(id) }
    }
    mutating func ensureSlots(_ id: Int) {
        let node = nodes[id]
        guard !node.slotsReady else { return }
        node.slotsReady = true
        for (index, value) in node.base.arrayValue!.enumerated() {
            node.slots.append(DraftSlot(id: nextSlot, baseIndex: index, ref: DraftRef(value: value)))
            nextSlot += 1
        }
    }
    func objectRef(_ id: Int, _ key: Delta.PathSegment) -> DraftRef? {
        let node = nodes[id]
        if node.deletes.contains(key) { return nil }
        if let ref = node.writes[key] { return ref }
        guard let value = node.base[key.propertyKey] else { return nil }
        return DraftRef(value: value, child: node.baseChildren[key])
    }
    func objectKeys(_ id: Int) -> [String] {
        let node = nodes[id]
        var ordered = JSONObject()
        for key in node.base.objectValue!.keys {
            let segment = Delta.PathSegment.key(key)
            if !node.deletes.contains(segment) && !node.readded.contains(segment) { ordered[key] = .null }
        }
        for key in node.writeOrder { ordered[key.propertyKey] = .null }
        return ordered.keys
    }
    mutating func snapshot(_ id: Int) -> JSONValue {
        var work: [(Int, Bool)] = [(id, false)]
        var values: [Int: JSONValue] = [:]
        while let (current, ready) = work.popLast() {
            let node = nodes[current]
            if node.isArray { ensureSlots(current) }
            if !ready {
                work.append((current, true))
                if node.isArray {
                    for slot in node.slots[node.head...] {
                        if let child = slot.ref.child { work.append((child, false)) }
                    }
                } else {
                    for key in objectKeys(current) {
                        if let child = objectRef(current, .key(key))?.child { work.append((child, false)) }
                    }
                }
                continue
            }
            if node.isArray {
                values[current] = .array(node.slots[node.head...].map { ref in
                    ref.ref.child.map { values[$0]! } ?? ref.ref.value
                })
            } else {
                var object = JSONObject()
                for key in objectKeys(current) {
                    let ref = objectRef(current, .key(key))!
                    object[key] = ref.child.map { values[$0]! } ?? ref.value
                }
                values[current] = .object(object)
            }
        }
        return values[id]!
    }
    mutating func snapshotRef(_ ref: DraftRef) -> JSONValue {
        if let child = ref.child { return snapshot(child) }
        return ref.value
    }
    mutating func child(_ id: Int, key: Delta.PathSegment) -> Int? {
        let node = nodes[id]
        var ref: DraftRef
        var slotIndex: Int?
        if node.isArray {
            ensureSlots(id)
            guard case .index(let index) = key, index >= 0, index < node.count else { return nil }
            slotIndex = node.head + index
            ref = node.slots[slotIndex!].ref
        } else {
            guard let current = objectRef(id, key) else { return nil }
            ref = current
        }
        if let existing = ref.child { return existing }
        switch ref.value { case .array, .object: break; default: return nil }
        let childID = nodes.count
        if let slotIndex {
            let slot = node.slots[slotIndex]
            nodes.append(DraftNode(ref.value, parent: .array(id, slot.id), placement: slot.baseIndex == nil || node.overrides.contains(slot.id)))
            node.slots[slotIndex].ref.child = childID
        } else {
            nodes.append(DraftNode(ref.value, parent: .object(id, key), placement: node.writes[key] != nil))
            if node.writes[key] != nil { node.writes[key]!.child = childID }
            else { node.baseChildren[key] = childID }
        }
        return childID
    }
    mutating func setObject(_ id: Int, _ key: Delta.PathSegment, _ value: JSONValue) {
        let node = nodes[id]
        let wasDeleted = node.deletes.contains(key)
        if !wasDeleted, !isContainer(value), objectRef(id, key)?.value == value { return }
        if node.writes[key] == nil { node.writeOrder.append(key) }
        node.writes[key] = DraftRef(value: value)
        if wasDeleted, node.base[key.propertyKey] != nil, node.readded.insert(key).inserted { node.readdOrder.append(key) }
        node.deletes.remove(key)
        node.deleteOrder.removeAll { $0 == key }
        mark(id)
    }
    mutating func removeObject(_ id: Int, _ key: Delta.PathSegment) {
        let node = nodes[id]
        guard objectRef(id, key) != nil else { return }
        node.writes.removeValue(forKey: key)
        node.writeOrder.removeAll { $0 == key }
        node.readded.remove(key)
        node.readdOrder.removeAll { $0 == key }
        if node.deletes.insert(key).inserted { node.deleteOrder.append(key) }
        mark(id)
    }
    mutating func replaceRange(_ id: Int, start: Int, remove: Int, insert: [JSONValue]) -> [JSONValue] {
        ensureSlots(id)
        let node = nodes[id]
        let absolute = node.head + start
        let removed = node.slots[absolute..<(absolute + remove)].map { snapshotRef($0.ref) }
        guard remove != 0 || !insert.isEmpty else { return removed }
        let additions = insert.map { value in
            defer { nextSlot += 1 }
            return DraftSlot(id: nextSlot, baseIndex: nil, ref: DraftRef(value: value))
        }
        if start == 0 && insert.isEmpty {
            node.head += remove
            // A queue keeps a small dead prefix, without copying on each shift.
            if node.head > 4096 && node.head * 2 > node.slots.count {
                node.slots.removeFirst(node.head); node.head = 0
            }
        } else { node.slots.replaceSubrange(absolute..<(absolute + remove), with: additions) }
        node.structural = true
        mark(id)
        return removed
    }
    mutating func setIndex(_ id: Int, _ index: Int, _ value: JSONValue) throws {
        ensureSlots(id)
        let node = nodes[id]
        if index < 0 || index >= 4_294_967_295 { throw TrackerError.invalidOperation("Only array indices and length can be written") }
        if index > node.count { throw TrackerError.holes }
        try validatePlacement(value)
        if index == node.count { _ = replaceRange(id, start: index, remove: 0, insert: [value]); return }
        let absolute = node.head + index
        let slot = node.slots[absolute]
        if !isContainer(value), slot.ref.value == value { return }
        node.slots[absolute].ref = DraftRef(value: value)
        if let baseIndex = slot.baseIndex {
            if !isContainer(value), node.base.arrayValue![baseIndex] == value {
                node.overrides.remove(slot.id)
                node.overrideOrder.removeAll { $0 == slot.id }
            } else if node.overrides.insert(slot.id).inserted { node.overrideOrder.append(slot.id) }
        }
        mark(id)
    }
}
private func isContainer(_ value: JSONValue) -> Bool {
    switch value { case .array, .object: true; default: false }
}

/// A handle to one object or array in an open change.
/// All methods use the lifetime lock, then the change lock. Reads return value snapshots.
public final class JSONDraft: Sendable {
    /// The container type of a draft handle.
    public enum Kind: Sendable {
        /// An object container.
        case object
        /// An array container.
        case array
    }
    private let context: DraftContext
    private let node: Int
    fileprivate init(_ context: DraftContext, node: Int) { self.context = context; self.node = node }
    /// The kind of this draft or delivery.
    public var kind: Kind {
        get throws { try context.withAccess { try $0.readable(); return $0.nodes[node].isArray ? .array : .object } }
    }
    /// Copies the current draft tree. Throws after draft settlement.
    public func snapshot() throws -> JSONValue {
        try context.withAccess { try $0.readable(); return $0.snapshot(node) }
    }
    /// Returns a member value, or nil if the member is absent.
    public func get(_ key: String) throws -> JSONValue? {
        try context.withAccess { draft in
            try draft.readable()
            if draft.nodes[node].isArray {
                if key == "length" { draft.ensureSlots(node); return .number(Double(draft.nodes[node].count)) }
                if let index = Self.arrayIndex(key) { return draft.arrayValue(node, index) }
                return nil
            }
            return draft.objectRef(node, .key(key)).map { draft.snapshotRef($0) }
        }
    }
    /// Returns an element value, or nil if the index is absent.
    public func get(_ index: Int) throws -> JSONValue? {
        try context.withAccess { draft in
            try draft.readable()
            if !draft.nodes[node].isArray { return draft.objectRef(node, .key(String(index))).map { draft.snapshotRef($0) } }
            return draft.arrayValue(node, index)
        }
    }
    /// Returns a child container handle, or nil if no container is present.
    public func child(_ key: String) throws -> JSONDraft? {
        try context.withAccess { draft in
            try draft.readable()
            let segment: Delta.PathSegment
            if draft.nodes[node].isArray {
                guard let index = Self.arrayIndex(key) else { return nil }
                segment = .index(index)
            } else { segment = .key(key) }
            return draft.child(node, key: segment).map { JSONDraft(context, node: $0) }
        }
    }
    /// Returns an element container handle, or nil if no container is present.
    public func child(_ index: Int) throws -> JSONDraft? {
        try context.withAccess { draft in
            try draft.readable()
            let key: Delta.PathSegment = draft.nodes[node].isArray ? .index(index) : .key(String(index))
            return draft.child(node, key: key).map { JSONDraft(context, node: $0) }
        }
    }
    /// Returns the current member keys in JavaScript key order.
    public func keys() throws -> [String] {
        try context.withAccess { draft in
            try draft.readable()
            if !draft.nodes[node].isArray { return draft.objectKeys(node) }
            draft.ensureSlots(node)
            return (0..<draft.nodes[node].count).map(String.init)
        }
    }
    /// Returns the current number of members or elements.
    public func count() throws -> Int {
        try context.withAccess { draft in
            try draft.readable()
            if !draft.nodes[node].isArray { return draft.objectKeys(node).count }
            draft.ensureSlots(node)
            return draft.nodes[node].count
        }
    }
    /// Returns whether the draft has this member.
    public func contains(_ key: String) throws -> Bool {
        try context.withAccess { draft in
            try draft.readable()
            if !draft.nodes[node].isArray { return draft.objectRef(node, .key(key)) != nil }
            if key == "length" { return true }
            draft.ensureSlots(node)
            guard let index = Self.arrayIndex(key) else { return false }
            return index < draft.nodes[node].count
        }
    }
    /// Assigns a strict JSON member value and detaches any replaced child handle.
    public func set(_ key: String, _ value: JSONValue) throws {
        try context.withAccess { draft in
            try draft.writable()
            if draft.nodes[node].isArray {
                if key == "length" {
                    guard let count = value.intValue else { throw TrackerError.invalidLength }
                    try draft.setCount(node, count)
                } else {
                    guard let index = Self.arrayIndex(key) else { throw TrackerError.invalidOperation("Only array indices and length can be written") }
                    try draft.setIndex(node, index, value)
                }
            } else { try validatePlacement(value); draft.setObject(node, .key(key), value) }
        }
    }
    /// Assigns an array element; rejects indices that would create holes.
    public func set(_ index: Int, _ value: JSONValue) throws {
        try context.withAccess { draft in
            try draft.writable()
            if draft.nodes[node].isArray { try draft.setIndex(node, index, value) }
            else { try validatePlacement(value); draft.setObject(node, .key(String(index)), value) }
        }
    }
    /// Removes an object member and detaches its child handle.
    public func remove(_ key: String) throws {
        try context.withAccess { draft in
            try draft.writable()
            if draft.nodes[node].isArray { throw TrackerError.holes }
            draft.removeObject(node, .key(key))
        }
    }
    /// Adds one strict JSON value to the end of the array.
    public func append(_ value: JSONValue) throws { try append(contentsOf: [value]) }
    /// Adds strict JSON values to the end of the array.
    public func append(contentsOf values: [JSONValue]) throws {
        try context.withAccess { draft in
            try draft.arrayWritable(node)
            try validatePlacements(values)
            _ = draft.replaceRange(node, start: draft.nodes[node].count, remove: 0, insert: values)
        }
    }
    /// Removes and returns the last element, or nil for an empty array.
    public func popLast() throws -> JSONValue? {
        try context.withAccess { draft in
            try draft.arrayWritable(node)
            let count = draft.nodes[node].count
            if count == 0 { return nil }
            return draft.replaceRange(node, start: count - 1, remove: 1, insert: []).first
        }
    }
    /// Removes and returns the first element, or nil for an empty array.
    public func popFirst() throws -> JSONValue? {
        try context.withAccess { draft in
            try draft.arrayWritable(node)
            if draft.nodes[node].count == 0 { return nil }
            return draft.replaceRange(node, start: 0, remove: 1, insert: []).first
        }
    }
    /// Adds strict JSON values to the start of the array.
    public func prepend(contentsOf values: [JSONValue]) throws {
        try context.withAccess { draft in
            try draft.arrayWritable(node)
            try validatePlacements(values)
            _ = draft.replaceRange(node, start: 0, remove: 0, insert: values)
        }
    }
    /// Replaces an array range and returns the removed values; negative starts count from the end.
    @discardableResult public func splice(_ start: Int, deleteCount: Int? = nil, insert: [JSONValue] = []) throws -> [JSONValue] {
        try context.withAccess { draft in
            try draft.arrayWritable(node)
            let count = draft.nodes[node].count
            let at = start < 0 ? (start < -count ? 0 : count + start) : min(start, count)
            let remove = deleteCount.map { min(max($0, 0), count - at) } ?? (count - at)
            try validatePlacements(insert)
            return draft.replaceRange(node, start: at, remove: remove, insert: insert)
        }
    }
    /// Reverses the current array elements.
    public func reverse() throws {
        try context.withAccess { draft in
            try draft.arrayWritable(node)
            let target = draft.nodes[node]
            if target.count < 2 { return }
            if target.head != 0 { target.slots.removeFirst(target.head); target.head = 0 }
            target.slots.reverse()
            target.structural = true
            draft.mark(node)
        }
    }
    /// Shrinks the array length; rejects growth that would create holes.
    public func setCount(_ count: Int) throws {
        try context.withAccess { draft in
            try draft.arrayWritable(node)
            try draft.setCount(node, count)
        }
    }
    private static func arrayIndex(_ text: String) -> Int? {
        guard let value = Int(text), value >= 0, value < 4_294_967_295, String(value) == text else { return nil }
        return value
    }
}

private extension DraftState {
    mutating func arrayWritable(_ id: Int) throws {
        try writable()
        guard nodes[id].isArray else { throw TrackerError.incompatibleReceiver }
        ensureSlots(id)
    }
    mutating func arrayValue(_ id: Int, _ index: Int) -> JSONValue? {
        ensureSlots(id)
        let node = nodes[id]
        guard index >= 0, index < node.count else { return nil }
        return snapshotRef(node.slots[node.head + index].ref)
    }
    mutating func setCount(_ id: Int, _ count: Int) throws {
        guard count >= 0, count < 4_294_967_296 else { throw TrackerError.invalidLength }
        ensureSlots(id)
        let old = nodes[id].count
        if count < old { _ = replaceRange(id, start: count, remove: old - count, insert: []) }
        if count > old { _ = replaceRange(id, start: old, remove: 0, insert: Array(repeating: .null, count: count - old)) }
    }
}

private struct DraftRegion { let start: Int; let length: Int }
private struct DraftPositions {
    var paths: [Int: Delta.Path] = [:]
    var detached: Set<Int> = []
    var slots: [Int: [Int: Int]] = [:]
}

private extension DraftState {
    func resolve(_ id: Int, _ positions: inout DraftPositions) -> Delta.Path? {
        if let cached = positions.paths[id] { return cached }
        if positions.detached.contains(id) { return nil }
        var chain: [Int] = []
        var at = id
        while positions.paths[at] == nil && !positions.detached.contains(at) {
            chain.append(at)
            guard let parent = nodes[at].parent else { positions.paths[at] = []; break }
            at = parent.node
        }
        guard var path = positions.paths[at] else {
            positions.detached.formUnion(chain)
            return nil
        }
        for child in chain.reversed() {
            guard let parent = nodes[child].parent else { continue }
            let segment: Delta.PathSegment
            switch parent {
            case .object(let parentID, let key):
                guard objectRef(parentID, key)?.child == child else {
                    positions.detached.formUnion(chain)
                    return nil
                }
                segment = key
            case .array(let parentID, let slotID):
                let array = nodes[parentID]
                if positions.slots[parentID] == nil {
                    var map: [Int: Int] = [:]
                    for index in 0..<array.count { map[array.slots[array.head + index].id] = index }
                    positions.slots[parentID] = map
                }
                guard let index = positions.slots[parentID]![slotID], array.slots[array.head + index].ref.child == child else {
                    positions.detached.formUnion(chain)
                    return nil
                }
                segment = .index(index)
            }
            path.append(segment)
            positions.paths[child] = path
        }
        return positions.paths[id]
    }
    func placementAncestor(_ id: Int) -> Bool {
        var at = id
        while let parent = nodes[at].parent {
            if nodes[at].placement { return true }
            at = parent.node
        }
        return false
    }
    func coveringRegion(_ id: Int, path: Delta.Path, regions: [Int: [DraftRegion]], positions: inout DraftPositions) -> Bool {
        var at = nodes[id].parent?.node
        while let parent = at {
            if let group = regions[parent], let parentPath = resolve(parent, &positions), path.count > parentPath.count,
               path.starts(with: parentPath), case .index(let index) = path[parentPath.count], contains(group, index) { return true }
            at = nodes[parent].parent?.node
        }
        return false
    }
    func contains(_ regions: [DraftRegion], _ index: Int) -> Bool {
        regions.contains { index >= $0.start && index < $0.start + $0.length }
    }
    mutating func emit() -> [Delta.Op] {
        if dirty.isEmpty { return [] }
        var positions = DraftPositions()
        // Candidate order matches the upstream Map insertion order.
        var candidates: [Int: [Int]] = [:]
        var denseOrder: [Int] = []
        for id in dirty {
            var child = id
            while let parent = nodes[child].parent {
                let parentID = parent.node
                if nodes[parentID].isArray {
                    if !nodes[parentID].structural, case .array(_, let slotID) = parent,
                       let childPath = resolve(child, &positions), case .index(let index) = childPath.last,
                       let slotIndex = positions.slots[parentID]?[slotID],
                       nodes[parentID].slots[nodes[parentID].head + slotIndex].baseIndex != nil {
                        if candidates[parentID] == nil { candidates[parentID] = []; denseOrder.append(parentID) }
                        candidates[parentID]!.append(index)
                    }
                    break
                }
                child = parentID
            }
            let node = nodes[id]
            if node.isArray && !node.structural && !node.overrideOrder.isEmpty {
                if candidates[id] == nil { candidates[id] = []; denseOrder.append(id) }
                for slot in node.slots[node.head...] where node.overrides.contains(slot.id) { candidates[id]!.append(slot.baseIndex!) }
            }
        }
        var regions: [Int: [DraftRegion]] = [:]
        for id in denseOrder {
            guard let path = resolve(id, &positions), !path.contains(where: isReserved), candidates[id]!.count >= 256 else { continue }
            let indices = Array(Set(candidates[id]!)).sorted()
            var at = 0
            var group: [DraftRegion] = []
            while at < indices.count {
                let start = indices[at]
                var end = start
                var count = 1
                at += 1
                while at < indices.count && indices[at] - end <= 2 { end = indices[at]; count += 1; at += 1 }
                let length = end - start + 1
                if count >= 256 && count * 2 >= length { group.append(DraftRegion(start: start, length: length)) }
            }
            if !group.isEmpty { regions[id] = group }
        }
        var order: [Int] = []
        var paths: [Int: Delta.Path] = [:]
        var folds: Set<Int> = []
        var foldOrder: [Int] = []
        for id in dirty {
            guard let path = resolve(id, &positions), !coveringRegion(id, path: path, regions: regions, positions: &positions) else { continue }
            paths[id] = path; order.append(id)
            let node = nodes[id]
            if !node.isArray && (node.writeOrder.contains(where: isReserved) || node.deleteOrder.contains(where: isReserved)) {
                if folds.insert(id).inserted { foldOrder.append(id) }
            }
            if let reservedAt = path.firstIndex(where: isReserved) {
                var ancestor = id
                for _ in reservedAt..<path.count { ancestor = nodes[ancestor].parent!.node }
                if folds.insert(ancestor).inserted { foldOrder.append(ancestor) }
            }
        }
        for id in foldOrder where paths[id] == nil {
            paths[id] = resolve(id, &positions)!; order.append(id)
        }
        for id in denseOrder where regions[id] != nil {
            if let path = resolve(id, &positions), !coveringRegion(id, path: path, regions: regions, positions: &positions), paths[id] == nil {
                paths[id] = path; order.append(id)
            }
        }
        // Use the insertion rank to make same-depth order explicit.
        let rank = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($0.element, $0.offset) })
        order.sort { paths[$0]!.count == paths[$1]!.count ? rank[$0]! < rank[$1]! : paths[$0]!.count < paths[$1]!.count }
        var folded: Set<Int> = []
        var ops: [Delta.Op] = []
        for id in order {
            if placementAncestor(id) { continue }
            var ancestor = nodes[id].parent?.node
            var covered = false
            while let parent = ancestor {
                if folded.contains(parent) { covered = true; break }
                ancestor = nodes[parent].parent?.node
            }
            if covered { continue }
            let path = paths[id]!
            if folds.contains(id) {
                let value = snapshot(id)
                ops.append(path.isEmpty ? .replace(value) : .set(path, value))
                folded.insert(id)
            } else if nodes[id].isArray { emitArray(id, path, regions[id] ?? [], &ops) }
            else { emitObject(id, path, &ops) }
            if ops.count > 4096 { return [.replace(snapshot(0))] }
        }
        return ops
    }
    mutating func emitObject(_ id: Int, _ path: Delta.Path, _ ops: inout [Delta.Op]) {
        let node = nodes[id]
        for key in node.readdOrder where node.base[key.propertyKey] != nil { ops.append(.delete(path + [key])) }
        for key in node.writeOrder {
            if ops.count > 4096 { return }
            let before = node.readded.contains(key) ? nil : node.base[key.propertyKey]
            changed(path + [key], before, snapshotRef(node.writes[key]!), &ops)
        }
        for key in node.deleteOrder {
            if ops.count > 4096 { return }
            if node.base[key.propertyKey] != nil { ops.append(.delete(path + [key])) }
        }
    }
    mutating func emitArray(_ id: Int, _ path: Delta.Path, _ regions: [DraftRegion], _ ops: inout [Delta.Op]) {
        ensureSlots(id)
        let node = nodes[id]
        let base = node.base.arrayValue!
        for region in regions {
            if ops.count > 4096 { return }
            let items = node.slots[(node.head + region.start)..<(node.head + region.start + region.length)].map { snapshotRef($0.ref) }
            ops.append(.splice(path, index: region.start, remove: region.length, items: items))
        }
        var locations: [Int: Int] = [:]
        for index in 0..<node.count { locations[node.slots[node.head + index].id] = index }
        if node.structural {
            var retained = [Bool](repeating: false, count: base.count)
            var targetBase: [Int] = []
            for slot in node.slots[node.head...] {
                if let index = slot.baseIndex { retained[index] = true; targetBase.append(index) }
            }
            var end = base.count
            while end > 0 {
                if retained[end - 1] { end -= 1; continue }
                var start = end - 1
                while start > 0 && !retained[start - 1] { start -= 1 }
                if ops.count > 4096 { return }
                ops.append(.splice(path, index: start, remove: end - start, items: []))
                end = start
            }
            let kept = retained.indices.filter { retained[$0] }
            if kept != targetBase {
                let ranks = Dictionary(uniqueKeysWithValues: kept.enumerated().map { ($0.element, $0.offset) })
                ops.append(.move(path, permutation: targetBase.map { ranks[$0]! }))
            }
            var index = 0
            while index < node.count {
                if node.slots[node.head + index].baseIndex != nil { index += 1; continue }
                let start = index
                var items: [JSONValue] = []
                while index < node.count && node.slots[node.head + index].baseIndex == nil {
                    items.append(snapshotRef(node.slots[node.head + index].ref)); index += 1
                }
                if ops.count > 4096 { return }
                ops.append(.splice(path, index: start, remove: 0, items: items))
            }
        }
        for slotID in node.overrideOrder {
            if ops.count > 4096 { return }
            guard let index = locations[slotID], !contains(regions, index) else { continue }
            let slot = node.slots[node.head + index]
            changed(path + [.index(index)], base[slot.baseIndex!], snapshotRef(slot.ref), &ops)
        }
    }
    func changed(_ path: Delta.Path, _ before: JSONValue?, _ after: JSONValue, _ ops: inout [Delta.Op]) {
        if before == after { return }
        if let left = before?.stringValue, let right = after.stringValue {
            let a = Array(left.utf16), b = Array(right.utf16)
            if b.count > a.count && b.starts(with: a) {
                ops.append(.append(path, String(decoding: b.dropFirst(a.count), as: UTF16.self))); return
            }
            let shared = Delta.overlap(left, right, scan: 65_536)
            if shared > 0 {
                ops.append(.trim(path, a.count - shared))
                if b.count > shared { ops.append(.append(path, String(decoding: b.dropFirst(shared), as: UTF16.self))) }
                return
            }
        }
        ops.append(.set(path, after))
    }
}
private func isReserved(_ key: Delta.PathSegment) -> Bool {
    if case .key(let key) = key { return Delta.reservedSegments.contains(key) }
    return false
}

private func validatePlacement(_ value: JSONValue) throws {
    guard value.isStrictJSON else { throw TrackerError.invalidOperation("Value contains a non-finite number and is not strict JSON") }
}
private func validatePlacements(_ values: [JSONValue]) throws {
    for value in values { try validatePlacement(value) }
}
