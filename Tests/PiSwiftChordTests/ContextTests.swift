import Synchronization
import Testing
@testable import PiSwiftChord

struct ContextTestError: Error, Sendable, Equatable {
    let text: String
}

// Keep work pending until the test opens the gate. Cancellation does not open it.
actor ContextTestGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        let pending = waiters
        waiters = []
        for waiter in pending { waiter.resume() }
    }
}

// Wait for observable registration, without a time delay.
func waitForContextListeners(_ signal: AbortSignal, _ count: Int) async {
    let deadline = ContinuousClock.now + .seconds(10)
    while signal.listenerCount != count {
        if ContinuousClock.now >= deadline {
            Issue.record("The listener count did not reach \(count).")
            return
        }
        await Task.yield()
    }
}

@Suite("Context")
struct ContextTests {
    @Test("provides distinct empty root contexts")
    func roots() {
        let key = ChordContextKey<String>("value")
        #expect(ChordContext.todo.description != ChordContext.background.description)
        #expect(ChordContext.todo.abortSignal == nil)
        #expect(ChordContext.todo.value(key) == nil)
        #expect(String(describing: ChordContext.background) == "[Context BACKGROUND_CONTEXT]")
        #expect(String(describing: ChordContext.todo) == "[Context TODO_CONTEXT]")
    }

    @Test("layers typed values without modifying parents")
    func values() {
        let firstKey = ChordContextKey<String>("first")
        let secondKey = ChordContextKey<Int>("second")
        let first = ChordContext.background.withValue("one", for: firstKey)
        let second = first.withValue(2, for: secondKey)
        let replaced = second.withValue("updated", for: firstKey)
        #expect(ChordContext.background.value(firstKey) == nil)
        #expect(first.value(firstKey) == "one")
        #expect(first.value(secondKey) == nil)
        #expect(second.value(firstKey) == "one")
        #expect(second.value(secondKey) == 2)
        #expect(replaced.value(firstKey) == "updated")
        #expect(second.value(firstKey) == "one")
        #expect(String(describing: replaced) == "[Context BACKGROUND_CONTEXT].WithValue(first).WithValue(second).WithValue(first)")
    }

    @Test("inherits parent cancellation and isolates child cancellation")
    func cancellation() throws {
        let controller = AbortController()
        let parent = ChordContext.background.withAbortSignal(controller.signal)
        let child = parent.withCancel()
        let sibling = parent.withCancel()
        let calls = Mutex(0)
        let signal = try #require(child.context.abortSignal)
        signal.addAbortListener { _ in calls.withLock { $0 += 1 } }
        child.cancel(ContextTestError(text: "child"))
        #expect(signal.aborted)
        #expect(signal.reason as? ContextTestError == ContextTestError(text: "child"))
        #expect(sibling.context.abortSignal?.aborted == false)
        #expect(parent.abortSignal?.aborted == false)
        #expect(calls.withLock { $0 } == 1)
        controller.abort(ContextTestError(text: "parent"))
        #expect(sibling.context.abortSignal?.aborted == true)
        #expect(sibling.context.abortSignal?.reason as? ContextTestError == ContextTestError(text: "parent"))
    }

    @Test("masks caller cancellation for mandatory cleanup")
    func cleanup() {
        let controller = AbortController()
        let key = ChordContextKey<String>("value")
        let context = ChordContext.background.withAbortSignal(controller.signal).withValue("preserved", for: key)
        let cleanup = context.withoutAbortSignal()
        controller.abort()
        #expect(context.abortSignal?.aborted == true)
        #expect(cleanup.abortSignal == nil)
        #expect(cleanup.value(key) == "preserved")
    }

