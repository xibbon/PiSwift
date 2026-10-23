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
        try await loadScopes()
        for record in overlay.tasks.values {
            try await loadChain(record.parent, overlay: overlay)
        }
        let staged = links(overlay)
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
                let children = state.withLock { state in
                    let children = (state.below[at] ?? []).union(staged[at] ?? [])
                    state.candidateEntries += children.count
                    return children
                }
                for child in children {
                    switch child {
                    case .conversation: below.append(child)
                    case .task(let member):
                        let live = overlay.tasks[member] ?? current(member)
                        guard let node = live.map(TaskNode.init) ?? state.withLock({ $0.nodes[member] }), !node.background else { continue }
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
