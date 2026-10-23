import Foundation
import PiSwiftAI
import PiSwiftChord
import PiSwiftDurable
import PiSwiftDurableTesting
import Synchronization
import Testing

private let nestedCountSchema: JSONObject = ["type": "object", "properties": ["count": ["type": "number"]], "required": ["count"]]

private func nestedReturning(_ name: String, _ result: ToolExecutionResult,
                             schema: JSONObject? = nil, limits: OutputLimitOverrides? = nil) throws -> ToolRegistration {
    try ToolRegistration(name: name, description: name, parameters: ["type": "object"],
        outputLimits: limits, structuredOutputSchema: schema) { _, _, _ in result }
}

private func nestedReturning(_ result: ToolExecutionResult, schema: JSONObject? = nil,
                             limits: OutputLimitOverrides? = nil) throws -> ToolRegistration {
    try nestedReturning("value", result, schema: schema, limits: limits)
}

private func nestedValueCall(_ name: String) -> AssistantMessage {
    var message = chatAssistant("")
    message.content = [.toolCall(ToolCall(id: "program", name: name, arguments: [:]))]
    message.stopReason = .toolUse
    return message
}

private struct NestedValues {
    var received: [NestedToolExecutionResult]
    var stored: [NestedToolExecutionResult]
    var ends: [NestedToolExecutionResult]
    var entries: [EntryRecord]
}

private func nestedValues(_ tools: [ToolRegistration], names: [String] = ["value"], hooks: ToolHooks? = nil) async throws -> NestedValues {
    let setup = HarnessChatSetup()
    let received = Mutex<[NestedToolExecutionResult]>([]), stored = Mutex<[NestedToolExecutionResult]>([])
    let ends = Mutex<[NestedToolExecutionResult]>([])
    let probe = try ToolRegistration(name: "probe", description: "probe", parameters: ["type": "object"]) { _, api, context in
        for name in names {
            let result = try await api.executeTool(name, arguments: [:], context: context)
            received.withLock { $0.append(result) }
        }
        return .init(output: [])
    }
    try setup.registry.install(Extension(name: "values", tools: tools + [probe]))
    if let hooks { try setup.registry.install(Extension(name: "hooks", hooks: [hook(hooks)])) }
    setup.models.setResponses([.message(nestedValueCall("probe")), .message(chatAssistant("done"))])
    let opened = try await openChat(setup: setup)
    let subscription = try opened.harness.subscribeCommits { publication, _ in
        for change in publication.changes {
            guard case .document(let document) = change, document.record.kind == NestedCallDoc.definition.kind,
                  !document.ops.isEmpty, let value = document.value else { continue }
            do {
                if let result = try JSONValue.object(value).decode(NestedCallState.self).result {
                    stored.withLock { $0.append(result) }
                }
            } catch { Issue.record(error) }
        }
    }
    let stream = try await watchEvents(opened.harness, conversationId: opened.root.id, context: .background)
    try stream.start { events, _ in
        for event in events {
            if case .toolExecutionEnd(_, _, _, _, let parent, _, let result) = event, parent != nil, let result {
                ends.withLock { $0.append(result) }
            }
        }
    }
    let input = try await opened.root.submit(.input(content: .text("go")), context: .background)
    #expect(try await input.wait(context: .background).status == "done")
    try await opened.harness.waitForIdle(context: .background)
    await stream.waitUntilIdle()
    _ = await stream.stop()
    subscription.cancel()
    let entries = try await allEntries(opened.root)
    try await opened.harness.close(context: .background)
    return .init(received: received.withLock { $0 }, stored: stored.withLock { $0 }, ends: ends.withLock { $0 }, entries: entries)
}

