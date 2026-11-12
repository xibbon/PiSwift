/// Records failed driver calls during checks. A driver failure is never a batch refusal.
final class SqliteCommitChecks: SqliteExecutor {
    let executor: any SqliteExecutor
    private(set) var failed = false

    init(_ executor: any SqliteExecutor) { self.executor = executor }

    private func call<T>(_ body: () throws -> T) throws -> T {
        do { return try body() }
        catch { failed = true; throw error }
    }

    func exec(_ sql: String) throws { try call { try executor.exec(sql) } }
    func run(_ sql: String, _ params: [SqliteValue]) throws { try call { try executor.run(sql, params) } }
    func get(_ sql: String, _ params: [SqliteValue]) throws -> SqliteRow? {
        try call { try executor.get(sql, params) }
    }
    func all(_ sql: String, _ params: [SqliteValue]) throws -> [SqliteRow] {
        try call { try executor.all(sql, params) }
    }
    func transaction<T>(_ body: (any SqliteExecutor) throws -> T) throws -> T {
        try call { try executor.transaction(body) }
    }
    func close() throws { try call { try executor.close() } }
}
