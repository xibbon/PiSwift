import Foundation

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

    /// D1 uses the existing clock sleep. D2 replaces this with host timers.
    func scheduleSleep() {
        let now = Double(now())
        state.withLock { state in
            let deadline = state.enabled && !state.closing ? state.sleeping.compactMap { id -> Double? in
                guard let record = state.live[id], !record.abortRequested,
                      case .sleeping(_, let until, _) = record.state, until > now else { return nil }
                return until
            }.min() : nil
            if state.sleepAt == deadline { return }
            state.sleepWork?.cancel(); state.sleepWork = nil; state.sleepAt = nil
            guard let deadline else { return }
            state.sleepAt = deadline
            let id = UUID(); state.sleepID = id
            // Round only the internal clock wait up. The saved Double stays unchanged.
            let delay = Int64(min(deadline - now, 2_147_483_647).rounded(.up))
            let (at, overflow) = clock.now().addingReportingOverflow(delay)
            let clockDeadline = overflow ? Int64.max : at
            state.sleepWork = Task { [weak self, clock] in
                do { try await clock.sleep(until: clockDeadline) }
                catch { return }
                guard let self else { return }
                let valid = self.state.withLock { state -> Bool in
                    guard state.sleepID == id, !state.closing else { return false }
                    state.sleepWork = nil; state.sleepAt = nil
                    return true
                }
                if valid { self.kick() }
            }
        }
    }
}
