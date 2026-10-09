import Foundation
import PiSwiftAI
import PiSwiftCodingAgent
import PiSwiftCodingAgentDurable
import PiSwiftDurable
import Testing

#if os(macOS)
import Darwin

private let scenarioKey = "PI_DURABLE_PUBLIC_API_SCENARIO"
private let providerID = "i6-public-faux"
private let modelID = "i6-answer"
private let inputText = "Give the saved answer."
private let answerText = "The durable answer is saved."

private final class PublicAPITestBundle: NSObject {}

private enum PublicAPITestError: Error {
    case missingRunner
    case childTimeout
    case answerTimeout
}

/// Run the built test directly. A nested swift test command would take the package build lock.
private func runPublicAPIScenario(_ scenario: String) async throws {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent("i6-public-\(UUID())")
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: base) }
    let output = base.appendingPathComponent("child.log")
    #expect(FileManager.default.createFile(atPath: output.path, contents: nil))
    let log = try FileHandle(forWritingTo: output)
    defer { try? log.close() }

    let child = Process()
    let runner = URL(fileURLWithPath: CommandLine.arguments[0])
    if runner.lastPathComponent == "swiftpm-testing-helper" {
        child.executableURL = runner
        let bundle = try #require(Bundle(for: PublicAPITestBundle.self).executableURL)
        child.arguments = ["--test-bundle-path", bundle.path,
                           "--filter", "PiSwiftCodingAgentDurableTests.publicAPIScenarioChild",
                           "--testing-library", "swift-testing"]
    } else if runner.path.contains(".xctest/Contents/MacOS/") {
        // The native SwiftPM build system supplies an executable test runner.
        child.executableURL = runner
        child.arguments = ["--testing-library", "swift-testing",
                           "--filter", "PiSwiftCodingAgentDurableTests.publicAPIScenarioChild"]
    } else {
        throw PublicAPITestError.missingRunner
    }
    var environment = ProcessInfo.processInfo.environment
    environment[ENV_AGENT_DIR] = base.appendingPathComponent("agent").path
    environment[scenarioKey] = scenario
    environment["PI_DURABLE_PUBLIC_API_CWD"] = base.appendingPathComponent("project").path
    child.environment = environment
    child.standardOutput = log
    child.standardError = log
    try child.run()
    defer {
        if child.isRunning { _ = kill(child.processIdentifier, SIGKILL); child.waitUntilExit() }
    }
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(30))
    while child.isRunning {
        try Task.checkCancellation()
        guard clock.now < deadline else { throw PublicAPITestError.childTimeout }
        try await Task.sleep(for: .milliseconds(20))
    }
    child.waitUntilExit()
    let text = try String(contentsOf: output, encoding: .utf8)
    #expect(child.terminationReason == .exit && child.terminationStatus == 0, "\(text)")
    // A zero exit code alone would also accept a child filter that ran no test.
    #expect(text.contains("I6 public API scenario passed: \(scenario)"), "\(text)")
}

@Test(.timeLimit(.minutes(1)))
func publicOpenDurablePersistsAndContinuesWithRegistryAndAuth() async throws {
    try await runPublicAPIScenario("end-to-end")
}

@Test(.timeLimit(.minutes(1)))
func readmeOpenDurableExampleRuns() async throws {
    let file = URL(fileURLWithPath: #filePath)
    let root = file.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let readme = try String(contentsOf: root.appendingPathComponent("Sources/PiSwiftCodingAgentDurable/README.md"), encoding: .utf8)
    let source = try String(contentsOf: file, encoding: .utf8)
    let example = try #require(source.components(separatedBy: "// BEGIN README EXAMPLE\n").last?
        .components(separatedBy: "// END README EXAMPLE").first)
    let block = try #require(readme.components(separatedBy: "```swift\n").dropFirst().first?
        .components(separatedBy: "```").first)
    #expect(block == "import Foundation\nimport PiSwiftCodingAgentDurable\n\n" + example)
    try await runPublicAPIScenario("readme")
}

private func transcriptText(_ session: OpenDurableResult, kind: String) throws -> [String] {
    try session.view.current().conversation.entries.filter { $0.kind == kind }.flatMap { entry in
        try (entry.messages() ?? []).flatMap { message -> [String] in
            switch message {
            case .assistant(let value):
                return value.content.compactMap { if case .text(let block) = $0 { block.text } else { nil } }
            case .user(let value):
                switch value.content {
                case .text(let text): return [text]
                case .blocks(let blocks):
                    return blocks.compactMap { if case .text(let block) = $0 { block.text } else { nil } }
                }
            default: return []
            }
        }
    }
}

