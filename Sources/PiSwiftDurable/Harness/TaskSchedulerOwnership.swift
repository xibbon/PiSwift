import PiSwiftChord

/// Only ownership fields are kept after a task ends.
internal struct TaskNode: Sendable {
    let id: TaskID
    let conversationId: ConversationID
    let owner: TaskID?
    let background: Bool
    init(_ record: TaskRecord) {
        id = record.id; conversationId = record.conversationId
        owner = record.owner; background = record.background
    }
    var parent: OwnershipUp { owner.map(OwnershipUp.task) ?? .conversation(conversationId) }
}

internal struct TaskOwnershipEdge: Sendable {
    let owner: TaskID?
    init(_ record: ConversationRecord) { owner = record.owner?.taskId }
}

extension TaskScheduler.State {
    func known(_ node: OwnershipUp) -> Bool {
        switch node {
        case .task(let id): return (live[id] != nil || nodes[id] != nil) && !unloaded.contains(id)
        case .conversation(let id):
            guard let edge = edges[id] else { return false }
            return edge.owner.map { known(.task($0)) } ?? true
        }
    }
    mutating func dropIfUnneeded(_ node: OwnershipUp) {
        if case .task(let id) = node, live[id] != nil { return }
        if below[node] == nil { dropQueue.insert(node) }
    }
    /// Change parent links only as far as membership changes. This walk must stay iterative.
    mutating func relist(_ start: OwnershipUp) {
        var node = start
        while true {
            var needed = below[node] != nil
            let parent: OwnershipUp
            switch node {
            case .task(let id):
                needed = needed || live[id] != nil
                guard let fields = live[id].map(TaskNode.init) ?? nodes[id] else { return }
                parent = fields.parent
            case .conversation(let id):
                guard let edge = edges[id] else { return }
                guard let owner = edge.owner else {
                    if needed { roots.insert(id) } else { roots.remove(id) }
                    return
                }
                parent = .task(owner)
            }
            if (below[parent]?.contains(node) == true) == needed { return }
            if needed {
                let first = below[parent] == nil
                below[parent, default: []].insert(node)
                if !first { return }
            } else {
                below[parent]?.remove(node)
                if below[parent]?.isEmpty == true { below.removeValue(forKey: parent) }
                if below[parent] != nil { return }
                dropIfUnneeded(parent)
            }
            node = parent
        }
    }
    mutating func setEdge(_ record: ConversationRecord) {
        edges[record.id] = TaskOwnershipEdge(record)
        relist(.conversation(record.id)); dropIfUnneeded(.conversation(record.id))
    }
    mutating func settle(_ record: TaskRecord) {
        nodes[record.id] = TaskNode(record); unloaded.insert(record.id)
        relist(.task(record.id)); dropIfUnneeded(.task(record.id))
    }
    func nearestLiveAbove(_ node: TaskNode, overlay: TaskOverlay = .empty) -> TaskRecord? {
        var current = node
        while !current.background {
            let edge = overlay.conversations[current.conversationId].map(TaskOwnershipEdge.init) ?? edges[current.conversationId]
            guard let owner = current.owner ?? edge?.owner else { return nil }
            let record = overlay.tasks[owner] ?? live[owner]
            if let record, record.state.status != "terminal" { return record }
            guard let above = record.map(TaskNode.init) ?? nodes[owner] else { return nil }
            current = above
        }
        return nil
    }
    mutating func track(_ record: TaskRecord) {
        let id = record.id, previous = live[id]
        if case .sleeping = record.state { sleeping.insert(id) } else { sleeping.remove(id) }
        if case .waiting(_, let on, _, _) = previous?.state {
            for target in on {
                waiters[target]?.remove(id)
                if waiters[target]?.isEmpty == true { waiters.removeValue(forKey: target) }
            }
        }
        if record.state.status == "terminal" {
            parked.remove(id)
            live.removeValue(forKey: id); liveOrder.removeValue(forKey: id); intent.remove(id); runnable.remove(id); finalizeChecks.remove(id)
            nodes[id] = TaskNode(record)
            if let above = nearestLiveAbove(TaskNode(record)) {
                if above.state.status == "completing" { finalizeChecks.insert(above.id) }
                else if above.abortRequested { runnable.insert(above.id) }
            }
            if let waiting = waiters[id] { candidateEntries += waiting.count; runnable.formUnion(waiting) }
            if let owner = previous?.owner ?? record.owner {
                directOwned[owner]?.remove(id)
                if directOwned[owner]?.isEmpty == true { directOwned.removeValue(forKey: owner) }
            }
            relist(.task(id)); dropIfUnneeded(.task(id))
            return
        }
        live[id] = record
        if previous == nil {
            liveOrder[id] = nextOrder; nextOrder += 1
            if !known(record.parent) { unloaded.insert(id) }
            if let owner = record.owner { directOwned[owner, default: []].insert(id) }
            relist(.task(id))
        }
        if record.abortRequested || record.failedOutcome { intent.insert(id) } else { intent.remove(id) }
        if record.state.status == "completing" { runnable.remove(id); finalizeChecks.insert(id) }
        else { runnable.insert(id) }
        if case .waiting(_, let on, _, _) = record.state {
            for target in on { waiters[target, default: []].insert(id) }
        }
    }
    mutating func sweep() {
        candidateEntries += dropQueue.count
        for node in dropQueue where below[node] == nil {
            switch node {
            case .conversation(let id): edges.removeValue(forKey: id); roots.remove(id)
            case .task(let id):
                if live[id] == nil { nodes.removeValue(forKey: id); unloaded.remove(id) }
            }
        }
        dropQueue.removeAll()
    }
}

