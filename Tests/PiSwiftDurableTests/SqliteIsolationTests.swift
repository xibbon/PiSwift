import Dispatch
import Foundation
import Synchronization
import Testing
import PiSwiftChord
@testable import PiSwiftDurable

private struct ReadGateState: Sendable {
    var armed = false
    var admitted = false
    var outsideStarted = false
    var closed = false
}

/// Blocks one synchronous query after it read its row. State remains safe across threads.
private final class ReadGate: Sendable {
    let state = Mutex(ReadGateState())
    let release = DispatchSemaphore(value: 0)
    func arm() { state.withLock { $0.armed = true } }
    func afterRead() throws {
        let block = state.withLock { state in
            guard state.armed else { return false }
            state.armed = false
            state.admitted = true
            return true
        }
        if block, release.wait(timeout: .now() + 10) != .success { throw IsolationTestError.gateTimedOut }
    }
    func waitUntil(_ condition: @Sendable (ReadGateState) -> Bool) async throws {
        for _ in 0..<10_000 {
            if state.withLock({ condition($0) }) { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        throw IsolationTestError.gateTimedOut
    }
}
private enum IsolationTestError: Error { case gateTimedOut, closeFailed }

private final class GatedSqliteExecutor: SqliteExecutor {
    let delegate: AppleSqliteDatabase
    let gate: ReadGate
    var closeFails = false
    var escapeNextTransaction = false
    init(gate: ReadGate) throws { self.gate = gate; delegate = try AppleSqliteDatabase(path: ":memory:") }
    func exec(_ sql: String) throws { try delegate.exec(sql) }
    func run(_ sql: String, _ params: [SqliteValue]) throws { try delegate.run(sql, params) }
    func get(_ sql: String, _ params: [SqliteValue]) throws -> SqliteRow? {
        let row = try delegate.get(sql, params)
        if sql == "SELECT record FROM conversations WHERE id = ?" { try gate.afterRead() }
        return row
    }
    func all(_ sql: String, _ params: [SqliteValue]) throws -> [SqliteRow] { try delegate.all(sql, params) }
    func transaction<T>(_ body: (any SqliteExecutor) throws -> T) throws -> T {
        try delegate.transaction { handle in
            let proxy = GatedTransactionExecutor(delegate: handle, gate: gate)
            let value = try body(proxy)
            if escapeNextTransaction {
                escapeNextTransaction = false
                try handle.exec("COMMIT")
                throw StorageRejected("injected rejection after escaped commit")
            }
            return value
        }
    }
    func close() throws {
        gate.state.withLock { $0.closed = true }
        try delegate.close()
        if closeFails { throw IsolationTestError.closeFailed }
    }
}
private final class GatedTransactionExecutor: SqliteExecutor {
    let delegate: any SqliteExecutor
    let gate: ReadGate
    init(delegate: any SqliteExecutor, gate: ReadGate) { self.delegate = delegate; self.gate = gate }
    func exec(_ sql: String) throws { try delegate.exec(sql) }
    func run(_ sql: String, _ params: [SqliteValue]) throws { try delegate.run(sql, params) }
    func get(_ sql: String, _ params: [SqliteValue]) throws -> SqliteRow? {
        let row = try delegate.get(sql, params)
        if sql == "SELECT record FROM documents WHERE id = ?" { try gate.afterRead() }
        return row
    }
    func all(_ sql: String, _ params: [SqliteValue]) throws -> [SqliteRow] { try delegate.all(sql, params) }
    func transaction<T>(_ body: (any SqliteExecutor) throws -> T) throws -> T { try delegate.transaction(body) }
    func close() throws { try delegate.close() }
}
extension SqliteStorage {
    fileprivate func failClose() { (db as? GatedSqliteExecutor)?.closeFails = true }
    fileprivate func escapeNextCommit() { (db as? GatedSqliteExecutor)?.escapeNextTransaction = true }
}

@Suite("PiSwiftDurableTests.SqliteIsolation")
struct SqliteIsolationTests {
    @Test func activeMultiQueryReadFinishesBeforeConcurrentClose() async throws {
        let gate = ReadGate()
        let storage = try await SqliteStorage.open(executor: GatedSqliteExecutor(gate: gate))
        _ = try await storage.commit([.conversation(value: ConversationRecord(id: rootConversationID)), .entry(value: EntryRecord(id: EntryID(2), conversationId: rootConversationID, kind: "probe"))], context: .background)
        gate.arm()
        let read = Task { try await storage.scanEntries(.init(conversationId: rootConversationID), limit: 10, cursor: nil, context: .background) }
        try await gate.waitUntil { $0.admitted }
        let close = Task {
            gate.state.withLock { $0.outsideStarted = true }
            try await storage.close(context: .background)
        }
        try await gate.waitUntil { $0.outsideStarted }
        #expect(!gate.state.withLock { $0.closed })
        gate.release.signal()
        #expect(try await read.value.items.map(\.id.rawValue) == [2])
        try await close.value
        #expect(gate.state.withLock { $0.closed })
    }

    @Test func activeDocumentReadUsesCommittedBaseBeforeReplacement() async throws {
        let gate = ReadGate()
        let storage = try await SqliteStorage.open(executor: GatedSqliteExecutor(gate: gate))
        let create: JSONValue = ["type": "document.create", "record": ["id": 5, "kind": "replaced", "scope": ["kind": "session"]], "content": ["kind": "base", "version": 1, "value": ["value": 1]]]
        let replace: JSONValue = ["type": "document.change", "id": 5, "content": ["kind": "base", "version": 1, "value": ["value": 2]]]
        _ = try await storage.commit([create.decode(StorageWrite.self)], context: .background)
        gate.arm()
        let read = Task { try await storage.document(DocumentID(5), at: .current, context: .background) }
        try await gate.waitUntil { $0.admitted }
        let commit = Task {
            gate.state.withLock { $0.outsideStarted = true }
            return try await storage.commit([replace.decode(StorageWrite.self)], context: .background)
        }
        try await gate.waitUntil { $0.outsideStarted }
        gate.release.signal()
        #expect(try await read.value?.value == ["value": 1])
        _ = try await commit.value
        #expect(try await storage.document(DocumentID(5), at: .current, context: .background)?.value == ["value": 2])
        try await storage.close(context: .background)
    }

    @Test func injectedRollbackFailureIsNotStorageRejected() async throws {
        let storage = try await SqliteStorage.open(executor: GatedSqliteExecutor(gate: ReadGate()))
        await storage.escapeNextCommit()
        await #expect(throws: SqliteRollbackError.self) { _ = try await storage.commit([], context: .background) }
        try await storage.close(context: .background)
    }

    @Test func repeatedClosePreservesFirstCloseFailure() async throws {
        let storage = try await SqliteStorage.open(executor: GatedSqliteExecutor(gate: ReadGate()))
        await storage.failClose()
        await #expect(throws: IsolationTestError.closeFailed) { try await storage.close(context: .background) }
        await #expect(throws: IsolationTestError.closeFailed) { try await storage.close(context: .background) }
        await #expect(throws: DurableStorageError.closed(backend: "SqliteStorage")) { _ = try await storage.commit([], context: .background) }
    }
}