    @Test("stops waiting when the invocation is cancelled")
    func stopsWaiting() async throws {
        let controller = AbortController()
        let context = ChordContext.background.withAbortSignal(controller.signal)
        let gate = ContextTestGate()
        let work = Task<String, Never> { await gate.wait(); return "completed later" }
        let waiting = Task { try await awaitWithContext(work, context) }
        await waitForContextListeners(controller.signal, 1)
        let cancellation = ContextTestError(text: "cancelled")
        controller.abort(cancellation)
        do {
            _ = try await waiting.value
            Issue.record("The waiter must throw.")
        } catch { #expect(error as? ContextTestError == cancellation) }
        #expect(!work.isCancelled)
        await gate.open()
        #expect(await work.value == "completed later")
        let completed = Task<String, Never> { "completed" }
        #expect(try await awaitWithContext(completed, .background) == "completed")
    }

    @Test("Keys with equal descriptions have distinct identities")
    func keyIdentity() {
        let first = ChordContextKey<String>("same")
        let second = ChordContextKey<String>("same")
        let context = ChordContext.background.withValue("first", for: first).withValue("second", for: second)
        #expect(context.value(first) == "first")
        #expect(context.value(second) == "second")
        #expect(context.value(ChordContextKey<String>("same")) == nil)
    }

    @Test("A nil value masks its parent value")
    func nilValue() {
        let key = ChordContextKey<String>("value")
        let parent = ChordContext.background.withValue("parent", for: key)
        let child = parent.withValue(nil, for: key)
        #expect(child.value(key) == nil)
        #expect(parent.value(key) == "parent")
    }

    @Test("Both task forms return results and remove listeners")
    func success() async throws {
        let controller = AbortController()
        let context = ChordContext.background.withAbortSignal(controller.signal)
        let unrelatedCalls = Mutex(0)
        let unrelated = controller.signal.addAbortListener { _ in unrelatedCalls.withLock { $0 += 1 } }
        defer { controller.signal.removeAbortListener(unrelated) }
        let baseline = controller.signal.listenerCount
        #expect(baseline == 1)
        let errorGate = ContextTestGate()
        let errorWork = Task<Int, any Error> { await errorGate.wait(); return 11 }
        let errorWaiter = Task { try await awaitWithContext(errorWork, context) }
        await waitForContextListeners(controller.signal, baseline + 1)
        await errorGate.open()
        #expect(try await errorWaiter.value == 11)
        #expect(controller.signal.listenerCount == baseline)
        let neverGate = ContextTestGate()
        let neverWork = Task<Int, Never> { await neverGate.wait(); return 12 }
        let neverWaiter = Task { try await awaitWithContext(neverWork, context) }
        await waitForContextListeners(controller.signal, baseline + 1)
        await neverGate.open()
        #expect(try await neverWaiter.value == 12)
        #expect(controller.signal.listenerCount == baseline)
        #expect(unrelatedCalls.withLock { $0 } == 0)
    }

    @Test("Work errors pass through and remove the listener")
    func failure() async {
        let controller = AbortController()
        let context = ChordContext.background.withAbortSignal(controller.signal)
        let gate = ContextTestGate()
        let failure = ContextTestError(text: "work failed")
        let work = Task<Int, any Error> { await gate.wait(); throw failure }
        let waiting = Task { try await awaitWithContext(work, context) }
        await waitForContextListeners(controller.signal, 1)
        await gate.open()
        do { _ = try await waiting.value; Issue.record("The waiter must throw.") }
        catch { #expect(error as? ContextTestError == failure) }
        #expect(controller.signal.listenerCount == 0)
        do { _ = try await awaitWithContext(work, .background); Issue.record("Work must throw.") }
        catch { #expect(error as? ContextTestError == failure) }
    }

    @Test("Abort removes both task waiters and leaves work active")
    func abortBothForms() async throws {
        let controller = AbortController()
        let context = ChordContext.background.withAbortSignal(controller.signal)
        let gate = ContextTestGate()
        let errorWork = Task<Int, any Error> { await gate.wait(); return 21 }
        let neverWork = Task<Int, Never> { await gate.wait(); return 22 }
        let first = Task { try await awaitWithContext(errorWork, context) }
        let second = Task { try await awaitWithContext(neverWork, context) }
        await waitForContextListeners(controller.signal, 2)
        let reason = ContextTestError(text: "stop")
        controller.abort(reason)
        for waiting in [first, second] {
            do { _ = try await waiting.value; Issue.record("The waiter must throw.") }
            catch { #expect(error as? ContextTestError == reason) }
        }
        #expect(controller.signal.listenerCount == 0)
        #expect(!errorWork.isCancelled)
        #expect(!neverWork.isCancelled)
        await gate.open()
        #expect(try await errorWork.value == 21)
        #expect(await neverWork.value == 22)
    }

    @Test("A signal aborted before the call rejects pending work at once")
    func alreadyAborted() async {
        let controller = AbortController()
        let reason = ContextTestError(text: "already stopped")
        controller.abort(reason)
        let context = ChordContext.background.withAbortSignal(controller.signal)
        let gate = ContextTestGate()
        let errorWork = Task<Int, any Error> { await gate.wait(); return 1 }
        let neverWork = Task<Int, Never> { await gate.wait(); return 2 }
        do { _ = try await awaitWithContext(errorWork, context); Issue.record("The waiter must throw.") }
        catch { #expect(error as? ContextTestError == reason) }
        do { _ = try await awaitWithContext(neverWork, context); Issue.record("The waiter must throw.") }
        catch { #expect(error as? ContextTestError == reason) }
        #expect(controller.signal.listenerCount == 0)
        #expect(!errorWork.isCancelled)
        #expect(!neverWork.isCancelled)
        await gate.open()
        _ = await errorWork.result
        _ = await neverWork.value
    }

    @Test("A context without a signal supports both task forms")
    func noSignal() async throws {
        let first = Task<Int, any Error> { 31 }
        let second = Task<Int, Never> { 32 }
        #expect(try await awaitWithContext(first, .background) == 31)
        #expect(try await awaitWithContext(second, .todo) == 32)
    }

    @Test("Swift cancellation alone does not end the wait")
    func cancelledWaiter() async throws {
        let controller = AbortController()
        let context = ChordContext.background.withAbortSignal(controller.signal)
        let gate = ContextTestGate()
        let work = Task<Int, Never> { await gate.wait(); return 41 }
        let waiting = Task { try await awaitWithContext(work, context) }
        await waitForContextListeners(controller.signal, 1)
        waiting.cancel()
        #expect(waiting.isCancelled)
        #expect(!controller.signal.aborted)
        #expect(controller.signal.listenerCount == 1)
        await gate.open()
        #expect(try await waiting.value == 41)
        #expect(controller.signal.listenerCount == 0)
    }

    @Test("The bridge handles task cancellation before its call")
    func bridgeBeforeCall() async throws {
        let parent = ChordContext.background.withCancel()
        let gate = ContextTestGate()
        let ready = ContextTestGate()
        let waiting = Task {
            await ready.open()
            await gate.wait()
            return await withTaskCancellationContext(parent.context) { child in
                #expect(child.abortSignal?.aborted == true)
                #expect(child.abortSignal?.reason is CancellationError)
                return 51
            }
        }
        await ready.wait()
        waiting.cancel()
        await gate.open()
        #expect(await waiting.value == 51)
        #expect(parent.context.abortSignal?.aborted == false)
    }

    @Test("The bridge handles task cancellation after its call")
    func bridgeAfterCall() async throws {
        let parent = ChordContext.background.withCancel()
        let ready = ContextTestGate()
        let gate = ContextTestGate()
        let childSignal = Mutex<AbortSignal?>(nil)
        let waiting = Task {
            await withTaskCancellationContext(parent.context) { child in
                childSignal.withLock { $0 = child.abortSignal }
                await ready.open()
                await gate.wait()
                #expect(child.abortSignal?.aborted == true)
                #expect(child.abortSignal?.reason is CancellationError)
                return 52
            }
        }
        await ready.wait()
        waiting.cancel()
        #expect(childSignal.withLock { $0?.aborted } == true)
        #expect(parent.context.abortSignal?.aborted == false)
        await gate.open()
        #expect(await waiting.value == 52)
    }
}
