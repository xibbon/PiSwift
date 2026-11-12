import Foundation
import Synchronization
import Testing
import PiSwiftAI
import PiSwiftChord
@testable import PiSwiftDurable
import PiSwiftDurableTesting

@Suite("PiSwiftDurableTests.D6NestedHistory", .timeLimit(.minutes(1)))
struct D6NestedHistoryTests {
    // v1.5.2 harness-nested-tools.test.ts:393–398,476–486,825–829.
    @Test func nestedSlotsStartAndEndInOwnershipOrder() async throws {
        let setup = HarnessChatSetup(), log = HarnessLiveDeltaLog()
        try installHarnessTool(harnessTestTool("deep", execute: { _, _, _ in
            .init(output: [.text(.init(text: "deep"))])
        }), setup: setup)
        try installHarnessTool(harnessTestTool("inner", execute: { _, api, context in
            let result = try await api.executeTool("deep", arguments: [:], context: context, options: .init(key: "x"))
            return .init(output: [.text(.init(text: result.structuredOutput?.stringValue ?? "missing"))])
        }), setup: setup)
        try installHarnessTool(harnessTestTool("outer", execute: { _, api, context in
            let result = try await api.executeTool("inner", arguments: [:], context: context)
            return .init(output: [.text(.init(text: result.structuredOutput?.stringValue ?? "missing"))])
        }), setup: setup)
        setup.models.setResponses([.message(try toolCalls([("outer", [:], "c1")])), .message(chatAssistant("done"))])
        let opened = try await openChat(setup: setup)
        let subscription = try opened.harness.subscribeCommits { publication, _ in log.append(publication) }
        let settled = try await opened.root.submit(.input(content: .text("go")), context: .background).wait(context: .background)
        #expect(settled.status == "done")
        let states = try log.values.map { try JSONValue.object($0.2).decode(LiveState.self) }
        #expect(states.first?.nestedTools == nil)
        var began: [String] = [], ended: [String] = []
        for state in states {
            let slots = (state.tools ?? []).map { ($0.callId, $0.status) } + (state.nestedTools ?? []).map { ($0.callId, $0.status) }
            for (id, status) in slots {
                if status == .running && !began.contains(id) { began.append(id) }
                if status == .done && !ended.contains(id) { ended.append(id) }
            }
        }
        #expect(began == ["c1", "c1/1", "c1/1/x"])
        #expect(ended == ["c1/1/x", "c1/1", "c1"])
        let tasks = try await d4bToolTasks(opened.harness)
        let outer = try #require(tasks.first { $0.input["callId"] == "c1" })
        let inner = try #require(tasks.first { $0.input["call"]?["id"] == "c1/1" })
        let deep = try #require(tasks.first { $0.input["call"]?["id"] == "c1/1/x" })
        #expect(inner.owner == outer.id && deep.owner == inner.id)
        let nestedSlots = states.flatMap { $0.nestedTools ?? [] }
        let innerSlot = try #require(nestedSlots.first { $0.callId == "c1/1" })
        let deepSlot = try #require(nestedSlots.first { $0.callId == "c1/1/x" })
        #expect(innerSlot.taskId == inner.id && innerSlot.parentTaskId == outer.id && innerSlot.parentCallId == "c1")
        #expect(deepSlot.taskId == deep.id && deepSlot.parentTaskId == inner.id && deepSlot.parentCallId == "c1/1")
        #expect(try await generationLive(opened) == LiveState())
        subscription.cancel(); try await opened.harness.close(context: .background)
    }

    // v1.5.2 harness-nested-tools.test.ts:867–end of late-subscriber case.
    @Test func lateSubscriberReplaysTwoRunningNestedSlots() async throws {
        let setup = HarnessChatSetup(), one = HarnessChatSignal(), two = HarnessChatSignal(), release = HarnessChatSignal()
        try installHarnessTool(harnessTestTool("slow", execute: { args, api, context in
            let label = args["text"]?.stringValue ?? "?"
            try api.output(.text("\(label)\n"), nil)
            try await api.details(.object(["label": .string(label)]), context)
            if label == "one" { one.signal() } else { two.signal() }
            await release.wait()
            return .init(output: [.text(.init(text: label))])
        }), setup: setup)
        try installHarnessTool(harnessTestTool("outer", execute: { _, api, context in
            let first = Task { try await api.executeTool("slow", arguments: ["text": "one"], context: context, options: .init(key: "one")) }
            await one.wait()
            let second = Task { try await api.executeTool("slow", arguments: ["text": "two"], context: context, options: .init(key: "two")) }
            _ = try await [first.value, second.value]
            return .init(output: [])
        }), setup: setup)
        setup.models.setResponses([.message(try toolCalls([("outer", [:], "c1")])), .message(chatAssistant("done"))])
        let opened = try await openChat(setup: setup)
        let submission = try await opened.root.submit(.input(content: .text("go")), context: .background)
        await one.wait(); await two.wait()
        let watch = try await opened.root.watch(context: .background)
        let initial = watch.value
        let live = try JSONValue.object(#require(initial.docs["pi.live"])).decode(LiveState.self)
        let initialSlots = try #require(live.nestedTools)
        #expect(initialSlots.map { [$0.callId, $0.status.rawValue] } ==
                [["c1/one", "running"], ["c1/two", "running"]])
        let frames = Mutex<[(ConversationView, [Delta.Op])]>([])
        try watch.start { call, _ in
            guard case .value(let value, let ops, _) = call else { Issue.record("Nested view watch failed"); return }
            frames.withLock { $0.append((value, ops)) }
        }
        release.signal()
        #expect(try await submission.wait(context: .background).status == "done")
        try await eventually { try await generationLive(opened) == LiveState() }
        try await eventually {
            let current = watch.value
            guard let doc = current.docs["pi.live"],
                  try JSONValue.object(doc).decode(LiveState.self) == LiveState() else { return false }
            return frames.withLock { $0.last?.0 == current }
        }
        await watch.waitUntilIdle()
        var replayed = try JSONValue(encoding: initial)
        for (value, ops) in frames.withLock({ $0 }) {
            replayed = try #require(try Delta.applyImmutable(replayed, ops))
            #expect(try replayed.decode(ConversationView.self) == value)
        }
        #expect(!frames.withLock { $0.isEmpty })
        let final = try replayed.decode(ConversationView.self)
        let finalLive = try #require(final.docs["pi.live"])
        #expect(try JSONValue.object(finalLive).decode(LiveState.self) == LiveState())
        #expect(try JSONValue(encoding: final) == JSONValue(encoding: watch.value))
        _ = await watch.stop()
        try await opened.harness.close(context: .background)
    }
}
