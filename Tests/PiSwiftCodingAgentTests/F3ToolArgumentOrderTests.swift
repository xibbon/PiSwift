import Foundation
import Testing
import PiSwiftAI
import PiSwiftAgent
@testable import PiSwiftCodingAgent

private func f3CodingCall() -> ToolCall {
    var call = ToolCall(id: "call", name: "test", arguments: [:])
    call.setArguments(from: #"{"z":{"last":1,"first":2},"a":3}"#)
    return call
}

private func f3CodingMessage(_ call: ToolCall) -> AssistantMessage {
    AssistantMessage(content: [.toolCall(call)], api: .openAIResponses, provider: "test", model: "test",
        usage: Usage(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0), stopReason: .toolUse)
}

@Test func f3SessionSaveLoadAndOldSessionOrder() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("f3-session-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let manager = SessionManager.create(directory.path, directory.path)
    let file = try #require(manager.newSession(NewSessionOptions(id: "f3")))
    let call = f3CodingCall()
    _ = manager.appendMessage(.user(UserMessage(content: .text("run"))))
    _ = manager.appendMessage(.assistant(f3CodingMessage(call)))
    var recorder = NestedCallRecorder()
    let index = recorder.start(call); recorder.finish(index, isError: false, errorText: "")
    _ = manager.appendMessage(.toolResult(ToolResultMessage(toolCallId: "parent", toolName: "parent", content: [],
        nestedCalls: recorder.snapshot(), isError: false)))
    let text = try String(contentsOfFile: file, encoding: .utf8)
    #expect(!text.contains("argumentsJSON"))
    #expect(text.contains(#""arguments":{"z":{"last":1,"first":2},"a":3}"#))
    let reopened = SessionManager.open(file)
    let messages = reopened.buildSessionProjection().messages
    let assistant = try #require(messages.compactMap { message -> AssistantMessage? in
        if case .assistant(let value) = message { return value }; return nil
    }.first)
    guard case .toolCall(let stored) = assistant.content.first else { Issue.record("Missing call"); return }
    #expect(orderedToolArguments(stored).map(\.key) == ["z", "a"])
    let nestedRecords = messages.compactMap { message -> NestedToolCallRecord? in
        if case .toolResult(let result) = message { return result.nestedCalls?.calls.first }; return nil
    }
    let nested = try #require(nestedRecords.first)
    #expect(nested.argumentsJSON?.objectEntries?.map(\.0) == ["z", "a"])
    let codedNested = try JSONDecoder().decode(NestedToolCallRecord.self, from: JSONEncoder().encode(nested))
    #expect(codedNested.argumentsJSON == nil)
    #expect(!String(decoding: try JSONEncoder().encode(nested), as: UTF8.self).contains("argumentsJSON"))

    // Old upstream-shaped lines carry their order in the argument object itself.
    let oldFile = directory.appendingPathComponent("old.jsonl")
    try text.write(to: oldFile, atomically: true, encoding: .utf8)
    let oldMessages = SessionManager.open(oldFile.path).buildSessionProjection().messages
    for message in oldMessages {
        if case .assistant(let assistant) = message, case .toolCall(let old) = assistant.content.first {
            #expect(orderedToolArguments(old).map(\.key) == ["z", "a"])
        }
        if case .toolResult(let result) = message {
            #expect(result.nestedCalls?.calls.first?.argumentsJSON?.objectEntries?.map(\.0) == ["z", "a"])
        }
    }
}

