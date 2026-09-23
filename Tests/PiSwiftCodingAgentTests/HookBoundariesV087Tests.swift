import Foundation
import Testing
import PiSwiftAI
import PiSwiftAgent
@testable import PiSwiftCodingAgent

private func boundaryRunner(_ api: HookAPI) -> HookRunner {
    let hook = LoadedHook(path: "boundary-test", resolvedPath: "boundary-test", handlers: api.handlers,
                          currentHandlers: { api.handlers })
    return HookRunner([hook], "/tmp", SessionManager.inMemory("/tmp"), ModelRegistry(AuthStorage(":memory:")))
}

private enum BoundaryTestError: Error { case invalid }

@Suite struct HookBoundariesV087Tests {
    @Test func boundaryPreviewsEachDraftAndPassesContinuation() async throws {
        let api = HookAPI()
        let observations = LockedState<[String]>([])
        api.on("turn_end") { (event: TurnEndEvent, _: HookContext) in
            observations.withLock { $0.append("handler-1:\(event.entries.count)") }
            return BoundaryResult(entries: [.custom(customType: "note", data: nil)], shouldContinue: true)
        }
        api.on("turn_end") { (event: TurnEndEvent, _: HookContext) in
            observations.withLock { $0.append("handler-2:\(event.entries.count):\(event.shouldContinue)") }
            #expect(event.context.canContinue)
            return nil
        }
        let runner = boundaryRunner(api)
        let event = TurnEndBoundaryBaseEvent(turnIndex: 0, message: .user(UserMessage(content: .text("hello"))),
                                 toolResults: [], messageEntryId: "m1", toolResultEntryIds: [], outcome: .completed)
        let result = try await runner.emitBoundary(event) { drafts in
            observations.withLock { $0.append("preview:\(drafts.count)") }
            return BoundaryContextPreview(contextEntries: [], contextMessages: [], llmMessages: [], pendingMessages: [], canContinue: true)
        }
        #expect(result.entries.count == 1)
        #expect(result.shouldContinue)
        #expect(result.valid)
        #expect(observations.withLock { $0 } == ["preview:0", "handler-1:0", "preview:1", "handler-2:1:true", "preview:1"])
    }

    @Test func invalidBoundaryDraftCanBeRepairedByLaterHandler() async throws {
        let api = HookAPI()
        let errors = LockedState<[String]>([])
        api.on("agent_before_settle") { (_: AgentBeforeSettleEvent, _: HookContext) in
            BoundaryResult(entries: [.contextEdit(targetId: "missing", replacement: nil)])
        }
        api.on("agent_before_settle") { (event: AgentBeforeSettleEvent, _: HookContext) in
            #expect(event.entries.count == 1)
            return BoundaryResult(entries: [])
        }
        let runner = boundaryRunner(api)
        let stop = runner.onError { error in errors.withLock { $0.append(error.error) } }
        defer { stop() }
        let result = try await runner.emitBoundary(AgentBeforeSettleBoundaryBaseEvent(outcome: .completed)) { drafts in
            if !drafts.isEmpty { throw BoundaryTestError.invalid }
            return BoundaryContextPreview(contextEntries: [], contextMessages: [], llmMessages: [], pendingMessages: [], canContinue: false)
        }
        #expect(result.valid)
        #expect(result.entries.isEmpty)
        #expect(errors.withLock { $0.count } == 1)
    }

    @Test func handlerMutationAppliesOnNextDispatch() async {
        let api = HookAPI()
        let calls = LockedState<[String]>([])
        let unsubscribe = LockedState<(@Sendable () -> Void)?>(nil)
        let first = api.on("agent_end") { (_: AgentEndEvent, _: HookContext) in
            calls.withLock { $0.append("first") }
            unsubscribe.withLock { $0?() }
            api.on("agent_end") { (_: AgentEndEvent, _: HookContext) in
                calls.withLock { $0.append("late") }
                return nil
            }
            return nil
        }
        unsubscribe.withLock { $0 = first }
        api.on("agent_end") { (_: AgentEndEvent, _: HookContext) in
            calls.withLock { $0.append("second") }
            return nil
        }
        let runner = boundaryRunner(api)
        _ = await runner.emit(AgentEndEvent(messages: []))
        #expect(calls.withLock { $0 } == ["first", "second"])
        _ = await runner.emit(AgentEndEvent(messages: []))
        #expect(calls.withLock { $0 } == ["first", "second", "second", "late"])
    }

