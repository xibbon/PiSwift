import Foundation
import PiSwiftAI
import PiSwiftChord
import PiSwiftDurableTesting
import Synchronization
import Testing
@testable import PiSwiftDurable

// Direct ports of the key and settlement cases in harness-park-children.test.ts.
@Suite(.timeLimit(.minutes(1)))
struct HarnessParkChildrenD3bTests {
    @Test func abandonsTheParkedChildrenOfAReplayUnsafeCallCutOffWhileItRan() async throws {
        let directory = try sqliteTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("cut-off-children.sqlite").path
        let setup = HarnessChatSetup()
        let started = HarnessChatSignal()
        let done: SignalToken<JSONValue> = try defineSignal(name: "test.cut-off-done", version: 1,
            schema: ["type": "object", "properties": ["text": ["type": "string"]], "required": ["text"]])
        let research = try ToolRegistration(name: "research", description: "research", parameters: ["type": "object"],
            replay: .safe, execute: { _, api, context in
                if case .value = try await api.readSignal(done, key: "done", context: context) {
                    return .result(.init(output: []))
                }
                return .park(.sleep(signals: [try done.key("done")]))
            })
        try installHarnessTool(research, setup: setup)
        let unsafe = try ToolRegistration(name: "unsafe", description: "unsafe", parameters: ["type": "object"],
            execute: { _, api, context in
                _ = try await api.executeTool("research", arguments: [:], context: context, wait: false, key: "a")
                started.signal()
                try await harnessToolAwaitAbort(context)
                return .result(.init(output: []))
            })
        try installHarnessTool(unsafe, setup: setup)
        setup.models.setResponses([.message(try toolCalls([("unsafe", [:], "c1")])), .message(chatAssistant("done"))])
        let first = try await openChat(storage: SqliteStorage.open(path: path), setup: setup)
        try first.harness.resume()
        let submissionID = try await first.root.submit(.input(content: .text("go")), context: .background).id
        await started.wait()
        try await harnessEventually { try await generationLive(first)?.nestedTools?.first?.status == .sleeping }
        let child = try #require(try await generationLive(first)?.nestedTools?.first?.taskId)
        let second = try await openChat(storage: SqliteStorage.open(path: path), setup: setup)
        try second.harness.resume()
        let submission = try #require(try await second.harness.submission(id: submissionID, context: .background))
        #expect(try await submission.wait(context: .background).status == "done")
        let ended = try await second.harness.waitForTask(id: child, context: .background)
        #expect(ended.record.abortReason == .restart)
        #expect(ended.outcome.status == "aborted")
        try await second.harness.close(context: .background)
        try await first.harness.close(context: .background)
    }