@Test func f3EventEncodingRetainsToolArgumentsAtEveryMessagePath() throws {
    let call = f3CodingCall()
    let assistant = f3CodingMessage(call)
    let args = toolArgumentsWithOrder(call.arguments, argumentsJSON: call.argumentsJSON)
    let partial = AgentToolResult(content: [])
    let events: [AgentSessionEvent] = [
        .agent(.toolExecutionStart(toolCallId: call.id, toolName: call.name, args: args)),
        .agent(.toolExecutionUpdate(toolCallId: call.id, toolName: call.name, args: args, partialResult: partial)),
        .nestedToolExecution(.start(toolCallId: "child", toolName: call.name, args: args, parentToolCallId: "parent")),
        .nestedToolExecution(.update(toolCallId: "child", toolName: call.name, args: args, partialResult: partial, parentToolCallId: "parent")),
        .agent(.messageEnd(message: .assistant(assistant))),
        .agent(.agentEnd(messages: [.assistant(assistant)])),
        .agent(.messageUpdate(message: .assistant(assistant), assistantMessageEvent: .toolCallEnd(contentIndex: 0, toolCall: call, partial: assistant)))
    ]
    for event in events {
        let json = encodeSessionEventJSON(event)
        #expect(!json.contains("argumentsJSON"))
        let ordered = try OrderedJSON.parse(json)
        let arguments = ordered["args"] ?? ordered["message"]?["content"]?[0]?["arguments"]
            ?? ordered["messages"]?[0]?["content"]?[0]?["arguments"]
            ?? ordered["assistantMessageEvent"]?["toolCall"]?["arguments"]
        #expect(arguments?.serialized() == #"{"z":{"last":1,"first":2},"a":3}"#)
    }
    let manager = SessionManager.inMemory()
    _ = manager.appendMessage(.assistant(assistant))
    let entry = try #require(manager.getEntries().first)
    let encoded = try OrderedJSON.parse(encodeSessionEventJSON(.entryAppended(entry)))
    #expect(encoded["entry"]?["message"]?["content"]?[0]?["arguments"]?.objectEntries?.map(\.0) == ["z", "a"])
}

@Test(.timeLimit(.minutes(1))) func f3NestedRunnerKeepsCallAndEventOrder() async throws {
    let call = f3CodingCall()
    let events = LockedState<[NestedToolExecutionEvent]>([])
    let tool = AgentTool(label: "Test", name: "test", description: "Test", parameters: [:], execute: { _, _, _, _ in AgentToolResult(content: []) })
    let runner = NestedToolCallRunner(host: NestedToolCallHost(getTools: { [tool] }, isSequential: { false },
        runToolCall: { child, _, _, onUpdate in
            #expect(orderedToolArguments(child).map(\.key) == ["z", "a"])
            let result = AgentToolResult(content: [])
            await onUpdate(result)
            return AgentToolCallOutcome(toolCall: child, result: result, isError: false)
        }, emit: { event in events.withLock { $0.append(event) } }))
    let result = await runner.execute(callerId: "parent", name: "test", args: call.arguments,
        options: ExecuteToolOptions(argumentsJSON: call.argumentsJSON))
    #expect(orderedToolArguments(result.toolCall).map(\.key) == ["z", "a"])
    let record = try #require(await runner.takeRecord(toolCallId: "parent")?.calls?.calls.first)
    #expect(record.argumentsJSON?.objectEntries?.map(\.0) == ["z", "a"])
    for event in events.withLock({ $0 }) {
        switch event {
        case .start(_, _, let args, _), .update(_, _, let args, _, _):
            #expect(orderedToolArguments(args).map(\.key) == ["z", "a"])
        default: break
        }
    }
}

