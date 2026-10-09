import Synchronization
import PiSwiftChord

private final class MutationSlot: Sendable {
    private struct State: Sendable {
        var complete = false
        var waiters: [CheckedContinuation<Void, Never>] = []
    }
    private let state = Mutex(State())

    func wait() async {
        await withCheckedContinuation { continuation in
            let complete = state.withLock { value in
                if value.complete { return true }
                value.waiters.append(continuation)
                return false
            }
            if complete { continuation.resume() }
        }
    }

    func release() {
        let waiters = state.withLock { value in
            value.complete = true
            let waiters = value.waiters
            value.waiters.removeAll()
            return waiters
        }
        for waiter in waiters { waiter.resume() }
    }
}

private struct MutationKey: Hashable, Sendable {
    let environment: [UInt8]
    // Byte identity also keeps distinct NFC and NFD names separate on file systems that support them.
    let path: [UInt8]
}

private let mutationSlots = Mutex<[MutationKey: MutationSlot]>([:])

private func canonicalMutationPath(env: any ExecutionEnv, path: String, context: ChordContext) async throws -> String {
    switch await env.canonicalPath(path, context: context) {
    case .success(let canonical): return canonical
    case .failure(let error):
        if error.code == .notSupported { return path }
        guard error.code == .notFound else { throw error }
    }
    // Use the environment path rules. A POSIX name can contain a backslash.
    let parent = try await env.joinPath([path, ".."], context: context).get()
    let parentBytes = Array(parent.utf8), pathBytes = Array(path.utf8)
    guard parentBytes != pathBytes, pathBytes.starts(with: parentBytes) else { return path }
    let separatorCount = parentBytes.last == 0x2F || parentBytes.last == 0x5C ? 0 : 1
    let name = String(decoding: pathBytes.dropFirst(parentBytes.count + separatorCount), as: UTF8.self)
    let canonicalParent = try await canonicalMutationPath(env: env, path: parent, context: context)
    return try await env.joinPath([canonicalParent, name], context: context).get()
}

/// Holds one file's mutation slot until the operation settles, including after cancellation.
internal func withFileMutationQueue<T: Sendable>(
    env: any ExecutionEnv, path: String, context: ChordContext,
    operation: @Sendable () async throws -> T
) async throws -> T {
    let absolute = try await env.absolutePath(path, context: context).get()
    let canonical = try await canonicalMutationPath(env: env, path: absolute, context: context)
    let key = MutationKey(environment: Array(env.id.utf8), path: Array(canonical.utf8))
    let slot = MutationSlot()
    let previous = mutationSlots.withLock { slots in
        let previous = slots[key]
        slots[key] = slot
        return previous
    }
    if let previous { await previous.wait() }
    defer {
        slot.release()
        mutationSlots.withLock { slots in
            if slots[key] === slot { slots.removeValue(forKey: key) }
        }
    }
    return try await operation()
}
