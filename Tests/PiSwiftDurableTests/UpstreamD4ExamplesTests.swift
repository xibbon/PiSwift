import Foundation
import Synchronization
import Testing
import PiSwiftAI
import PiSwiftChord
import PiSwiftDurableTesting
@testable import PiSwiftDurable

// Ports durable/test/examples/44-approval-gate.ts.
@Suite("PiSwiftDurableTests.UpstreamD4Examples", .timeLimit(.minutes(1)))
struct UpstreamD4ExamplesTests {
    private struct Approval: Codable, Sendable { let allow: Bool }
    private let day: Int64 = 86_400_000

    @Test func example44ApprovalGate() async throws {
        let clock = TestClock(now: 9 * 3_600_000)
        let setup = HarnessChatSetup(clock: clock)
        let token: SignalToken<Approval> = try defineSignal(name: "approvals.decision", version: 1,
            schema: ["type": "object", "properties": ["allow": ["type": "boolean"]], "required": ["allow"]])
        let commands = ["rm -rf build", "rm -rf dist", "rm -rf cache"]
        let questions = Dictionary(uniqueKeysWithValues: commands.map { ($0, HarnessChatSignal()) })
        let checks = Mutex(0), runs = Mutex<[String]>([])
        let bash = try ToolRegistration(name: "bash", description: "Run a shell command",
            parameters: ["type": "object", "properties": ["command": ["type": "string"]], "required": ["command"]],
            execute: { args, _, _ in
                let command = args["command"]?.stringValue ?? ""
                runs.withLock { $0.append(command) }
                return .result(.init(output: [.text(.init(text: "ran: \(command)"))]))
            })
        try setup.registry.install(Extension(name: "tools", tools: [bash]))
        try setup.registry.install(Extension(name: "quiet-hours", hooks: [hook(ToolHooks(beforeTool: { _, api, _ in
            checks.withLock { $0 += 1 }
            let hour = (try api.now() / 3_600_000) % 24
            return hour >= 22 || hour < 6 ? .init(block: "Quiet hours: no commands at night") : nil
        }))]))
        try setup.registry.install(Extension(name: "approvals", hooks: [hook(ToolHooks(beforeTool: { call, api, context in
            guard let command = call.arguments["command"]?.value as? String,
                  command.hasPrefix("rm ") else { return nil }
            let key = Data("{\"command\":\"\(command)\"}".utf8).base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
            let state = try await api.readSignal(token, key: key, context: context)
            let until = try await api.memo("approvals.until.\(key)", .number(Double(try api.now() + day)), context)
            switch state {
            case nil:
                questions[command]?.signal()
                return .init(sleep: .init(until: until?.numberValue, signals: [try token.key(key)]))
            case .expired: return .init(block: "No approval within a day")
            case .value(let value): return value.allow ? nil : .init(block: "Not approved")
            }
        }))]))
        var replies: [FakeDurableResponseStep] = []
        for (index, command) in commands.enumerated() {
            replies.append(.message(try toolCalls([("bash", ["command": .string(command)], "c\(index + 1)")])))
            replies.append(.message(chatAssistant("answered")))
        }
        setup.models.setResponses(replies)
        let opened = try await openChat(setup: setup)
        try opened.harness.resume()
        for (index, command) in commands.enumerated() {
            let submission = try await opened.root.submit(.input(content: .text("Clean \(index)")), context: .background)
            await questions[command]?.wait()
            try await eventually {
                try await opened.harness.snapshot(LiveDoc, conversationId: opened.root.id,
                    context: .background)?.tools?.first?.status == .sleeping
            }
            let slot = try #require(try await opened.harness.snapshot(LiveDoc,
                conversationId: opened.root.id, context: .background)?.tools?.first)
            let id = try #require(slot.taskId)
            #expect(slot.status == .sleeping)
            let key = Data("{\"command\":\"\(command)\"}".utf8).base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
            if index == 2 { clock.advance(by: day); try opened.harness.resume() }
            else {
                #expect(try await opened.harness.signal(taskId: id, token: token, key: key,
                    value: Approval(allow: index == 0), context: .background) == .delivered)
            }
            #expect(try await submission.wait(context: .background).status == "done")
            let results = try harnessToolResults(await allEntries(opened.root))
            let text = harnessToolText(try #require(results.last))
            switch index {
            case 0: #expect(text == "ran: rm -rf build")
            case 1: #expect(text.contains("Not approved"))
            default: #expect(text.contains("No approval within a day"))
            }
        }
        #expect(runs.withLock { $0 } == ["rm -rf build"])
        #expect(checks.withLock { $0 } == 6)
        try await opened.harness.close(context: .background)
    }
}