@Test func f3LargeSessionArgumentIsWrittenOnceAndParsingIsSelective() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("f3-large-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let manager = SessionManager.create(directory.path, directory.path)
    let file = try #require(manager.newSession(NewSessionOptions(id: "f3-large")))
    let large = "F3-large-file-" + String(repeating: "file content ", count: 10_000)
    let source = OrderedJSON.object([("content", .string(large)), ("path", .string("file.swift"))])
    let call = ToolCall(id: "large", name: "write", arguments: ["path": AnyCodable("file.swift"), "content": AnyCodable(large)], argumentsJSON: source)
    _ = manager.appendMessage(.user(UserMessage(content: .text("write a file"))))
    _ = manager.appendMessage(.assistant(AssistantMessage(content: [.text(TextContent(text: "Ready"))],
        api: .openAIResponses, provider: "test", model: "test",
        usage: Usage(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0), stopReason: .stop)))
    _ = manager.appendMessage(.assistant(f3CodingMessage(call)))
    let text = try String(contentsOfFile: file, encoding: .utf8)
    let exported = try serializeSessionBranch(manager)
    #expect(exported.components(separatedBy: large).count == 2)
    #expect(!exported.contains("argumentsJSON"))
    let leaf = try #require(manager.getLeafId())
    let branchedFile = try #require(manager.createBranchedSession(leaf))
    let branched = try String(contentsOfFile: branchedFile, encoding: .utf8)
    #expect(branched.contains(#""arguments":{"content":"#))
    #expect(branched.components(separatedBy: large).count == 2)
    #expect(!branched.contains("argumentsJSON"))
    #expect(!text.contains("argumentsJSON"))
    #expect(text.components(separatedBy: large).count == 2)
    #expect(text.contains(#""arguments":{"content":"#))
    var count = 0
    let entries = parseSessionEntries(text, orderedParser: { text in
        count += 1
        return try OrderedJSON.parse(text)
    })
    #expect(count == 1) // Header, plain user and plain assistant lines use only Foundation parsing.
    let saved = try #require(entries.compactMap { entry -> ToolCall? in
        if case .entry(.message(let message)) = entry, case .assistant(let assistant) = message.message,
           case .toolCall(let tool) = assistant.content.first { return tool }
        return nil
    }.first)
    #expect(orderedToolArguments(saved).map(\.key) == ["content", "path"])
    let event = encodeSessionEventJSON(.agent(.toolExecutionStart(toolCallId: call.id, toolName: call.name, args: call.arguments)))
    #expect(event.components(separatedBy: large).count == 2)
    #expect(!event.contains("argumentsJSON"))
}

@Test func f3NestedResultAndCustomRecordTextOrder() throws {
    let call = f3CodingCall()
    let nested = NestedToolCalls(calls: [NestedToolCallRecord(id: "child", name: "test", arguments: call.arguments,
        status: .ok, argumentsJSON: call.argumentsJSON)], complete: true)
    let result = ToolResultMessage(toolCallId: "parent", toolName: "test", content: [.toolCall(call)], nestedCalls: nested, isError: false)
    let event = encodeSessionEventJSON(.agent(.turnEnd(message: .assistant(f3CodingMessage(call)), toolResults: [result])))
    let tree = try OrderedJSON.parse(event)
    let subtree = try #require(tree["toolResults"]?[0]?["nestedCalls"])
    #expect(subtree["calls"]?[0]?["arguments"]?.objectEntries?.map(\.0) == ["z", "a"])
    #expect(tree["toolResults"]?[0]?["content"]?[0]?["arguments"]?.objectEntries?.map(\.0) == ["z", "a"])
    #expect(!event.contains("argumentsJSON"))
    let object = try #require(JSONSerialization.jsonObject(with: Data(subtree.serialized().utf8)) as? [String: Any])
    let decoded = try #require(nestedToolCallsFromJSONObject(object, ordered: subtree))
    #expect(decoded.calls.first?.argumentsJSON?.objectEntries?.map(\.0) == ["z", "a"])
    let manager = SessionManager.inMemory()
    let user = manager.appendMessage(.user(UserMessage(content: .text("run"))))
    _ = manager.appendCustomMessage("test", .blocks([.toolCall(call)]), true)
    _ = try manager.appendContextEdit(user, .blocks([.toolCall(call)]))
    let text = try serializeSessionBranch(manager)
    #expect(!text.contains("argumentsJSON"))
    var count = 0
    let entries = parseSessionEntries(text, orderedParser: { count += 1; return try OrderedJSON.parse($0) })
    #expect(count == 2)
    for entry in entries {
        let blocks: [ContentBlock]
        switch entry {
        case .entry(.customMessage(let message)):
            guard case .blocks(let values) = message.content else { continue }; blocks = values
        case .entry(.contextEdit(let edit)):
            guard case .blocks(let values) = edit.replacement else { continue }; blocks = values
        default: continue
        }
        guard case .toolCall(let saved) = blocks.first else { Issue.record("Missing tool"); continue }
        #expect(orderedToolArguments(saved).map(\.key) == ["z", "a"])
    }
}
