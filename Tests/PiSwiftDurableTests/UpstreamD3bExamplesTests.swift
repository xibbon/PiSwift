import Foundation
import PiSwiftAI
import PiSwiftChord
import PiSwiftDurableTesting
import Synchronization
import Testing
@testable import PiSwiftDurable

@Suite(.timeLimit(.minutes(1)))
struct UpstreamD3bExamplesTests {
    // Upstream example 42 uses the same two handles and policy-any flow as the direct case.
    @Test func example42ParallelChildren() async throws {
        try await HarnessParkChildrenD3bTests().parkOnHandlesWithPolicyAnyAndCollectResultsByKeyAcrossWakes()
    }

    @Test func example43SubagentWaits() async throws {
        let setup = HarnessChatSetup()
        let answer: SignalToken<JSONValue> = try defineSignal(name: "example.answer", version: 1,
            schema: ["type": "object", "properties": ["text": ["type": "string"]], "required": ["text"]])
        let asked = Mutex<TaskID?>(nil)
        let askPerson = try ToolRegistration(name: "ask_person", description: "Ask a person", parameters: ["type": "object"],
            replay: .safe, execute: { _, api, context in
                if case .value(let value) = try await api.readSignal(answer, key: "answer", context: context) {
                    return .result(.init(output: [.text(.init(text: value["text"]?.stringValue ?? ""))]))
                }
                asked.withLock { $0 = api.taskId }
                return .park(.sleep(signals: [try answer.key("answer")]))
            })
        try setup.registry.install(Extension(name: "people", tools: [askPerson]))
        let subagent = try ToolRegistration(name: "subagent", description: "Delegate a task", parameters: ["type": "object"],
            replay: .safe, execute: { args, api, context in
                if case .value(let settled) = try await api.readSignal(SubmissionSettled, key: "answered", context: context) {
                    guard settled.status == "done", settled.record.type != "write", let answerID = settled.answer else {
                        return .result(.init(output: [.text(.init(text: "Subagent ended: \(settled.status)"))], isError: true))
                    }
                    let entry = try await api.commit({ tx in try await tx.entry(assistantEntry, id: answerID) }, context: context)
                    let text = try entry?.record.messages()?.compactMap { message -> String? in
                        if case .assistant(let assistant) = message {
                            return assistant.content.compactMap { block in
                                if case .text(let item) = block { return item.text }
                                return nil
                            }.joined()
                        }
                        return nil
                    }.joined() ?? ""
                    return .result(.init(output: [.text(.init(text: text))]))
                }
                let child = try await api.commit({ tx in
                    if let existing = try await tx.scanConversations(.init(ownerTaskId: api.taskId), limit: 1).items.first {
                        return existing.id
                    }
                    let created = try await tx.createConversation(ownership: .task(taskId: api.taskId))
                    try await configure(tx: tx, conversationId: created.id,
                        change: AgentChange(extensions: .set(.edit(remove: [Extension(name: "subagent")]))))
                    return created.id
                }, context: context)
                guard let handle = try await api.conversation(id: child, context: context) else {
                    throw TaskDefinitionError("No child conversation")
                }
                _ = try await handle.submit(.input(content: .text(args["task"]?.stringValue ?? ""),
                    requestId: "subagent:\(api.taskId.rawValue)", notify: .init(taskId: api.taskId, key: "answered")),
                    context: context)
                return .park(.sleep(signals: [try SubmissionSettled.key("answered")]))
            })
        try setup.registry.install(Extension(name: "subagent", tools: [subagent]))
        setup.models.setResponses([
            .message(try toolCalls([("subagent", ["task": "May we deploy?"], "c1")])),
            .message(try toolCalls([("ask_person", ["question": "May we deploy?"], "c2")])),
            .message(chatAssistant("The person says yes, after 5 pm.")),
            .message(chatAssistant("We may deploy after 5 pm."))
        ])
        let chat = try await openChat(setup: setup)
        try chat.harness.resume()
        let submission = try await chat.root.submit(.input(content: .text("Can we deploy?")), context: .background)
        try await harnessEventually { asked.withLock { $0 } != nil && !chat.harness.wake().active }
        let question = try #require(asked.withLock { $0 })
        #expect(try await chat.harness.signal(taskId: question, token: answer, key: "answer",
            value: ["text": "Yes, after 5 pm"], context: .background) == .delivered)
        #expect(try await submission.wait(context: .background).status == "done")
        let toolResult = try #require(harnessToolResults(await allEntries(chat.root)).first)
        #expect(harnessToolText(toolResult) == "The person says yes, after 5 pm.")
        try await chat.harness.close(context: .background)
    }
}
