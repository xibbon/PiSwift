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
        var queue: [Ticket?] = []
        var head = 0
    }
    private let state = Mutex(State())
    var queuedCount: Int { state.withLock { $0.queue.count - $0.head } }
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
            if state.head == state.queue.count { state.held = false; return nil }
            let next = state.queue[state.head]
            state.queue[state.head] = nil
            state.head += 1
            if state.head == state.queue.count {
                state.queue.removeAll(); state.head = 0
            } else if state.head >= 1_024 && state.head >= state.queue.count - state.head {
                state.queue.removeFirst(state.head); state.head = 0
            }
            return next
        }
        next?.grant()
    }
}