private func waitForAnswer(_ session: OpenDurableResult) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(10))
    while try !transcriptText(session, kind: "pi.assistant").contains(answerText) {
        guard clock.now < deadline else {
            Issue.record("Answer absent. Notices: \(session.view.current().notices)")
            throw PublicAPITestError.answerTimeout
        }
        try await Task.sleep(for: .milliseconds(10))
    }
}

// BEGIN README EXAMPLE
private func embeddedSession(cwd: String) async throws -> DurableView {
    let session = try await openDurable(.init(cwd: cwd))
    do {
        await session.controller.submit("Give the saved answer.", whenBusy: .steer)
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while !session.view.current().conversation.entries.contains(where: { $0.kind == "pi.assistant" }) {
            guard ContinuousClock.now < deadline else { throw CancellationError() }
            try await Task.sleep(for: .milliseconds(10))
        }
        let view = session.view.current()
        await session.close()
        return view
    } catch {
        await session.close()
        throw error
    }
}
// END README EXAMPLE

@Test(.enabled(if: ProcessInfo.processInfo.environment[scenarioKey] != nil), .timeLimit(.minutes(1)))
func publicAPIScenarioChild() async throws {
    let scenario = try #require(ProcessInfo.processInfo.environment[scenarioKey])
    let cwd = try #require(ProcessInfo.processInfo.environment["PI_DURABLE_PUBLIC_API_CWD"])
    let agent = getAgentDir()
    try FileManager.default.createDirectory(atPath: cwd, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(atPath: agent, withIntermediateDirectories: true)
    let directory = URL(fileURLWithPath: agent)
    let settings = """
    {"defaultProvider":"i6-public-faux","defaultModel":"i6-answer","defaultThinkingLevel":"off",
     "retry":{"enabled":false},"compaction":{"enabled":false}}
    """
    try Data(settings.utf8).write(to: directory.appendingPathComponent("settings.json"))
    // No configured key: the adapter must load this credential from auth.json.
    let models = """
    {"providers":{"i6-public-faux":{"api":"openai-completions","baseUrl":"https://i6.invalid/v1",
      "models":[{"id":"i6-answer","name":"I6 offline answer","contextWindow":128000,"maxTokens":16384}]}}}
    """
    try Data(models.utf8).write(to: directory.appendingPathComponent("models.json"))
    let auth = AuthStorage.create(directory.appendingPathComponent("auth.json").path)
    auth.set(providerID, credential: .apiKey(ApiKeyCredential(key: "i6-stored-key")))
    let faux = registerFauxProvider(.init(api: Api.openAICompletions.rawValue, provider: providerID,
                                          models: [.init(id: modelID)]))
    defer { faux.unregister() }
    faux.setResponses([.factory { context, options, _, model in
        #expect(options?.apiKey == "i6-stored-key")
        #expect(model.provider == providerID && model.id == modelID)
        #expect(model.baseUrl == "https://i6.invalid/v1")
        #expect(!context.messages.isEmpty)
        return fauxAssistantMessage(content: [fauxText(answerText)])
    }])

    if scenario == "readme" {
        let view = try await embeddedSession(cwd: cwd)
        #expect(view.conversation.entries.contains { $0.kind == "pi.assistant" })
    } else {
        let session = try await openDurable(.init(cwd: cwd))
        let before: DurableView
        do {
            #expect(session.view.current().models.contains { $0.provider == providerID && $0.modelId == modelID })
            #expect(agentOf(session.view.current().conversation).model == .init(provider: providerID, modelId: modelID))
            await session.controller.submit(inputText, whenBusy: .steer)
            try await waitForAnswer(session)
            before = session.view.current()
            #expect(try transcriptText(session, kind: "pi.user") == [inputText])
            #expect(try transcriptText(session, kind: "pi.assistant") == [answerText])
            #expect(before.notices.allSatisfy { $0.level != .error })
            await session.close()
        } catch { await session.close(); throw error }

        let continued = try await openDurable(.init(cwd: cwd, continueSession: true))
        do {
            let after = continued.view.current()
            #expect(after.session == before.session)
            #expect(after.conversation.entries == before.conversation.entries)
            #expect(try transcriptText(continued, kind: "pi.user") == [inputText])
            #expect(try transcriptText(continued, kind: "pi.assistant") == [answerText])
            #expect(agentOf(after.conversation).model == .init(provider: providerID, modelId: modelID))
            await continued.close()
        } catch { await continued.close(); throw error }
    }
    #expect(faux.state().callCount == 1)
    print("I6 public API scenario passed: \(scenario)")
}
#endif