extension TaskScheduler {
    var indexSizes: [String: Int] {
        state.withLock { ["live": $0.live.count, "settled": $0.nodes.count, "edges": $0.edges.count,
                         "below": $0.below.values.reduce(0) { $0 + $1.count }, "roots": $0.roots.count,
                         "unloaded": $0.unloaded.count, "dropQueue": $0.dropQueue.count] }
    }
    /// Count candidate-set and downward-link entries, for cost tests.
    var candidateEntries: Int { state.withLock { $0.candidateEntries } }
    func resetCandidateEntries() { state.withLock { $0.candidateEntries = 0 } }
    func scheduleSweep() {
        state.withLock { state in
            guard !state.sweepScheduled, !state.closing, !state.dropQueue.isEmpty else { return }
            state.sweepScheduled = true
            state.sweepWork = Task { [weak self] in
                guard let self else { return }
                try? await self.session.readOnLine {
                    self.state.withLock { $0.sweepScheduled = false; $0.sweep() }
                }
            }
        }
    }
    func loadChain(_ start: OwnershipUp, overlay: TaskOverlay = .empty) async throws {
        var at: OwnershipUp? = start, passed: [TaskID] = []
        while let step = at {
            switch step {
            case .task(let id):
                var node = state.withLock { $0.live[id].map(TaskNode.init) ?? $0.nodes[id] }
                if node == nil && overlay.tasks[id] != nil { at = nil; continue }
                if node != nil && state.withLock({ !$0.unloaded.contains(id) }) { at = nil; continue }
                if node == nil {
                    guard let record = try await storage.task(id, context: context) else { return }
                    node = TaskNode(record)
                    if record.state.status == "terminal" { state.withLock { $0.settle(record) }; scheduleSweep() }
                    scheduleReconcile()
                }
                passed.append(id); at = node?.parent
            case .conversation(let id):
                var edge = overlay.conversations[id].map(TaskOwnershipEdge.init) ?? state.withLock { $0.edges[id] }
                if edge == nil {
                    if let record = try await storage.conversation(id, context: context) {
                        edge = TaskOwnershipEdge(record)
                        state.withLock { $0.setEdge(record) }; scheduleSweep()
                    }
                    scheduleReconcile()
                }
                at = edge?.owner.map(OwnershipUp.task)
            }
        }
        state.withLock { $0.unloaded.subtract(passed) }
    }
    func loadScopes() async throws {
        let unloaded = state.withLock { state in state.candidateEntries += state.unloaded.count; return Array(state.unloaded) }
        for id in unloaded where state.withLock({ $0.unloaded.contains(id) }) { try await loadChain(.task(id)) }
    }
    func loadQueuedScopes() async throws -> Set<ConversationID> {
        let submissions = try await scanAll { cursor in
            try await storage.scanSubmissions(.init(status: .queued), limit: 256, cursor: cursor, context: context)
        }
        let ids = Set(submissions.filter { $0.type == "input" }.map(\.conversationId))
        for id in ids { try await loadChain(.conversation(id)) }
        return ids
    }
    func above(_ start: OwnershipUp, overlay: TaskOverlay = .empty) -> AnySequence<OwnershipStep> {
        AnySequence {
            var at: OwnershipUp? = start, unknown = false
            return AnyIterator<OwnershipStep> {
                if unknown { unknown = false; return .unknown }
                guard let step = at else { return nil }
                return self.state.withLock { state in
                    switch step {
                    case .task(let id):
                        guard let node = overlay.tasks[id].map(TaskNode.init) ?? state.live[id].map(TaskNode.init) ?? state.nodes[id] else {
                            at = nil; return .unknown
                        }
                        at = node.parent; return .task(node)
                    case .conversation(let id):
                        let edge = overlay.conversations[id].map(TaskOwnershipEdge.init) ?? state.edges[id]
                        at = edge?.owner.map(OwnershipUp.task)
                        unknown = edge == nil
                        return .conversation(id)
                    }
                }
            }
        }
    }
    /// Add staged tasks and the missing links above them to the committed tree.
    func links(_ overlay: TaskOverlay) -> [OwnershipUp: Set<OwnershipUp>] {
        state.withLock { state in
            var links: [OwnershipUp: Set<OwnershipUp>] = [:]
            for record in overlay.tasks.values {
                if state.live[record.id] != nil || state.nodes[record.id] != nil { continue }
                var child = OwnershipUp.task(record.id), parent: OwnershipUp? = record.parent
                while let at = parent, links[at]?.contains(child) != true {
                    links[at, default: []].insert(child)
                    if case .task(let id) = at, state.live[id] != nil || overlay.tasks[id] != nil { break }
                    let above: OwnershipUp?
                    switch at {
                    case .conversation(let id): above = (overlay.conversations[id].map(TaskOwnershipEdge.init) ?? state.edges[id])?.owner.map(OwnershipUp.task)
                    case .task(let id): above = state.nodes[id]?.parent
                    }
                    if let above, state.below[above]?.contains(at) == true { break }
                    child = at; parent = above
                }
            }
            return links
        }
    }
    struct DownStep { let node: TaskNode; let live: TaskRecord? }
    /// Return at the first matching task when the caller needs only an existence check.
    @discardableResult
    func walkDown(_ start: OwnershipUp, overlay: TaskOverlay = .empty,
                  links: [OwnershipUp: Set<OwnershipUp>] = [:], crossBackground: Bool = false,
                  enter: (TaskID) -> Bool = { _ in true }, visit: (DownStep) -> Bool) -> Bool {
        var pending = [start]
        while let at = pending.popLast() {
            let children = state.withLock { state -> Set<OwnershipUp> in
                let children = state.below[at] ?? []
                state.candidateEntries += children.count
                return children
            }
            let staged = links[at] ?? []
            state.withLock { $0.candidateEntries += staged.count }
            for group in [children, staged] {
                for child in group {
                    switch child {
                    case .conversation: pending.append(child)
                    case .task(let id):
                        let (record, node) = state.withLock { state in
                            let record = overlay.tasks[id] ?? state.live[id]
                            return (record, record.map(TaskNode.init) ?? state.nodes[id])
                        }
                        guard let node else { continue }
                        let live = record.flatMap { $0.state.status == "terminal" ? nil : $0 }
                        if visit(DownStep(node: node, live: live)) { return true }
                        if (crossBackground || !node.background) && enter(id) { pending.append(child) }
                    }
                }
            }
        }
        return false
    }
    func ownedLive(_ owner: TaskID, overlay: TaskOverlay = .empty, links: [OwnershipUp: Set<OwnershipUp>] = [:],
                   first: Bool = false, done: Set<TaskID> = []) -> [TaskID] {
        var found: [TaskID] = []
        walkDown(.task(owner), overlay: overlay, links: links, enter: { !done.contains($0) }) { step in
            guard let live = step.live, !step.node.background else { return false }
            found.append(live.id); return first
        }
        return found
    }
    func inScope(_ start: OwnershipUp, conversationId: ConversationID?, background: Bool = false) -> Bool? {
        for step in above(start) {
            switch step {
            case .unknown: return nil
            case .conversation(let id): if id == conversationId { return true }
            case .task(let record): if record.background && !background { return false }
            }
        }
        return conversationId == nil
    }
    func cancellingOwner(_ start: OwnershipUp) -> TaskRecord? {
        if state.withLock({ $0.intent.isEmpty }) { return nil }
        for step in above(start) {
            if case .task(let record) = step {
                if let live = current(record.id), live.abortRequested || live.failedOutcome { return live }
                if record.background { return nil }
            }
        }
        return nil
    }
    func belowCancelled(_ start: OwnershipUp) -> Bool { cancellingOwner(start) != nil }
    func idle(_ id: ConversationID?) -> Bool {
        let unloaded = state.withLock { state in state.candidateEntries += state.unloaded.count; return state.unloaded }
        for task in unloaded {
            if let record = current(task), !record.background, inScope(record.parent, conversationId: id) != false { return false }
        }
        let starts = id.map { [$0] } ?? state.withLock { state in state.candidateEntries += state.roots.count; return Array(state.roots) }
        for start in starts {
            if walkDown(.conversation(start), visit: { $0.live != nil && !$0.node.background }) { return false }
        }
        return true
    }
    func waitingOn(_ record: TaskRecord, first: Bool = false) -> [TaskID] {
        if record.abortRequested { return ownedLive(record.id, first: first) }
        if case .waiting(_, let on, _, _) = record.state {
            if first { return on.first(where: { current($0) != nil }).map { [$0] } ?? [] }
            return on.filter { current($0) != nil }
        }
        return []
    }
}