@Suite(.timeLimit(.minutes(1))) struct HarnessNestedStructuredOutputTests {
    // harness-structured-output.test.ts:88.
    @Test(arguments: [0, 1, 2, 3, 4]) func schemaFreeOutputFallback(mode: Int) async throws {
        let text = ContentBlock.text(TextContent(text: "one"))
        let image = ContentBlock.image(ImageContent(data: "AAAA", mimeType: "image/png"))
        let imageValue: JSONValue = ["type": "image", "data": "AAAA", "mimeType": "image/png"]
        let textValue: JSONValue = ["type": "text", "text": "one"]
        let outputs: [[ContentBlock]] = [[text], [image], [], [text, image], [text, text]]
        let values: [JSONValue] = ["one", imageValue, "", [textValue, imageValue], [textValue, textValue]]
        let run = try await nestedValues([nestedReturning(.init(output: outputs[mode]))])
        let result = try #require(run.received.first)
        #expect(result == .init(taskId: result.taskId, structuredOutput: values[mode], isError: false,
                                diagnostics: [], durationMs: result.durationMs))
    }

    // :118. The program value excludes rendered harness diagnostics.
    @Test func boundedProgramOutputExcludesRenderedDiagnostics() async throws {
        let run = try await nestedValues([nestedReturning(.init(output: [.text(.init(text: "a\nb\nc"))],
            diagnostics: [.init(severity: .info, message: "note")]), limits: .init(maxLines: 1))])
        let result = try #require(run.received.first)
        #expect(result.structuredOutput == "a\n")
        #expect(result.diagnostics.map(\.code) == [nil, "truncated"])
    }

    // :133. The exact stored value also reaches the caller and the event stream.
    @Test func storedCallerAndEventResultsMatchAndKeepNull() async throws {
        let run = try await nestedValues([
            nestedReturning("plain", .init(output: [.text(.init(text: "a"))])),
            nestedReturning("nothing", .init(structuredOutput: .null), schema: ["type": "null"])
        ], names: ["plain", "nothing"])
        try #require(run.received.count == 2)
        #expect(run.received[0].structuredOutput == "a")
        #expect(run.received[1].structuredOutput == .null)
        #expect(run.stored == run.received)
        #expect(run.ends == run.received)
        for result in run.received {
            let value = try JSONValue(encoding: result)
            #expect(value["output"] == nil)
            #expect(value["control"] == nil)
        }
        #expect(run.entries.filter { $0.kind == "pi.tool-result" }.count == 1)
    }

    // :187. D4a checks the model transcript half.
    @Test func schemaValueReachesProgramWithoutNestedTranscriptEntry() async throws {
        let run = try await nestedValues([nestedReturning(.init(output: [.text(.init(text: "3 things"))],
            structuredOutput: ["count": 3]), schema: nestedCountSchema)])
        #expect(run.received.first?.structuredOutput == ["count": 3])
        #expect(run.received.first?.isError == false)
        #expect(run.entries.filter { $0.kind == "pi.tool-result" }.count == 1)
        #expect(run.entries.allSatisfy { $0.model?.allSatisfy { $0["structuredOutput"] == nil } ?? true })
    }

    // :200. Invalid nested values become errors; schema-free output fallback still applies.
    @Test(arguments: ["wrong", "missing", "undeclared"])
    func invalidProgramValuesBecomeDiagnosticErrors(mode: String) async throws {
        let schema = mode == "undeclared" ? nil : nestedCountSchema
        let value: JSONValue? = mode == "wrong" ? ["count": "three"] : mode == "undeclared" ? ["count": 3] : nil
        let run = try await nestedValues([nestedReturning(.init(output: [], structuredOutput: value), schema: schema)])
        let result = try #require(run.received.first)
        #expect(result.isError)
        #expect(result.structuredOutput == (mode == "undeclared" ? .string("") : nil))
        #expect(result.diagnostics.map(\.code) == ["invalid_structured_output"])
        let message = mode == "wrong" ? "does not match its schema: count:" :
            mode == "missing" ? "returned no structuredOutput" : "declares no structuredOutputSchema"
        #expect(result.diagnostics.first?.message.contains(message) == true)
    }

    // :227 and :233.
    @Test func toolErrorsKeepOutputAndHarnessErrorsHaveOnlyDiagnostics() async throws {
        let run = try await nestedValues([nestedReturning(.init(output: [.text(.init(text: "bad"))], isError: true))],
                                         names: ["value", "missing"])
        try #require(run.received.count == 2)
        #expect(run.received[0].isError)
        #expect(run.received[0].structuredOutput == "bad")
        #expect(run.received[1].isError)
        #expect(run.received[1].structuredOutput == nil)
        #expect(run.received[1].diagnostics.map(\.code) == ["tool_unavailable"])
    }

    // :240, including thrown errors, an existing error diagnostic, and a supplied error value.
    @Test func schemaErrorsUseTextOnceAndKeepSuppliedProgramValues() async throws {
        let thrown = try ToolRegistration(name: "throws", description: "throws", parameters: ["type": "object"],
            structuredOutputSchema: nestedCountSchema) { _, _, _ in throw TaskDefinitionError("permission denied") }
        let run = try await nestedValues([
            nestedReturning("fails", .init(output: [.text(.init(text: "nope"))], isError: true), schema: nestedCountSchema),
            thrown,
            nestedReturning("explained", .init(output: [.text(.init(text: "partial log"))], isError: true,
                diagnostics: [.init(severity: .error, message: "quota exceeded", code: "quota")]), schema: nestedCountSchema),
            nestedReturning("kept", .init(output: [.text(.init(text: "nope"))], structuredOutput: ["count": 0], isError: true), schema: nestedCountSchema)
        ], names: ["fails", "throws", "explained", "kept"])
        try #require(run.received.count == 4)
        #expect(run.received[0].diagnostics == [.init(severity: .error, message: "nope", code: "tool_error")])
        #expect(run.received[1].diagnostics == [.init(severity: .error, message: "permission denied", code: "tool_error")])
        #expect(run.received[2].diagnostics == [.init(severity: .error, message: "quota exceeded", code: "quota")])
        #expect(run.received.prefix(3).allSatisfy { $0.isError && $0.structuredOutput == nil })
        #expect(run.received[3].isError)
        #expect(run.received[3].structuredOutput == ["count": 0])
    }

    // :323. A replacement of the output changes schema-free program values only.
    @Test func replacementHooksControlFallbackAndValidateSchemaValues() async throws {
        let hooks = ToolHooks(afterTool: { call, result, _, _ in
            var replacement = result
            if call.name == "other" { replacement.structuredOutput = ["count": "broken"] }
            else if call.name != "probe" { replacement.output = [.text(.init(text: "rewritten"))] }
            return replacement
        })
        let run = try await nestedValues([
            nestedReturning("plain", .init(output: [.text(.init(text: "secret"))])),
            nestedReturning("counter", .init(structuredOutput: ["count": 1]), schema: nestedCountSchema),
            nestedReturning("other", .init(structuredOutput: ["count": 1]), schema: nestedCountSchema)
        ], names: ["plain", "counter", "other"], hooks: hooks)
        try #require(run.received.count == 3)
        #expect(run.received[0].structuredOutput == "rewritten")
        #expect(run.received[1].structuredOutput == ["count": 1])
        #expect(run.received[2].isError)
        #expect(run.received[2].diagnostics.map(\.code) == ["invalid_structured_output"])
    }
    // :370. Nonzero exit returns its program value and one exit diagnostic.
    @Test func nestedBashReturnsRetainedOutputAndExitCode() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { do { try FileManager.default.removeItem(at: directory) } catch { Issue.record(error) } }
        let setup = HarnessChatSetup()
        let received = Mutex<[NestedToolExecutionResult]>([])
        let probe = try ToolRegistration(name: "probe", description: "probe", parameters: ["type": "object"]) { _, api, context in
            for command in ["printf ok", "printf bad; exit 4"] {
                let result = try await api.executeTool("bash", arguments: ["command": .string(command)], context: context)
                received.withLock { $0.append(result) }
            }
            return .init(output: [])
        }
        try setup.registry.install(Extension(name: "tools", tools: [try createBashTool(), probe]))
        setup.models.setResponses([.message(nestedValueCall("probe")), .message(chatAssistant("done"))])
        let env = LocalExecutionEnv(cwd: directory.path)
        let harness = try await Harness.open(storage: MemoryStorage(), options: .init(models: setup.models,
            registry: setup.registry, env: { _, _ in env }), context: .background)
        let root = try await harness.root(options: .init(agent: .init(model: .set(.init(provider: "faux", modelId: "faux-1")))) , context: .background)
        let input = try await root.submit(.input(content: .text("go")), context: .background)
        #expect(try await input.wait(context: .background).status == "done")
        let results = received.withLock { $0 }
        try #require(results.count == 2)
        #expect(results[0].isError == false)
        #expect(results[0].structuredOutput == ["output": "ok", "truncated": false, "exitCode": 0])
        #expect(results[1].isError)
        #expect(results[1].structuredOutput == ["output": "bad", "truncated": false, "exitCode": 4])
        #expect(results[1].diagnostics.map(\.code) == ["exit_code"])
        try await harness.close(context: .background)
    }

}
