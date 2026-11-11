struct StrictToolLimitSessions: Sendable {
    var ids: Set<String> = []
    var order: [String] = []

    mutating func mark(_ sessionId: String) {
        guard ids.insert(sessionId).inserted else { return }
        order.append(sessionId)
        if order.count > 10_000 { ids.remove(order.removeFirst()) }
    }
}

private enum StrictToolLimitResource {
    static let sessions = LockedState(StrictToolLimitSessions())
    static let registration: Void = {
        _ = registerSessionResourceCleanup { cleanupStrictToolLimits($0) }
    }()
}

func isStrictToolLimitErrorMessage(_ message: String) -> Bool {
    ["The compiled grammar is too large", "Too many strict tools (",
     "Schemas contains too many parameters with union types ("].contains(where: message.contains)
}

func markStrictToolLimitsExceeded(_ sessionId: String?) {
    guard let sessionId else { return }
    _ = StrictToolLimitResource.registration
    StrictToolLimitResource.sessions.withLock { $0.mark(sessionId) }
}

func hasExceededStrictToolLimits(_ sessionId: String?) -> Bool {
    guard let sessionId else { return false }
    _ = StrictToolLimitResource.registration
    return StrictToolLimitResource.sessions.withLock { $0.ids.contains(sessionId) }
}

func cleanupStrictToolLimits(_ sessionId: String?) {
    StrictToolLimitResource.sessions.withLock { state in
        if let sessionId, !sessionId.isEmpty {
            state.ids.remove(sessionId)
            state.order.removeAll { $0 == sessionId }
        } else {
            state.ids.removeAll()
            state.order.removeAll()
        }
    }
}
