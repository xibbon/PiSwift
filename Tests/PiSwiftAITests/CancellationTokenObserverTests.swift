import Testing
import PiSwiftAI

@Suite("Cancellation token observer")
struct CancellationTokenObserverTests {
    @Test func handlerRunsOnce() {
        let token = CancellationToken()
        let calls = LockedState(0)
        let unsubscribe = token.onCancel { calls.withLock { $0 += 1 } }

        #expect(calls.withLock { $0 } == 0)
        token.cancel()
        #expect(calls.withLock { $0 } == 1)
        token.cancel()
        unsubscribe()
        #expect(calls.withLock { $0 } == 1)
    }

    @Test func cancelledTokenCallsHandlerImmediately() {
        let token = CancellationToken()
        token.cancel()
        let calls = LockedState(0)

        let unsubscribe = token.onCancel { calls.withLock { $0 += 1 } }

        #expect(calls.withLock { $0 } == 1)
        unsubscribe()
        unsubscribe()
        token.cancel()
        #expect(calls.withLock { $0 } == 1)
    }

    @Test func unsubscribePreventsCall() {
        let token = CancellationToken()
        let calls = LockedState(0)
        let unsubscribe = token.onCancel { calls.withLock { $0 += 1 } }

        unsubscribe()
        unsubscribe()
        token.cancel()

        #expect(calls.withLock { $0 } == 0)
    }

    @Test(arguments: [false, true])
    func handlersAreIndependent(unsubscribeFirst: Bool) {
        let token = CancellationToken()
        let firstCalls = LockedState(0)
        let secondCalls = LockedState(0)
        let removeFirst = token.onCancel { firstCalls.withLock { $0 += 1 } }
        let removeSecond = token.onCancel { secondCalls.withLock { $0 += 1 } }

        if unsubscribeFirst { removeFirst() }
        token.cancel()
        token.cancel()

        #expect(firstCalls.withLock { $0 } == (unsubscribeFirst ? 0 : 1))
        #expect(secondCalls.withLock { $0 } == 1)
        removeFirst()
        removeSecond()
    }
}
