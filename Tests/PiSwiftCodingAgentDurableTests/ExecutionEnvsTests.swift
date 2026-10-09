import PiSwiftChord
import PiSwiftDurable
@testable import PiSwiftCodingAgentDurable
import Synchronization
import Testing

private func envTarget(_ cwd: String?, id: Int64 = 1) throws -> EnvTarget {
    EnvTarget(conversationId: try ConversationID(id), cwd: cwd, read: .init())
}

@Test func executionEnvsSharesDirectoryAcrossConversations() throws {
    let pool = ExecutionEnvs(defaultCwd: "/default")
    let first = pool.env(try envTarget("/shared"))
    let second = pool.env(try envTarget("/shared", id: 2))
    let other = pool.env(try envTarget("/other"))
    #expect(first === second)
    #expect(first !== other)
    #expect(first.cwd == "/shared")
    #expect(other.cwd == "/other")
}

@Test func executionEnvsUsesDefaultOnlyForMissingDirectory() async throws {
    let pool = ExecutionEnvs(defaultCwd: "/default")
    let first = pool.env(try envTarget(nil))
    #expect(first === pool.env(try envTarget("/default")))
    #expect(pool.env(try envTarget("")).cwd == "")
    let supplied = try await pool.factory(envTarget(nil, id: 3), .background)
    #expect((supplied as? LocalExecutionEnv) === first)
    await pool.cleanup(context: .background)
}

@Test func executionEnvsCreatesOneEnvironmentForConcurrentCalls() async throws {
    let pool = ExecutionEnvs(defaultCwd: "/default")
    let target = try envTarget("/shared")
    let results = await withTaskGroup(of: LocalExecutionEnv.self) { group in
        for _ in 0..<100 { group.addTask { pool.env(target) } }
        var results: [LocalExecutionEnv] = []
        for await result in group { results.append(result) }
        return results
    }
    let first = try #require(results.first)
    #expect(results.allSatisfy { $0 === first })
    await pool.cleanup(context: .background)
}

@Test func executionEnvsCleansEveryEnvironmentOnceAndClearsPool() async throws {
    let cleaned = Mutex<[String]>([])
    let pool = ExecutionEnvs(defaultCwd: "/default", cleanup: { env, context in
        cleaned.withLock { $0.append(env.cwd) }
        await env.cleanup(context: context)
    })
    let target = try envTarget("/one")
    let old = pool.env(target)
    _ = pool.env(target)
    _ = pool.env(try envTarget("/two"))
    _ = pool.env(try envTarget(nil))
    await withTaskGroup(of: Void.self) { group in
        for _ in 0..<10 { group.addTask { await pool.cleanup(context: .background) } }
    }
    #expect(cleaned.withLock { $0.sorted() } == ["/default", "/one", "/two"])
    let replacement = pool.env(target)
    #expect(replacement !== old)
    await pool.cleanup(context: .background)
    #expect(cleaned.withLock { $0.filter { $0 == "/one" }.count } == 2)
}
