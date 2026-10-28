import Foundation

extension Harness {
    /// Returns the current work and the next sleep deadline without a storage read.
    public func wake() -> HarnessWake { tasks.wake() }
}

extension TaskScheduler {
    /// An abort mark ends a sleep without waiting for its deadline.
    func notDue(_ record: TaskRecord) -> Bool {
        if case .sleeping(_, let until, _) = record.state {
            return !record.abortRequested && until > Double(now())
        }
        return false
    }

    /// Check sleeps at every reservation pass, including passes before a timer fires.
    func wakeDue() {
        let now = Double(now())
        state.withLock { state in
            state.candidateEntries += state.sleeping.count
            for id in state.sleeping {
                guard let record = state.live[id], case .sleeping(_, let until, _) = record.state else { continue }
                if record.abortRequested || until <= now { state.runnable.insert(id) }
            }
        }
    }

    /// Reads work from memory. Work below waits and held outcomes counts itself.
    func wake() -> HarnessWake {
        let time = Double(now())
        let view = state.withLock { $0 }
        var active = !view.invocations.isEmpty || view.reconcilingWork > 0 || view.cascadePending ||
            !view.finalizeChecks.isEmpty || !view.failFastChecks.isEmpty
        var at: Double?
        var snapshot: RegistrySnapshot?
        for record in view.live.values {
            if record.state.status == "completing" { continue }
            if !record.abortRequested, case .waiting(_, let on, _, _) = record.state,
               on.contains(where: { view.live[$0] != nil }) { continue }
            if !record.abortRequested, case .sleeping(_, let until, _) = record.state, until > time {
                at = at.map { min($0, until) } ?? until
                continue
            }
            if active { continue }
            if record.abortRequested && view.hasOwnedLive(record.id) { continue }
            if !record.abortRequested || record.abortReason != nil {
                snapshot = snapshot ?? registry.snapshot()
                guard let definition = snapshot?.task(name: record.kind), definition.version >= record.version else { continue }
                if definition.version > record.version, let failure = view.failedMigrations[record.id],
                   failure.0 == definition.identity { continue }
            }
            active = true
        }
        return HarnessWake(active: active, at: at)
    }

    /// Offers wakes on a separate task. No host callback runs on the Session line.
    func scheduleWake() {
        state.withLock { state in
            guard !state.closing else { return }
            state.wakeDirty = true
            guard !state.wakeScheduled else { return }
            state.wakeScheduled = true
            Task.detached { [weak self] in self?.deliverWakes() }
        }
    }

    private func deliverWakes() {
        while state.withLock({ state in
            guard !state.closing, state.wakeDirty else { state.wakeScheduled = false; return false }
            state.wakeDirty = false; return true
        }) {
            let value = wake()
            if let onWake {
                if state.withLock({ $0.lastWake == value }) { continue }
                do {
                    try onWake(value)
                    state.withLock { $0.lastWake = value }
                } catch { report(error) }
            } else {
                armSleep(state.withLock({ $0.enabled && !$0.closing }) ? value.at : nil)
                // The deadline can pass before the first timer is installed, or
                // while the host arms it. Hand that work to a reservation pass.
                let time = Double(now())
                let due = state.withLock { state in
                    state.enabled && !state.closing && state.sleeping.contains { id in
                        guard case .sleeping(_, let until, _) = state.live[id]?.state else { return false }
                        return until <= time
                    }
                }
                // An empty pass must not offer itself again for a missing definition.
                if due { kick(offerWake: false) }
            }
        }
    }

    /// Keeps one foreground timer. An early fire starts a pass and checks time again.
    private func armSleep(_ deadline: Double?) {
        let time = Double(now())
        let changed = state.withLock { state -> (UUID, HarnessDisarm?, Bool)? in
            guard !state.closing, state.sleepAt != deadline else { return nil }
            let previous = state.sleepDisarm
            let wasDue = state.sleepAt.map { $0 <= time } ?? false
            state.sleepDisarm = nil; state.sleepAt = deadline
            let id = UUID(); state.sleepID = id
            return (id, previous, wasDue)
        }
        guard let (id, previous, wasDue) = changed else { return }
        previous?()
        // Cancelling a due timer can suppress a callback still queued by the host.
        // Start its scheduling pass here before replacing or removing that timer.
        if wasDue { wakeDue(); kick() }
        guard let deadline else { return }
        let disarm = timers.setTimer({ [weak self] in
            guard let self else { return }
            let valid = self.state.withLock { state in
                guard state.sleepID == id, !state.closing else { return false }
                state.sleepDisarm = nil; state.sleepAt = nil; return true
            }
            if valid { self.wakeDue(); self.kick() }
        }, until: deadline)
        let installed = state.withLock { state in
            guard state.sleepID == id, state.sleepAt != nil, !state.closing else { return false }
            state.sleepDisarm = disarm; return true
        }
        if !installed { disarm?() }
    }
}

private extension TaskScheduler.State {
    func hasOwnedLive(_ owner: TaskID) -> Bool {
        var pending: [OwnershipUp] = [.task(owner)]
        while let parent = pending.popLast() {
            for child in below[parent] ?? [] {
                switch child {
                case .conversation: pending.append(child)
                case .task(let id):
                    guard let node = live[id].map(TaskNode.init) ?? nodes[id], !node.background else { continue }
                    if live[id] != nil { return true }
                    pending.append(child)
                }
            }
        }
        return false
    }
}