    @Test func keepsTheChildrenOfAParkedReplayUnsafeCall() async throws {
        let directory = try sqliteTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("parked-children.sqlite").path
        let setup = HarnessChatSetup()
        let done: SignalToken<JSONValue> = try defineSignal(name: "test.restart-done", version: 1,
            schema: ["type": "object", "properties": ["text": ["type": "string"]], "required": ["text"]])
        let research = try ToolRegistration(name: "research", description: "research", parameters: ["type": "object"],
            replay: .safe, execute: { _, api, context in
                if case .value(let value) = try await api.readSignal(done, key: "done", context: context) {
                    return .result(.init(output: [.text(.init(text: value["text"]?.stringValue ?? ""))]))
                }
                return .park(.sleep(signals: [try done.key("done")]))
            })
        try installHarnessTool(research, setup: setup)
        let unsafe = try ToolRegistration(name: "unsafe", description: "unsafe", parameters: ["type": "object"],
            execute: { _, api, context in
                let nested = try await api.executeTool("research", arguments: [:], context: context, wait: false, key: "a")
                if api.wake == nil { return .park(.wait(on: [nested.taskId], policy: .allSettled)) }
                let result = try await nested.result(context: context)
                return .result(.init(output: [.text(.init(text: result.structuredOutput?.stringValue ?? ""))]))
            })
        try installHarnessTool(unsafe, setup: setup)
        setup.models.setResponses([.message(try toolCalls([("unsafe", [:], "c1")])), .message(chatAssistant("done"))])
        let first = try await openChat(storage: SqliteStorage.open(path: path), setup: setup)
        try first.harness.resume()
        let submissionID = try await first.root.submit(.input(content: .text("go")), context: .background).id
        try await harnessEventually { try await generationLive(first)?.tools?.first?.status == .waiting }
        let child = try #require(try await generationLive(first)?.nestedTools?.first?.taskId)
        try await first.harness.close(context: .background)
        let second = try await openChat(storage: SqliteStorage.open(path: path), setup: setup)
        try second.harness.resume()
        try await harnessEventually { try await second.harness.getTask(id: child, context: .background)?.state.status == "sleeping" }
        #expect(try await second.harness.getTask(id: child, context: .background)?.abortRequested == false)
        #expect(try await second.harness.signal(taskId: child, token: done, key: "done",
            value: ["text": "kept"], context: .background) == .delivered)
        let submission = try #require(try await second.harness.submission(id: submissionID, context: .background))
        #expect(try await submission.wait(context: .background).status == "done")
        #expect(try harnessToolText(#require(harnessToolResults(await allEntries(second.root)).first)) == "kept")
        try await second.harness.close(context: .background)
    }

    @Test func needExplicitKeysAfterAWakeForNestedCallsAndTasksAlike() async throws {
        let setup = HarnessChatSetup()
        let child = harnessOneStep("test.idle") { _, runtime, context in
            try await runtime.commit({ _, _ in try completed(1) }, context: context)
        }
        try setup.registry.install(Extension(name: "idle-child", tasks: [AnyTaskDefinition(child)]))
        let errors = Mutex<[String]>([])
        let woken = try ToolRegistration(name: "woken", description: "woken", parameters: ["type": "object"],
            execute: { _, api, context in
                if api.wake == nil { return .park(.sleep(until: 0)) }
                do { _ = try await api.executeTool("woken", arguments: [:], context: context, wait: false) }
                catch { errors.withLock { $0.append(String(describing: error)) } }
                do { _ = try await api.createTask(child, input: 0,
                    options: .init(ownership: .task(taskId: api.taskId)), context: context) }
                catch { errors.withLock { $0.append(String(describing: error)) } }
                return .result(.init(output: []))
            })
        try installHarnessTool(woken, setup: setup)
        let (_, _) = try await runHarnessTools(setup, calls: [("woken", [:], "c1")])
        #expect(errors.withLock { $0 } == [
            "Tool call c1 needs explicit keys after a wake", "Tool call c1 needs explicit keys after a wake"
        ])
    }

    @Test func parkOnHandlesWithPolicyAnyAndCollectResultsByKeyAcrossWakes() async throws {
        let setup = HarnessChatSetup()
        let done: SignalToken<JSONValue> = try defineSignal(name: "test.done", version: 1,
            schema: ["type": "object", "properties": ["text": ["type": "string"]], "required": ["text"]])
        let research = try ToolRegistration(name: "research", description: "research", parameters: ["type": "object"],
            replay: .safe, execute: { args, api, context in
                if case .value(let value) = try await api.readSignal(done, key: "done", context: context) {
                    return .result(.init(output: [.text(.init(text: "\(args["topic"]?.stringValue ?? ""): \(value["text"]?.stringValue ?? "")"))]))
                }
                return .park(.sleep(signals: [try done.key("done")]))
            })
        try installHarnessTool(research, setup: setup)
        let wakes = Mutex<[WakeReason?]>([])
        let both = try ToolRegistration(name: "both", description: "both", parameters: ["type": "object"],
            replay: .safe, execute: { _, api, context in
                wakes.withLock { $0.append(api.wake) }
                let a = try await api.executeTool("research", arguments: ["topic": "x"], context: context, wait: false, key: "a")
                let b = try await api.executeTool("research", arguments: ["topic": "y"], context: context,
                                                   options: .init(wait: false, key: "b"))
                var open: [TaskID] = []
                for id in [a.taskId, b.taskId] {
                    if try await api.getTask(id: id, context: context)?.state.status != "terminal" { open.append(id) }
                }
                if !open.isEmpty { return .park(.wait(on: open, policy: .any)) }
                let ra = try await a.result(context: context)
                let rb = try await b.result(context: context)
                return .result(.init(output: [.text(.init(text: "\(ra.structuredOutput?.stringValue ?? "") + \(rb.structuredOutput?.stringValue ?? "")"))]))
            })
        try installHarnessTool(both, setup: setup)
        setup.models.setResponses([.message(try toolCalls([("both", [:], "c1")])), .message(chatAssistant("done"))])
        let chat = try await openChat(setup: setup)
        try chat.harness.resume()
        let submission = try await chat.root.submit(.input(content: .text("go")), context: .background)
        try await harnessEventually { try await generationLive(chat)?.nestedTools?.count == 2 }
        let slots = try #require(try await generationLive(chat)?.nestedTools)
        let a = try #require(slots.first { $0.callId == "c1/a" }?.taskId)
        let b = try #require(slots.first { $0.callId == "c1/b" }?.taskId)
        #expect(try await chat.harness.signal(taskId: b, token: done, key: "done", value: ["text": "bee"], context: .background) == .delivered)
        try await harnessEventually {
            let ended = try await chat.harness.getTask(id: b, context: .background)?.state.status == "terminal"
            let waiting = try await generationLive(chat)?.tools?.first?.status == .waiting
            return ended && waiting && wakes.withLock { $0.count } == 2
        }
        #expect(try await chat.harness.signal(taskId: a, token: done, key: "done", value: ["text": "ay"], context: .background) == .delivered)
        #expect(try await submission.wait(context: .background).status == "done")
        #expect(try harnessToolText(#require(harnessToolResults(await allEntries(chat.root)).first)) == "x: ay + y: bee")
        #expect(wakes.withLock { $0.count } == 3)
        try await chat.harness.close(context: .background)
    }

    @Test func returnTheTaskAKeyNamesAndRefuseAnotherInputOrNestedCallKey() async throws {
        let setup = HarnessChatSetup()
        let child = harnessOneStep("test.keyed") { _, runtime, context in
            try await runtime.commit({ _, _ in try completed(1) }, context: context)
        }
        try setup.registry.install(Extension(name: "keyed-child", tasks: [AnyTaskDefinition(child)]))
        try installHarnessTool(try ToolRegistration(name: "research", description: "research",
            parameters: ["type": "object"], execute: { _, _, _ in .result(.init(output: [])) }), setup: setup)
        let ids = Mutex<[TaskID]>([])
        let errors = Mutex<[String]>([])
        let tool = try ToolRegistration(name: "keyed", description: "keyed", parameters: ["type": "object"],
            execute: { _, api, context in
                let own = TaskOptions(ownership: .task(taskId: api.taskId), key: "k")
                let first = try await api.createTask(child, input: 1, options: own, context: context)
                let again = try await api.createTask(child, input: 1, options: own, context: context)
                ids.withLock { $0 = [first, again] }
                do { _ = try await api.createTask(child, input: 2, options: own, context: context) }
                catch { errors.withLock { $0.append(String(describing: error)) } }
                _ = try await api.executeTool("research", arguments: [:], context: context, wait: false, key: "n")
                do { _ = try await api.createTask(child, input: 1,
                    options: .init(ownership: .task(taskId: api.taskId), key: "n"), context: context) }
                catch { errors.withLock { $0.append(String(describing: error)) } }
                do { _ = try await api.executeTool("research", arguments: [:], context: context, wait: false, key: "k") }
                catch { errors.withLock { $0.append(String(describing: error)) } }
                return .result(.init(output: []))
            })
        try installHarnessTool(tool, setup: setup)
        let (_, _) = try await runHarnessTools(setup, calls: [("keyed", [:], "c1")])
        #expect(ids.withLock { $0.count == 2 && $0[0] == $0[1] })
        #expect(errors.withLock { $0 } == [
            "Key k of tool call c1 was already used for another call or task",
            "Key n of tool call c1 was already used for another call or task",
            "Nested call c1/k was already made with another tool or other arguments"
        ])
    }

    @Test func deliverSubmissionSettledInTheSettlingCommit() async throws {
        let setup = HarnessChatSetup()
        let storage = ControlledStorage()
        let chat = try await openChat(storage: storage, setup: setup)
        let child = harnessOneStep("test.waiter") { task, runtime, context in
            let first = try await runtime.readSignal(SubmissionSettled, key: "one", context: context)
            let second = try await runtime.readSignal(SubmissionSettled, key: "two", context: context)
            guard case .value = first, case .value = second else {
                try await runtime.sleep(signals: [SubmissionSettled.key("one"), SubmissionSettled.key("two")],
                                        checkpoint: JSONValue(encoding: task.checkpoint), context: context)
                return
            }
            try await runtime.commit({ _, _ in try completed(1) }, context: context)
        }
        try setup.registry.install(Extension(name: "waiter", tasks: [AnyTaskDefinition(child)]))
        let taskId = try await chat.root.commit({ tx in
            try await tx.createTask(child, input: 0, options: .init(ownership: .conversation()))
        }, context: .background)
        try await chat.root.commit({ tx in
            let first = try await tx.appendEntry(chat.root.id, value: EntryDraft(kind: "note"))
            let second = try await tx.appendEntry(chat.root.id, value: EntryDraft(kind: "note"))
            _ = try await tx.createSubmission(.write(conversationId: chat.root.id,
                notify: .init(taskId: taskId, key: "one"), state: .done(entry: first.id)))
            _ = try await tx.createSubmission(.write(conversationId: chat.root.id,
                notify: .init(taskId: taskId, key: "two"), state: .done(entry: second.id)))
        }, context: .background)
        let record = try #require(try await chat.harness.getTask(id: taskId, context: .background))
        #expect(record.memos?["pi.signal.pi.submission-settled/one"] != nil)
        #expect(record.memos?["pi.signal.pi.submission-settled/two"] != nil)
        let batches = await storage.commits
        let sameCommit = batches.contains { batch in
            var submissions = 0
            var taskWrites = 0
            for write in batch {
                switch write {
                case .submission(let value, _): if value.status == "done" { submissions += 1 }
                case .task(let value, _): if value.id == taskId { taskWrites += 1 }
                default: break
                }
            }
            return submissions == 2 && taskWrites == 1
        }
        #expect(sameCommit)
        try chat.harness.resume()
        #expect(try await chat.harness.waitForTask(id: taskId, context: .background).outcome.status == "completed")
        try await chat.harness.close(context: .background)
    }

    @Test func refuseADeliveryOfSubmissionSettledThatIsNotASettledRecord() async throws {
        let chat = try await openChat(setup: HarnessChatSetup())
        let child = harnessOneStep("test.signal-target") { _, runtime, context in
            try await runtime.commit({ _, _ in try completed(1) }, context: context)
        }
        let id = try await chat.root.commit({ tx in
            try await tx.createTask(child, input: 0, options: .init(ownership: .conversation()))
        }, context: .background)
        let queued = SubmissionRecord.write(id: try SubmissionID(2), conversationId: chat.root.id,
                                            requestId: nil, state: .queued())
        #expect(try await chat.harness.signal(taskId: id, token: SubmissionSettled,
                                             key: "settled", value: SettledSubmission(queued), context: .background) == .invalid)
        try await chat.harness.close(context: .background)
    }

    @Test func settleWithoutFailingWhenTheTaskToNotifyIsGone() async throws {
        let chat = try await openChat(setup: HarnessChatSetup())
        let write = try await chat.root.submit(.write(entry: EntryDraft(kind: "note"),
            notify: .init(taskId: try TaskID(999_999), key: "settled")), context: .background)
        #expect(try await write.wait(context: .background).status == "done")
        try await chat.harness.close(context: .background)
    }

    @Test func deliverItForASubmissionCreatedSettledBeforeTheTaskRan() async throws {
        let setup = HarnessChatSetup()
        let chat = try await openChat(setup: setup)
        let child = harnessOneStep("test.late-waiter") { _, runtime, context in
            guard case .value(let settled) = try await runtime.readSignal(SubmissionSettled, key: "settled", context: context) else {
                throw TaskDefinitionError("Settlement signal was lost")
            }
            #expect(settled.status == "done")
            try await runtime.commit({ _, _ in try completed(1) }, context: context)
        }
        let id = try await chat.root.commit({ tx in
            try await tx.createTask(child, input: 0, options: .init(ownership: .conversation()))
        }, context: .background)
        let write = try await chat.root.submit(.write(entry: EntryDraft(kind: "note"),
            notify: .init(taskId: id, key: "settled")), context: .background)
        #expect(try await write.status(context: .background).status == "done")
        #expect(try await chat.harness.getTask(id: id, context: .background)?.startedAt == nil)
        try setup.registry.install(Extension(name: "late-waiter", tasks: [AnyTaskDefinition(child)]))
        try chat.harness.resume()
        #expect(try await chat.harness.waitForTask(id: id, context: .background).outcome.status == "completed")
        try await chat.harness.close(context: .background)
    }

    @Test func deliverSubmissionSettledInTheCommitThatSettlesTheSubmission() async throws {
        let setup = HarnessChatSetup()
        let storage = ControlledStorage()
        let child = harnessOneStep("test.settlement-waiter") { task, runtime, context in
            switch task.checkpoint.phase {
            case .run:
                var next = task.checkpoint
                next.phase = .joined
                try await runtime.sleep(signals: [SubmissionSettled.key("settled")],
                                        checkpoint: JSONValue(encoding: next), context: context)
            case .joined:
                guard case .value(let record) = try await runtime.readSignal(SubmissionSettled,
                    key: "settled", context: context) else { throw TaskDefinitionError("No settlement signal") }
                #expect(record.status == "done")
                try await runtime.commit({ _, _ in try completed(1) }, context: context)
            }
        }
        try setup.registry.install(Extension(name: "settlement-waiter", tasks: [AnyTaskDefinition(child)]))
        let chat = try await openChat(storage: storage, setup: setup)
        let waiter = try await chat.root.commit({ tx in
            try await tx.createTask(child, input: 0, options: .init(ownership: .conversation()))
        }, context: .background)
        try chat.harness.resume()
        try await harnessEventually { try await chat.harness.getTask(id: waiter, context: .background)?.state.status == "sleeping" }
        let submission = try await chat.root.commit({ tx in
            try await tx.createSubmission(.write(conversationId: chat.root.id,
                notify: .init(taskId: waiter, key: "settled"))).id
        }, context: .background)
        try await chat.root.commit({ tx in
            let entry = try await tx.appendEntry(chat.root.id, value: EntryDraft(kind: "note"))
            try tx.placeSubmission(submission, entry: entry.id)
        }, context: .background)
        let batches = await storage.commits
        let settling = batches.first { batch in
            batch.contains { write in
                if case .submission(let value, _) = write { return value.id == submission && value.status == "done" }
                return false
            }
        }
        #expect(settling?.contains { write in
            if case .task(let value, _) = write { return value.id == waiter && value.memos?["pi.signal.pi.submission-settled/settled"] != nil }
            return false
        } == true)
        #expect(try await chat.harness.waitForTask(id: waiter, context: .background).outcome.status == "completed")
        try await chat.harness.close(context: .background)
    }

    @Test func composeInOneCommitTwoQueuedWritesSignalOneTaskUnderTwoKeys() async throws {
        let setup = HarnessChatSetup()
        let storage = ControlledStorage()
        let keys = (0..<16).map { "key\($0)" }
        let child = harnessOneStep("test.many-notifications") { task, runtime, context in
            switch task.checkpoint.phase {
            case .run:
                var next = task.checkpoint
                next.phase = .joined
                try await runtime.sleep(signals: try keys.map { try SubmissionSettled.key($0) },
                                        checkpoint: JSONValue(encoding: next), context: context)
            case .joined:
                try await runtime.commit({ _, _ in try completed(1) }, context: context)
            }
        }
        try setup.registry.install(Extension(name: "many-notifications", tasks: [AnyTaskDefinition(child)]))
        let chat = try await openChat(storage: storage, setup: setup)
        let waiter = try await chat.root.commit({ tx in
            try await tx.createTask(child, input: 0, options: .init(ownership: .conversation()))
        }, context: .background)
        try chat.harness.resume()
        try await harnessEventually { try await chat.harness.getTask(id: waiter, context: .background)?.state.status == "sleeping" }
        var submissions: [SubmissionID] = []
        for key in keys {
            let id = try await chat.root.commit({ tx in
                try await tx.createSubmission(.write(conversationId: chat.root.id,
                    notify: .init(taskId: waiter, key: key))).id
            }, context: .background)
            submissions.append(id)
        }
        try await chat.root.commit({ tx in
            for id in submissions {
                let entry = try await tx.appendEntry(chat.root.id, value: EntryDraft(kind: "note"))
                try tx.placeSubmission(id, entry: entry.id)
            }
        }, context: .background)
        let batches = await storage.commits
        let placing = batches.first { batch in
            var done = 0
            for write in batch {
                if case .submission(let record, _) = write, submissions.contains(record.id), record.status == "done" { done += 1 }
            }
            return done == keys.count
        }
        let writes = placing?.compactMap { write -> TaskRecord? in
            if case .task(let record, _) = write, record.id == waiter { return record }
            return nil
        } ?? []
        #expect(writes.count == 1)
        #expect(keys.allSatisfy { writes.first?.memos?["pi.signal.pi.submission-settled/\($0)"] != nil })
        try await chat.harness.close(context: .background)
    }

    @Test func settlementRacingTheTaskSleepCommitNeverLosesTheWake() async throws {
        let setup = HarnessChatSetup()
        let storage = ControlledStorage()
        let started = HarnessChatSignal()
        let release = HarnessChatSignal()
        let child = harnessOneStep("test.racing-notification") { task, runtime, context in
            switch task.checkpoint.phase {
            case .run:
                started.signal()
                await release.wait()
                var next = task.checkpoint
                next.phase = .joined
                try await runtime.sleep(signals: [SubmissionSettled.key("settled")],
                                        checkpoint: JSONValue(encoding: next), context: context)
            case .joined:
                guard case .value = try await runtime.readSignal(SubmissionSettled, key: "settled", context: context) else {
                    throw TaskDefinitionError("The racing settlement wake was lost")
                }
                try await runtime.commit({ _, _ in try completed(1) }, context: context)
            }
        }
        try setup.registry.install(Extension(name: "racing-notification", tasks: [AnyTaskDefinition(child)]))
        let chat = try await openChat(storage: storage, setup: setup)
        let waiter = try await chat.root.commit({ tx in
            try await tx.createTask(child, input: 0, options: .init(ownership: .conversation()))
        }, context: .background)
        try chat.harness.resume()
        await started.wait()
        let queued = try await chat.root.commit({ tx in
            try await tx.createSubmission(.write(conversationId: chat.root.id,
                notify: .init(taskId: waiter, key: "settled"))).id
        }, context: .background)
        let settle = Task {
            try await chat.root.commit({ tx in
                let entry = try await tx.appendEntry(chat.root.id, value: EntryDraft(kind: "note"))
                try tx.placeSubmission(queued, entry: entry.id)
            }, context: .background)
        }
        release.signal()
        try await settle.value
        #expect(try await chat.harness.waitForTask(id: waiter, context: .background).outcome.status == "completed")
        try await chat.harness.close(context: .background)
    }
}