    @Test func nestedDispatchTakesFreshHandlerSnapshot() async {
        let api = HookAPI()
        let calls = LockedState<[String]>([])
        let depth = LockedState(0)
        let runnerRef = LockedState<HookRunner?>(nil)
        api.on("agent_end") { (_: AgentEndEvent, _: HookContext) in
            let current = depth.withLock { value -> Int in value += 1; return value }
            calls.withLock { $0.append("first:\(current)") }
            if current == 1 {
                api.on("agent_end") { (_: AgentEndEvent, _: HookContext) in
                    calls.withLock { $0.append("late") }
                    return nil
                }
                if let runner = runnerRef.withLock({ $0 }) {
                    _ = await runner.emit(AgentEndEvent(messages: []))
                }
            }
            return nil
        }
        api.on("agent_end") { (_: AgentEndEvent, _: HookContext) in
            calls.withLock { $0.append("second") }
            return nil
        }
        let runner = boundaryRunner(api)
        runnerRef.withLock { $0 = runner }
        _ = await runner.emit(AgentEndEvent(messages: []))
        #expect(calls.withLock { $0 } == ["first:1", "first:2", "second", "late", "second"])
    }

    @Test func userBashFailureStopsDispatch() async {
        let api = HookAPI()
        let reached = LockedState(false)
        api.on("user_bash") { (_: UserBashEvent, _: HookContext) in throw BoundaryTestError.invalid }
        api.on("user_bash") { (_: UserBashEvent, _: HookContext) in
            reached.withLock { $0 = true }
            return nil
        }
        let runner = boundaryRunner(api)
        do {
            _ = try await runner.emitUserBash(UserBashEvent(command: "pwd", excludeFromContext: false, cwd: "/tmp"))
            Issue.record("A failed bash handler must abort execution.")
        } catch {}
        #expect(!reached.withLock { $0 })
    }

    @Test func userBashRejectsDefinedInvalidResult() async {
        let api = HookAPI()
        api.on("user_bash") { (_: UserBashEvent, _: HookContext) in UserBashEventResult() }
        let runner = boundaryRunner(api)
        do {
            _ = try await runner.emitUserBash(UserBashEvent(command: "pwd", excludeFromContext: false, cwd: "/tmp"))
            Issue.record("An empty result must fail closed.")
        } catch HookDispatchError.invalidUserBashResult {}
        catch { Issue.record("Unexpected error: \(error)") }
    }

    @Test func contextPhasesRestoreSystemAndReportMissingLeadingPrompt() async {
        let api = HookAPI()
        let errors = LockedState<[String]>([])
        api.on("context") { (event: ContextEvent, _: HookContext) in
            #expect(event.messages.allSatisfy { $0.role != "system" })
            return ContextEventResult(messages: [])
        }
        api.on("context_with_system") { (event: ContextWithSystemEvent, _: HookContext) in
            #expect(event.messages.first?.role == "system")
            return ContextEventResult(messages: [])
        }
        let runner = boundaryRunner(api)
        let stop = runner.onError { error in errors.withLock { $0.append(error.event) } }
        defer { stop() }
        let messages: [AgentMessage] = [.system(SystemMessage(content: .text("prompt"))), .user(UserMessage(content: .text("hello")))]
        let result = await runner.emitContext(messages)
        #expect(result.isEmpty)
        #expect(errors.withLock { $0 } == ["context_with_system"])
    }
}
