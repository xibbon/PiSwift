import Synchronization

/// A FIFO lock that remains held across suspension points.
internal final class SessionLine: Sendable {
    final class Ticket: Sendable {
        private struct State: Sendable {
            var ready = false
            var waiter: CheckedContinuation<Void, Never>?
        }
        private let state = Mutex(State())
        func wait() async {
            await withCheckedContinuation { continuation in
                let ready = state.withLock { state in
                    if state.ready { return true }
                    state.waiter = continuation
                    return false
                }
                if ready { continuation.resume() }
            }
        }
        func grant() {
            let waiter = state.withLock { state in
                state.ready = true
                let waiter = state.waiter
                state.waiter = nil
                return waiter
            }
            waiter?.resume()
        }
    }
    private struct State: Sendable {
        var held = false
        var queue: [Ticket] = []
    }
    private let state = Mutex(State())
    var queuedCount: Int { state.withLock { $0.queue.count } }
    /// Reserve synchronously so Session admission and close have one order.
    func reserve() -> Ticket {
        let ticket = Ticket()
        let immediate = state.withLock { state in
            if !state.held { state.held = true; return true }
            state.queue.append(ticket)
            return false
        }
        if immediate { ticket.grant() }
        return ticket
    }
    func acquire() async { await reserve().wait() }
    func release() {
        let next = state.withLock { state -> Ticket? in
            if state.queue.isEmpty { state.held = false; return nil }
            return state.queue.removeFirst()
        }
        next?.grant()
    }
}
