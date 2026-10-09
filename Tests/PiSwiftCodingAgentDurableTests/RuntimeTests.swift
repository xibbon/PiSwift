import Darwin
import Foundation
import PiSwiftAI
import PiSwiftChord
import PiSwiftCodingAgent
@testable import PiSwiftCodingAgentDurable
import PiSwiftDurable
import PiSwiftDurableTesting
import Synchronization
import Testing

private let runtimeModel = ModelRef(provider: "faux", modelId: "faux-1")

private struct RuntimePaths: Sendable {
    let base: URL
    let cwd: URL
    let agent: URL
    let realCwd: String

    init() throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("runtime-" + UUID().uuidString)
        cwd = base.appendingPathComponent("project")
        agent = base.appendingPathComponent("agent")
        try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: agent, withIntermediateDirectories: true)
        guard let pointer = realpath(cwd.path, nil) else { throw POSIXError(.ENOENT) }
        realCwd = String(cString: pointer)
        free(pointer)
        try writeSettings()
    }

    func writeSettings() throws {
        let settings = """
        {
          "defaultProvider": "faux", "defaultModel": "faux-1", "defaultThinkingLevel": "high",
          "theme": "light", "retry": { "enabled": false },
          "compaction": { "enabled": false, "reserveTokens": 1000, "keepRecentTokens": 150 }
        }
        """
        try Data(settings.utf8).write(to: agent.appendingPathComponent("settings.json"))
    }

    func remove() { try? FileManager.default.removeItem(at: base) }

    func open(_ models: FakeDurableModels, continueSession: Bool = false,
              initial: (@Sendable (SettingsManager) async -> InitialAgentModel)? = nil) async throws -> OpenDurableResult {
        try await openDurable(.init(cwd: cwd.path, continueSession: continueSession), dependencies: .init(
            agentDirectory: agent.path,
            makeModels: { _ in
                DurableRuntimeModels(models: models, available: models.models, initial: initial ?? { settings in
                    InitialAgentModel(
                        model: ModelRef(provider: settings.getDefaultProvider() ?? "faux", modelId: settings.getDefaultModel() ?? "faux-1"),
                        thinkingLevel: settings.getDefaultThinkingLevel().flatMap(ModelThinkingLevel.init(rawValue:))
                    )
                })
            }
        ))
    }
}

private func runtimeModels(responses: [FakeDurableResponseStep] = []) -> FakeDurableModels {
    FakeDurableModels(options: .init(models: [
        .init(id: "faux-1", name: "Reasoning model", reasoning: true),
        .init(id: "plain", name: "Plain model", reasoning: false)
    ]), responses: responses)
}

private func withRuntime(_ paths: RuntimePaths, models: FakeDurableModels,
                         _ body: (OpenDurableResult) async throws -> Void) async throws {
    let result = try await paths.open(models)
    do {
        try await body(result)
        await result.close()
    } catch {
        await result.close()
        throw error
    }
}

private func runtimeTexts(_ view: DurableView, kind: String? = nil) throws -> [String] {
    try view.conversation.entries.filter { kind == nil || $0.kind == kind }.flatMap {
        try $0.messages()?.compactMap { textOf($0) } ?? []
    }
}

private func runtimeLive(_ view: DurableView) throws -> LiveState {
    try JSONValue.object(view.conversation.docs["pi.live"] ?? [:]).decode(LiveState.self)
}

private func runtimeInbox(_ view: DurableView) throws -> InboxState {
    try JSONValue.object(view.conversation.docs["pi.inbox"] ?? ["items": []]).decode(InboxState.self)
}

private func runtimeWaitForAnswer(_ result: OpenDurableResult, _ answer: String) async throws {
    try await eventually {
        try runtimeTexts(result.view.current(), kind: "pi.assistant").contains(answer)
            && runtimeLive(result.view.current()).run == nil
    }
}

private func runtimeHistory(_ result: OpenDurableResult, models: FakeDurableModels) async throws {
    for index in 1...3 {
        let text = "a\(index) " + String(repeating: "x", count: 396)
        models.setResponses([.message(chatAssistant(text))])
        await result.controller.submit("u\(index) " + String(repeating: "x", count: 396), whenBusy: .followUp)
        try await runtimeWaitForAnswer(result, text)
    }
}

