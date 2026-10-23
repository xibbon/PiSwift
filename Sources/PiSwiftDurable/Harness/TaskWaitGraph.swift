/// Reverse links for the ownership records already kept by the scheduler.
internal struct TaskWaitOwnershipIndex: Sendable {
    var children: [OwnershipUp: Set<OwnershipUp>] = [:]
    var pending = Set<TaskID>()

    mutating func add(_ record: TaskRecord) {
        children[record.parent, default: []].insert(.task(record.id))
    }
    mutating func add(_ record: ConversationRecord) {
        if let owner = record.owner { children[.task(owner.taskId), default: []].insert(.conversation(record.id)) }
    }
    mutating func remove(_ record: TaskRecord) {
        children[record.parent]?.remove(.task(record.id))
        if children[record.parent]?.isEmpty == true { children.removeValue(forKey: record.parent) }
        // Child links belong to their cached records, even when this parent must be loaded again.
        pending.remove(record.id)
    }
}

extension TaskScheduler {
    /// A wait must name existing tasks and must keep the wait-for graph acyclic.
    func validateWait(_ tx: Transaction, invocation: TaskInvocation, current: TaskRecord,
                      on: [TaskID], policy: JoinPolicy) async throws {
        if invocation.abort { throw SessionError.message("Abort handler of task \(current.id.rawValue) cannot wait") }
        let overlay = try TaskOverlay(tx)
        var targets: [TaskID] = []
        for id in on {
            let member: TaskRecord?
            if let record = overlay.tasks[id] ?? self.current(id) { member = record }
            else { member = try await storage.task(id, context: context) }
            guard let member else { throw SessionError.message("Task \(id.rawValue) does not exist") }
            if policy == .failFast && member.owner != current.id {
                throw SessionError.message("Task \(current.id.rawValue) can wait failFast only on tasks it owns; \(id.rawValue) is not one")
            }
            // Direct children already hold this task. Terminal tasks have no edges.
            if member.state.status != "terminal" && member.owner != current.id { targets.append(id) }
        }
        guard !targets.isEmpty, let cycle = try await waitCycle(current.id, on: targets, overlay: overlay) else { return }
        let path = ([current.id] + cycle).map { String($0.rawValue) }.joined(separator: " -> ")
        throw SessionError.message("Task \(current.id.rawValue) cannot wait on \(cycle[0].rawValue): \(path) is a wait cycle")
    }

    /// Find a path from a wait target back to the task. Each reached task is visited once.
    private func waitCycle(_ task: TaskID, on: [TaskID], overlay: TaskOverlay) async throws -> [TaskID]? {
        // New committed tasks can precede the next reservation. Load only their chains.
        let unloaded = state.withLock { $0.waitOwnership.pending }
        for id in unloaded {
            if let record = current(id) { try await loadChain(record.parent) }
            _ = state.withLock { $0.waitOwnership.pending.remove(id) }
        }
        var staged = TaskWaitOwnershipIndex()
        for record in overlay.tasks.values {
            try await loadChain(record.parent, overlay: overlay)
            staged.add(record)
        }
        for record in overlay.conversations.values { staged.add(record) }
        var from: [TaskID: TaskID] = [:]
        var reached = Set<TaskID>(), walked = Set<OwnershipUp>()
        var pending: [TaskID] = []
        func reach(_ id: TaskID, via: TaskID?) {
            guard reached.insert(id).inserted else { return }
            from[id] = via
            pending.append(id)
        }
        for id in on { reach(id, via: nil) }
        while let id = pending.popLast() {
            if id == task {
                var path: [TaskID] = [], at: TaskID? = id
                while let step = at { path.append(step); at = from[step] }
                return path.reversed()
            }
            guard let record = overlay.tasks[id] ?? current(id), record.state.status != "terminal" else { continue }
            // Abort runs from the bottom up. Its old wait does not hold the task.
            if case .waiting(_, let members, _, _) = record.state, !record.abortRequested {
                for member in members { reach(member, via: id) }
            }
            var below: [OwnershipUp] = [.task(id)]
            while let at = below.popLast() {
                guard walked.insert(at).inserted else { continue }
                let children = state.withLock { $0.waitOwnership.children[at] ?? [] }
                    .union(staged.children[at] ?? [])
                for child in children {
                    switch child {
                    case .conversation: below.append(child)
                    case .task(let member):
                        let live = overlay.tasks[member] ?? current(member)
                        guard let node = live ?? state.withLock({ $0.nodes[member] }), !node.background else { continue }
                        if let live, live.state.status != "terminal" { reach(member, via: id) }
                        // A cached terminal owner can have live work in its conversations.
                        below.append(child)
                    }
                }
            }
        }
        return nil
    }
}
