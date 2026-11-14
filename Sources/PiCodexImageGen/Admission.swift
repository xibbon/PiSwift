import CryptoKit
import Foundation
import PiSwiftAI

// Port of pi-codex-image-gen `src/admission.ts`: two active and eight queued
// generations per account, at most 32 account scopes. Account ids never
// leave this actor; they are keyed by an HMAC with a per-process secret.

actor ImageAdmission {
    static let shared = ImageAdmission()

    let maxActive: Int
    let maxQueued: Int
    let maxAccounts: Int
    private let secret = SymmetricKey(size: .bits256)

    private struct Waiter {
        var id: UUID
        var continuation: CheckedContinuation<Void, Error>
    }
    private struct Account {
        var active = 0
        var queue: [Waiter] = []
    }
    private var accounts: [String: Account] = [:]

    init(maxActive: Int = 2, maxQueued: Int = 8, maxAccounts: Int = 32) {
        self.maxActive = maxActive
        self.maxQueued = maxQueued
        self.maxAccounts = maxAccounts
    }

    /// Wait for a slot. Call `release` on the ticket exactly when work ends.
    func admit(account: String, token: CancellationToken) async throws -> AdmissionTicket {
        if token.isCancelled { throw CancellationError() }
        let key = HMAC<SHA256>.authenticationCode(for: Data(account.utf8), using: secret)
            .map { String(format: "%02x", $0) }.joined()
        var state = accounts[key]
        if state == nil {
            guard accounts.count < maxAccounts else {
                throw CodexImageError("Image admission capacity exceeded. No generation request was made.")
            }
            state = Account()
        }
        guard var current = state else { throw CancellationError() }
        guard current.queue.count < maxQueued else {
            throw CodexImageError("Image generation queue is full. No generation request was made.")
        }
        if current.active < maxActive {
            current.active += 1
            accounts[key] = current
            return AdmissionTicket(admission: self, key: key)
        }
        accounts[key] = current
        let id = UUID()
        let remove = token.onCancel { [weak self] in
            Task { await self?.cancel(key: key, id: id) }
        }
        defer { remove() }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            accounts[key, default: Account()].queue.append(Waiter(id: id, continuation: continuation))
        }
        return AdmissionTicket(admission: self, key: key)
    }

    private func cancel(key: String, id: UUID) {
        guard let index = accounts[key]?.queue.firstIndex(where: { $0.id == id }) else { return }
        let waiter = accounts[key]!.queue.remove(at: index)
        cleanUp(key)
        waiter.continuation.resume(throwing: CodexImageError(
            "Image generation cancelled before admission. No generation request was made."))
    }

    fileprivate func release(key: String) {
        guard var state = accounts[key] else { return }
        state.active -= 1
        if !state.queue.isEmpty {
            let next = state.queue.removeFirst()
            state.active += 1
            accounts[key] = state
            next.continuation.resume()
        } else {
            accounts[key] = state
            cleanUp(key)
        }
    }

    private func cleanUp(_ key: String) {
        if let state = accounts[key], state.active == 0, state.queue.isEmpty { accounts[key] = nil }
    }

    /// Test seam: the number of account scopes held.
    var accountCount: Int { accounts.count }
}

final class AdmissionTicket: Sendable {
    private let admission: ImageAdmission
    private let key: String
    private let released = LockedState(false)

    fileprivate init(admission: ImageAdmission, key: String) {
        self.admission = admission
        self.key = key
    }

    func release() async {
        let first = released.withLock { value -> Bool in
            defer { value = true }
            return !value
        }
        if first { await admission.release(key: key) }
    }
}
