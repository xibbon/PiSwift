import Foundation
import Testing
import PiSwiftAI
import PiSwiftAgent
@testable import PiSwiftCodingAgent

private struct RecordedBashCall: Sendable {
    var command: String
    var cwd: String?
    var environment: [String: String]
}

/// Answers every command itself, so a call that reached the shell or the registry instead
/// would not show up here.
private struct RecordingBashOperations: BashOperations {
    let label: String
    let calls = LockedState<[RecordedBashCall]>([])

    func execute(_ command: String, options: BashExecutorOptions?) async throws -> BashResult {
        calls.withLock {
            $0.append(RecordedBashCall(command: command, cwd: options?.cwd, environment: options?.environment ?? [:]))
        }
        let output = "\(label):\(command)"
        options?.onChunk?(output)
        return BashResult(output: output, exitCode: 0, cancelled: false, truncated: false)
    }

    var commands: [String] {
        calls.withLock { $0.map(\.command) }
    }
}

private func bashOperationsModel() -> Model {
    Model(
        id: "bash-operations-model",
        name: "Bash operations model",
        api: .openAICompletions,
        provider: "bash-operations-provider",
        baseUrl: "https://provider.example/v1",
        reasoning: false,
        input: [.text],
        cost: ModelCost(input: 0, output: 0, cacheRead: 0, cacheWrite: 0),
        contextWindow: 32_000,
        maxTokens: 4_096
    )
}

private func textOutput(_ result: AgentToolResult) -> String {
    result.content.compactMap { block in
        if case .text(let text) = block { return text.text }
        return nil
    }.joined(separator: "\n")
}

private func withTempDir(_ body: (String) async throws -> Void) async rethrows {
    let tempDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("bash-operations-test-\(UUID().uuidString)")
        .path
    try? FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: tempDir) }
    try await body(tempDir)
}

@Test func bashToolRunsThroughSuppliedOperations() async throws {
    try await withTempDir { dir in
        let operations = RecordingBashOperations(label: "ops")
        let tools = createAllTools(cwd: dir, options: ToolsOptions(bash: BashToolOptions(operations: operations)))
        let bash = try #require(tools[.bash])

        let result = try await bash.execute("call-1", ["command": AnyCodable("no-such-command-on-any-shell")], nil, nil)

        #expect(textOutput(result) == "ops:no-such-command-on-any-shell")
        #expect(operations.commands == ["no-such-command-on-any-shell"])
        #expect(operations.calls.withLock { $0.first?.cwd } == dir)
    }
}

@Test func bashToolIsIncludedWhenOperationsAreSupplied() {
    // On macOS the system shell always counts as available; this guards the iOS branch,
    // where the registry reports no bash unless an embedder registered one.
    let operations = RecordingBashOperations(label: "ops")
    #expect(shouldIncludeBashTool(BashToolOptions(operations: operations)))
    let names = createCodingTools(cwd: "/tmp", options: ToolsOptions(bash: BashToolOptions(operations: operations)))
        .map(\.name)
    #expect(names.contains("bash"))
}

@Test func sessionBashRunsThroughSessionOperations() async throws {
    try await withTempDir { dir in
        let operations = RecordingBashOperations(label: "session")
        let model = bashOperationsModel()
        let auth = AuthStorage(":memory:")
        auth.setRuntimeApiKey(model.provider, "test-key")
        let sessionManager = SessionManager.inMemory(dir)
        // C1 U3: SDK tool-list validation now throws.
        let result = try await createAgentSession(CreateAgentSessionOptions(
            cwd: dir,
            agentDir: dir,
            authStorage: auth,
            modelRegistry: ModelRegistry(auth),
            model: model,
            projectTrusted: false,
            offline: true,
            toolNames: ["bash"],
            hooks: [],
            sessionManager: sessionManager,
            settingsManager: SettingsManager.inMemory(),
            bashOperations: operations
        ))
        // No `dispose()`: it kills every tracked shell child in the process, which would
        // race the real commands of tests running beside this one. This session spawns none.
        let session = result.session

        // A user `!` command without explicit operations.
        let user = try await session.executeBash("user-command", excludeFromContext: true)
        #expect(user.output == "session:user-command")
        #expect(operations.calls.withLock { $0.last?.cwd } == sessionManager.getCwd())

        // Explicit operations still win over the session's.
        let explicit = RecordingBashOperations(label: "explicit")
        let override = try await session.executeBash("explicit-command", excludeFromContext: true, operations: explicit)
        #expect(override.output == "explicit:explicit-command")
        #expect(explicit.commands == ["explicit-command"])

        // The model's bash tool, with the session environment it always carried.
        let bash = try #require(session.agent.state.tools.first { $0.name == "bash" })
        let toolResult = try await bash.execute("call-1", ["command": AnyCodable("tool-command")], nil, nil)
        #expect(textOutput(toolResult) == "session:tool-command")
        #expect(operations.commands == ["user-command", "tool-command"])
        #expect(operations.calls.withLock { $0.last?.environment["PI_SESSION_ID"] } == sessionManager.getSessionId())
    }
}

@Test func subagentToolsRunThroughParentOperations() async throws {
    try await withTempDir { dir in
        let operations = RecordingBashOperations(label: "parent")
        let auth = AuthStorage(":memory:")
        let dependencies = SubagentToolDependencies(
            cwd: dir,
            agentDir: dir,
            modelRegistry: ModelRegistry(auth),
            settingsManager: SettingsManager.inMemory(),
            defaultModel: bashOperationsModel(),
            defaultThinkingLevel: .off,
            bashOperations: operations
        )
        func subagent(tools: [String]) -> SubagentConfig {
            SubagentConfig(
                name: "worker",
                description: "test",
                tools: tools,
                model: nil,
                outputFormat: nil,
                systemPrompt: "",
                source: .user,
                sourceLabel: "user",
                path: dir
            )
        }

        // The named tool, and the fallback set used when no requested tool is known.
        for tools in [["bash"], ["no-such-tool"]] {
            let resolution = resolveTools(agent: subagent(tools: tools), cwd: dir, dependencies: dependencies)
            let bash = try #require(resolution.tools.first { $0.name == "bash" })
            let result = try await bash.execute("call-1", ["command": AnyCodable("subagent-command")], nil, nil)
            #expect(textOutput(result) == "parent:subagent-command")
        }
        #expect(operations.commands == ["subagent-command", "subagent-command"])
    }
}

#if !canImport(UIKit)
@Test func systemBashOperationsBypassTheRegistry() async throws {
    let marker = "system-bash-\(UUID().uuidString)"
    let seenByRegistry = LockedState<[String]>([])
    let previous = BashExecutorRegistry.provider()
    // Other tests share the registry, so this provider forwards everything and only
    // records whether the marker command passed through it.
    BashExecutorRegistry.register(BashExecutorProvider(
        execute: { command, options in
            if command.contains(marker) {
                seenByRegistry.withLock { $0.append(command) }
            }
            return try await previous.execute(command, options)
        },
        isAvailable: previous.isAvailable
    ))
    defer { BashExecutorRegistry.register(previous) }

    let result = try await SystemBashOperations().execute("printf %s \(marker)", options: nil)

    #expect(result.output == marker)
    #expect(result.exitCode == 0)
    #expect(seenByRegistry.withLock { $0 }.isEmpty)
}
#endif
