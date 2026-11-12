import Testing
@testable import PiSwiftDurable

@Suite("PiSwiftDurableTests.ContextIdleIndexD7", .timeLimit(.minutes(1)))
struct ContextIdleIndexD7Tests {
    @Test func clockReversalResortsIdleExpiryOrder() {
        var index = ContextIdleIndex<Int>()
        index.mark(1, since: 1_000)
        index.mark(2, since: 1_100)
        index.mark(3, since: 900) // v1.5.2 D7 scheduler.ts:985-995
        #expect(index.oldest == 900)
        #expect(index.expire(now: 999, retention: 100) == [])
        #expect(index.expire(now: 1_000, retention: 100) == [3])
        #expect(index.expire(now: 1_200, retention: 100) == [1, 2])
    }

    @Test func unexpiredCheckVisitsOneOfTenThousandContexts() {
        var index = ContextIdleIndex<Int>()
        for id in 0..<10_000 { index.mark(id, since: Int64(1_000 + id)) }
        let before = index.visited
        #expect(index.expire(now: 1_001, retention: 600_000).isEmpty)
        #expect(index.visited - before == 1)
        #expect(index.count == 10_000)
    }
}