private func runtimeToolCall(_ name: String, arguments: [String: AnyCodable]) -> AssistantMessage {
    var message = chatAssistant("", reason: .toolUse)
    message.content = [.toolCall(.init(id: name + "-call", name: name, arguments: arguments))]
    return message
}

@Suite(.timeLimit(.minutes(1))) struct RuntimeTests {
    @Test func newSessionHasRootSettingsModelsAndTasks() async throws {
        let paths = try RuntimePaths()
        defer { paths.remove() }
        let models = runtimeModels()
        try await withRuntime(paths, models: models) { result in
            let view = result.view.current()
            #expect(view.session.cwd == paths.realCwd)
            #expect(URL(fileURLWithPath: view.session.directory).resolvingSymlinksInPath().path
                .hasPrefix(paths.agent.resolvingSymlinksInPath().path + "/experimental/durable-sessions-swift/"))
            #expect(view.session.id == URL(fileURLWithPath: view.session.directory).lastPathComponent)
            #expect(FileManager.default.fileExists(atPath: view.session.directory + "/session.sqlite"))
            #expect(view.conversation.conversation.id == rootConversationID)
            #expect(view.conversations == [.init(id: rootConversationID, label: "main")])
            #expect(agentOf(view.conversation).cwd == paths.realCwd)
            #expect(agentOf(view.conversation).model == runtimeModel)
            #expect(agentOf(view.conversation).thinkingLevel == .high)
            #expect(result.settings.getTheme() == "light")
            #expect(result.settings.getRetrySettings().enabled == false)
            #expect(view.models == models.models.map {
                ModelSummary(provider: $0.provider, modelId: $0.id, name: $0.name, contextWindow: $0.contextWindow)
            })
            #expect(view.tasks != nil)
            #expect(view.notices.isEmpty)
        }
    }

    @Test func idleInputAndContinueKeepTranscriptAndConfiguration() async throws {
        let paths = try RuntimePaths()
        defer { paths.remove() }
        let models = runtimeModels(responses: [.message(chatAssistant("first answer")), .message(chatAssistant("continued answer"))])
        let initialCalls = Mutex(0)
        let initial: @Sendable (SettingsManager) async -> InitialAgentModel = { _ in
            initialCalls.withLock { $0 += 1 }
            return .init(model: runtimeModel, thinkingLevel: .high)
        }
        let first = try await paths.open(models, initial: initial)
        let id = first.view.current().session.id
        await first.controller.submit("first input", whenBusy: .steer)
        do {
            try await runtimeWaitForAnswer(first, "first answer")
            await first.controller.setModel(.init(provider: "faux", modelId: "plain"))
            try await eventually { agentOf(first.view.current().conversation).thinkingLevel == .off }
            #expect(try runtimeTexts(first.view.current(), kind: "pi.user") == ["first input"])
            #expect(first.view.current().conversations.first?.title == "first input")
        } catch { await first.close(); throw error }
        await first.close()
        let second = try await paths.open(models, continueSession: true, initial: initial)
        do {
            #expect(second.view.current().session.id == id)
            #expect(try runtimeTexts(second.view.current()).contains("first answer"))
            #expect(second.view.current().conversations.first?.title == nil)
            #expect(agentOf(second.view.current().conversation).model == .init(provider: "faux", modelId: "plain"))
            #expect(agentOf(second.view.current().conversation).thinkingLevel == .off)
            #expect(initialCalls.withLock { $0 } == 1)
            await second.controller.submit("second input", whenBusy: .followUp)
            try await runtimeWaitForAnswer(second, "continued answer")
            #expect(try runtimeTexts(second.view.current(), kind: "pi.user") == ["first input", "second input"])
            #expect(second.view.current().notices.isEmpty)
        } catch { await second.close(); throw error }
        await second.close()
    }

    @Test(arguments: [SubmitWhenBusy.steer, .followUp])
    func busyInputUsesSelectedQueue(whenBusy: SubmitWhenBusy) async throws {
        let paths = try RuntimePaths()
        defer { paths.remove() }
        let first = HarnessGatedResponse(message: chatAssistant("first answer"))
        let second = HarnessGatedResponse(message: chatAssistant("second answer"))
        let requests = Mutex<[[String]]>([])
        let models = runtimeModels(responses: [first.step, .factory { transcript, options, state, model in
            requests.withLock { $0.append(transcript.messages.compactMap { textOf($0) }) }
            guard case .factory(let factory) = second.step else { throw TestDeadlineError() }
            return try await factory(transcript, options, state, model)
        }])
        try await withRuntime(paths, models: models) { result in
            await result.controller.submit("first input", whenBusy: .followUp)
            try await eventually { first.reached.isSignalled }
            await result.controller.submit("busy input", whenBusy: whenBusy)
            try await eventually { try runtimeInbox(result.view.current()).items.count == 1 }
            let inbox = try runtimeInbox(result.view.current())
            #expect(inbox.items.count == 1)
            #expect(inbox.items.first?.mode.rawValue == whenBusy.rawValue)
            #expect(inbox.items.first?.content == .string("busy input"))
            #expect(try !runtimeTexts(result.view.current(), kind: "pi.user").contains("busy input"))
            first.release()
            try await eventually { second.reached.isSignalled }
            #expect(requests.withLock { $0.last?.contains("busy input") } == true)
            #expect(try runtimeInbox(result.view.current()).items.isEmpty)
            second.release()
            try await runtimeWaitForAnswer(result, "second answer")
            #expect(try runtimeTexts(result.view.current(), kind: "pi.user") == ["first input", "busy input"])
            #expect(result.view.current().notices.isEmpty)
        }
    }

    @Test func unansweredModelErrorHasReasonAndJSONDetail() async throws {
        let paths = try RuntimePaths()
        defer { paths.remove() }
        let detail = "bad \"request\"\ntry again"
        let models = runtimeModels(responses: [.message(chatAssistant("", reason: .error, error: detail))])
        try await withRuntime(paths, models: models) { result in
            await result.controller.submit("fail", whenBusy: .followUp)
            try await eventually { result.view.current().notices.contains { $0.message.hasPrefix("No answer:") } }
            let notice = try #require(result.view.current().notices.first { $0.message.hasPrefix("No answer:") })
            #expect(notice.level == .error)
            #expect(notice.message == "No answer: model_error " + (try JSONValue.string(detail).jsonText()))
            try await eventually { try runtimeLive(result.view.current()).run == nil }
        }
    }

    @Test func abortWaitsForIdleAndDoesNotReportAnUnansweredError() async throws {
        let paths = try RuntimePaths()
        defer { paths.remove() }
        let hold = HarnessUnanswered()
        let models = runtimeModels(responses: [hold.step, .message(chatAssistant("after abort"))])
        try await withRuntime(paths, models: models) { result in
            await result.controller.submit("abort this", whenBusy: .followUp)
            try await eventually { hold.reached.isSignalled }
            try await eventually { try runtimeLive(result.view.current()).run != nil }
            #expect(try runtimeLive(result.view.current()).run != nil)
            await result.controller.abort()
            try await eventually { try runtimeLive(result.view.current()).run == nil }
            await result.controller.submit("start again", whenBusy: .followUp)
            try await runtimeWaitForAnswer(result, "after abort")
            #expect(result.view.current().notices.isEmpty)
        }
    }

    @Test func thinkingCyclesAndModelSelectionClampsThinking() async throws {
        let paths = try RuntimePaths()
        defer { paths.remove() }
        let models = runtimeModels()
        try await withRuntime(paths, models: models) { result in
            let levels = getSupportedThinkingLevels(models.models[0])
            var index = try #require(levels.firstIndex(of: .high))
            for _ in levels {
                index = (index + 1) % levels.count
                let expected = levels[index]
                await result.controller.cycleThinking()
                try await eventually { agentOf(result.view.current().conversation).thinkingLevel == expected }
            }
            #expect(agentOf(result.view.current().conversation).thinkingLevel == .high)
            let unknown = ModelRef(provider: "missing", modelId: "model")
            await result.controller.setModel(unknown)
            #expect(result.view.current().notices.last?.message == "Unknown model: missing/model")
            #expect(agentOf(result.view.current().conversation).model == runtimeModel)
            await result.controller.setModel(.init(provider: "faux", modelId: "plain"))
            try await eventually { agentOf(result.view.current().conversation).thinkingLevel == .off }
            #expect(agentOf(result.view.current().conversation).model == .init(provider: "faux", modelId: "plain"))
            await result.controller.cycleThinking()
            #expect(result.view.current().notices.last?.message == "Current model does not support thinking")
            #expect(result.view.current().notices.map(\.id) == [1, 2])
        }
    }

    @Test func startupNoticesForMissingModelAndFallback() async throws {
        let paths = try RuntimePaths()
        defer { paths.remove() }
        let result = try await paths.open(runtimeModels(), initial: { _ in .init(fallbackMessage: "Fallback selected.") })
        #expect(result.view.current().notices == [
            .init(id: 1, level: .warning, message: "No model configured; select one with /model."),
            .init(id: 2, level: .info, message: "Fallback selected.")
        ])
        await result.controller.cycleThinking()
        #expect(result.view.current().notices.last?.message == "No model selected")
        await result.controller.submit("input without model", whenBusy: .followUp)
        do {
            try await eventually { result.view.current().notices.contains { $0.message == "No answer: no_model" } }
        } catch { await result.close(); throw error }
        await result.close()
    }

    @Test func continuedSessionReportsUnavailableSavedModel() async throws {
        let paths = try RuntimePaths()
        defer { paths.remove() }
        let first = try await paths.open(runtimeModels())
        await first.close()
        let missing = FakeDurableModels(options: .init(models: [.init(id: "other")]))
        let second = try await paths.open(missing, continueSession: true)
        #expect(second.view.current().notices == [.init(id: 1, level: .warning, message: "Saved model is unavailable: faux/faux-1")])
        await second.controller.cycleThinking()
        #expect(second.view.current().notices.last?.message == "Current model is unavailable")
        await second.close()
    }

    @Test func taskPanelTogglesAndMissingConversationKeepsCurrentView() async throws {
        let paths = try RuntimePaths()
        defer { paths.remove() }
        try await withRuntime(paths, models: runtimeModels()) { result in
            #expect(result.view.current().tasks != nil)
            await result.controller.toggleTasks()
            #expect(result.view.current().tasks == nil)
            await result.controller.toggleTasks()
            #expect(result.view.current().tasks != nil)
            let conversation = result.view.current().conversation
            await result.controller.switchConversation(try ConversationID(999_999))
            #expect(result.view.current().notices.last?.message == "Conversation 999999 does not exist")
            #expect(result.view.current().conversation == conversation)
        }
    }

    @Test func subagentAppearsWithTitleAndCanBeSelectedAndTalkedTo() async throws {
        let paths = try RuntimePaths()
        defer { paths.remove() }
        let child = HarnessGatedResponse(message: chatAssistant("child answer"))
        let models = runtimeModels(responses: [
            .message(runtimeToolCall("subagent", arguments: ["task": AnyCodable("  child\n task\ttext  ")])),
            child.step, .message(chatAssistant("parent answer")), .message(chatAssistant("child reply"))
        ])
        try await withRuntime(paths, models: models) { result in
            await result.controller.submit("parent input", whenBusy: .followUp)
            try await eventually { child.reached.isSignalled }
            try await eventually { result.view.current().conversations.count == 2 }
            let summary = try #require(result.view.current().conversations.first { $0.id != rootConversationID })
            #expect(summary.title == "child task text")
            #expect(summary.label == "subagent \(summary.id.rawValue)")
            child.release()
            try await runtimeWaitForAnswer(result, "parent answer")
            await result.controller.switchConversation(summary.id)
            try await eventually { result.view.current().conversation.conversation.id == summary.id }
            #expect(try runtimeTexts(result.view.current()).contains("child answer"))
            await result.controller.submit("talk to child", whenBusy: .followUp)
            try await runtimeWaitForAnswer(result, "child reply")
            #expect(try runtimeTexts(result.view.current(), kind: "pi.user") == ["  child\n task\ttext  ", "talk to child"])
            await result.controller.switchConversation(rootConversationID)
            try await eventually { result.view.current().conversation.conversation.id == rootConversationID }
            #expect(try !runtimeTexts(result.view.current()).contains("child reply"))
            #expect(result.view.current().conversations.first?.title == "parent input")
            #expect(result.view.current().notices.isEmpty)
        }
        let reopened = try await paths.open(models, continueSession: true)
        #expect(reopened.view.current().conversations.count == 2)
        #expect(reopened.view.current().conversations.first { $0.id != rootConversationID }?.title == "child task text")
        await reopened.close()
    }

    @Test func emptyCompactionHasNoOpNotice() async throws {
        let paths = try RuntimePaths()
        defer { paths.remove() }
        try await withRuntime(paths, models: runtimeModels()) { result in
            await result.controller.compact(instructions: nil)
            try await eventually { !result.view.current().notices.isEmpty }
            #expect(result.view.current().notices.last?.level == .info)
            #expect(result.view.current().notices.last?.message == "Nothing to compact: the context fits in the recent window that is kept verbatim.")
        }
    }

    @Test func idleCompactionWritesSummaryAndForwardsInstructions() async throws {
        let paths = try RuntimePaths()
        defer { paths.remove() }
        let models = runtimeModels()
        let prompt = Mutex("")
        try await withRuntime(paths, models: models) { result in
            try await runtimeHistory(result, models: models)
            models.setResponses([.factory { transcript, _, _, _ in
                prompt.withLock { $0 = transcript.messages.compactMap { textOf($0) }.joined(separator: "\n") }
                return chatAssistant("SUMMARY")
            }])
            await result.controller.compact(instructions: "Keep file paths")
            try await eventually { result.view.current().notices.contains { $0.message == "Compacted." } }
            #expect(result.view.current().notices.last?.level == .info)
            #expect(prompt.withLock { $0.contains("Additional focus: Keep file paths") })
            #expect(result.view.current().conversation.entries.contains { $0.kind == "pi.compaction" })
            #expect(try runtimeTexts(result.view.current()).contains { $0.contains("<summary>\nSUMMARY\n</summary>") })
        }
    }

    @Test func busyCompactionReportsQueuedSummaryThenPlacesIt() async throws {
        let paths = try RuntimePaths()
        defer { paths.remove() }
        let models = runtimeModels()
        let gate = HarnessGatedResponse(message: chatAssistant("busy answer"))
        try await withRuntime(paths, models: models) { result in
            try await runtimeHistory(result, models: models)
            models.setResponses([gate.step, .message(chatAssistant("QUEUED SUMMARY"))])
            await result.controller.submit("busy input", whenBusy: .followUp)
            try await eventually { gate.reached.isSignalled }
            await result.controller.compact(instructions: nil)
            try await eventually { result.view.current().notices.contains { $0.message == "Compaction summary queued; it is placed at the next turn boundary." } }
            #expect(!result.view.current().conversation.entries.contains { $0.kind == "pi.compaction" })
            #expect(try runtimeInbox(result.view.current()).items.contains { $0.mode == .write })
            gate.release()
            try await runtimeWaitForAnswer(result, "busy answer")
            try await eventually { result.view.current().conversation.entries.contains { $0.kind == "pi.compaction" } }
        }
    }

    @Test func olderCompactionReportsDroppedSummaryAfterContextChanges() async throws {
        let paths = try RuntimePaths()
        defer { paths.remove() }
        let models = runtimeModels()
        let old = HarnessGatedResponse(message: chatAssistant("OLD SUMMARY"))
        try await withRuntime(paths, models: models) { result in
            try await runtimeHistory(result, models: models)
            models.setResponses([old.step, .message(chatAssistant("a4 " + String(repeating: "x", count: 396))), .message(chatAssistant("NEW SUMMARY"))])
            await result.controller.compact(instructions: nil)
            try await eventually { old.reached.isSignalled }
            await result.controller.submit("u4 " + String(repeating: "x", count: 396), whenBusy: .followUp)
            try await runtimeWaitForAnswer(result, "a4 " + String(repeating: "x", count: 396))
            await result.controller.compact(instructions: nil)
            try await eventually { result.view.current().notices.contains { $0.message == "Compacted." } }
            old.release()
            try await eventually { result.view.current().notices.contains { $0.message == "Compaction summary dropped: the context changed under it." } }
            #expect(try runtimeTexts(result.view.current()).contains { $0.contains("NEW SUMMARY") })
            #expect(try !runtimeTexts(result.view.current()).contains { $0.contains("OLD SUMMARY") })
        }
    }

    @Test func compactionFailureAndAbortHaveOutcomeNotices() async throws {
        let paths = try RuntimePaths()
        defer { paths.remove() }
        let models = runtimeModels()
        let hold = HarnessUnanswered()
        try await withRuntime(paths, models: models) { result in
            try await runtimeHistory(result, models: models)
            models.setResponses([.message(chatAssistant("", reason: .error, error: "summary failed")), hold.step])
            await result.controller.compact(instructions: nil)
            try await eventually { result.view.current().notices.contains { $0.message == "Compaction failed: Summarization failed: summary failed" } }
            #expect(result.view.current().notices.last?.level == .error)
            await result.controller.compact(instructions: nil)
            try await eventually { hold.reached.isSignalled }
            await result.controller.abort()
            try await eventually { result.view.current().notices.contains { $0.message == "Compaction aborted." } }
            #expect(result.view.current().notices.last?.level == .info)
            try await eventually { try runtimeLive(result.view.current()).compactions == nil }
            #expect(!result.view.current().notices.contains { $0.message.hasPrefix("No answer:") })
        }
    }

    @Test func closeTwiceReleasesSessionLock() async throws {
        let paths = try RuntimePaths()
        defer { paths.remove() }
        let models = runtimeModels()
        let first = try await paths.open(models)
        let directory = first.view.current().session.directory
        let descriptor = open(directory + "/session.lock", O_RDWR)
        #expect(descriptor >= 0)
        if descriptor >= 0 {
            #expect(flock(descriptor, LOCK_EX | LOCK_NB) == -1)
            #expect(errno == EWOULDBLOCK)
            _ = Darwin.close(descriptor)
        }
        await first.close()
        await first.close()
        let continued = try await paths.open(models, continueSession: true)
        #expect(continued.view.current().session.directory == directory)
        #expect(continued.view.current().notices.isEmpty)
        await continued.close()
    }

    #if os(macOS)
    @Test func closeStopsLocalBashAndContinueRecoversTurn() async throws {
        let paths = try RuntimePaths()
        defer { paths.remove() }
        let marker = paths.cwd.appendingPathComponent("shell.pid")
        let command = "echo $$ > shell.pid; echo runtime-ready; sleep 60"
        let models = runtimeModels(responses: [
            .message(runtimeToolCall("bash", arguments: ["command": AnyCodable(command)])),
            .message(chatAssistant("recovered answer"))
        ])
        let first = try await paths.open(models)
        let session = first.view.current().session.id
        await first.controller.submit("run bash", whenBusy: .followUp)
        let processID: Int32
        do {
            try await eventually {
                let live = try runtimeLive(first.view.current())
                return FileManager.default.fileExists(atPath: marker.path)
                    && live.tools?.contains { $0.name == "bash" && $0.output?.contains("runtime-ready") == true } == true
            }
            processID = try #require(Int32(String(contentsOf: marker, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
            #expect(kill(processID, 0) == 0)
        } catch { await first.close(); throw error }
        let closed = settled { await first.close() }
        try await eventually(timeout: .seconds(10)) { closed.isSettled }
        try await eventually { kill(processID, 0) == -1 && errno == ESRCH }
        await first.close()
        let continued = try await paths.open(models, continueSession: true)
        do {
            #expect(continued.view.current().session.id == session)
            try await runtimeWaitForAnswer(continued, "recovered answer")
            #expect(try runtimeTexts(continued.view.current(), kind: "pi.user") == ["run bash"])
            let entry = try #require(continued.view.current().conversation.entries.first { $0.kind == "pi.tool-result" })
            guard case .toolResult(let toolResult) = try entry.messages()?.first else {
                throw TaskDefinitionError("Expected the interrupted bash result")
            }
            #expect(toolResult.isError)
            #expect(textOf(.toolResult(toolResult))?.contains("runtime-ready") == true)
            #expect(entry.data?["diagnostics"]?[0]?["code"] == .string("interrupted"))
            #expect(entry.data?["diagnostics"]?[0]?["message"] == .string("Tool bash was interrupted and may have partially run"))
            #expect(!continued.view.current().notices.contains { $0.message.hasPrefix("No answer:") })
        } catch { await continued.close(); throw error }
        await continued.close()
    }
    #endif
}
