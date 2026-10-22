import Foundation
import Testing
import PiSwiftAI
import PiSwiftAgent
@testable import PiSwiftCodingAgent

// Port of v1.3.0 default-tools-setting.test.ts:293-400, resume (#10785/#10887).
@Suite("C1b resume tools")
struct C1bResumeToolsTests {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("c1b-resume-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func recordedSession(_ directory: URL, names: [String]) -> SessionManager {
        let manager = SessionManager.inMemory(directory.path)
        manager.appendMessage(.system(SystemMessage(content: .text(""), toolsAdded: names.map {
            AITool(name: $0, description: $0, parameters: ["type": AnyCodable("object")])
        })))
        return manager
    }

    private func tool(_ name: String, active: Bool = false) -> CustomTool {
        CustomTool(name: name, label: name, description: name, parameters: [:],
            execute: { _, _, _, _, _ in AgentToolResult(content: []) }, defaultActive: active)
    }

    private func resume(_ directory: URL, manager: SessionManager, names: [String]? = nil,
                        exclude: [String]? = nil, noTools: NoToolsMode? = nil,
                        extraExtensions: [InlineExtension] = []) async throws -> AgentSession {
        let model = getModel(provider: .openai, modelId: "gpt-4o-mini")
        let tools = [tool("inactive_tool"), tool("active_tool", active: true)]
        let extensions = [InlineExtension(name: "resume-tools") { api in
            for tool in tools { try api.registerTool(tool).get() }
        }] + extraExtensions
        return try await createAgentSession(CreateAgentSessionOptions(
            cwd: directory.path, agentDir: directory.path,
            authStorage: .inMemory([model.provider: .apiKey(ApiKeyCredential(key: "test"))]),
            model: model, offline: true, toolNames: names, excludeTools: exclude, noTools: noTools,
            customTools: [], resourceLoader: TestResourceLoader(), hooks: [], inlineExtensions: extensions,
            sessionManager: manager, settingsManager: .inMemory())).session
    }

    @Test(.timeLimit(.minutes(1))) func restoresRecordedLoadout() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let manager = recordedSession(directory, names: ["read", "grep", "inactive_tool"])
        let session = try await resume(directory, manager: manager)
        defer { session.dispose() }
        #expect(session.getActiveToolNames().sorted() == ["grep", "inactive_tool", "read"])
    }

    @Test(.timeLimit(.minutes(1))) func doesNotRestoreExcludedTools() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let manager = recordedSession(directory, names: ["read", "grep", "inactive_tool"])
        let session = try await resume(directory, manager: manager, exclude: ["inactive_*"])
        defer { session.dispose() }
        #expect(session.getActiveToolNames().sorted() == ["grep", "read"])
    }

    @Test(.timeLimit(.minutes(1))) func explicitOptionsOverrideRecordedLoadout() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let recorded = ["read", "grep", "inactive_tool"]
        let allowlisted = try await resume(directory, manager: recordedSession(directory, names: recorded),
                                          names: ["read", "write"])
        defer { allowlisted.dispose() }
        #expect(allowlisted.getActiveToolNames() == ["read", "write"])
        let builtinless = try await resume(directory, manager: recordedSession(directory, names: recorded),
                                          noTools: .builtin)
        defer { builtinless.dispose() }
        #expect(builtinless.getActiveToolNames() == ["active_tool"])
        let noTools = try await resume(directory, manager: recordedSession(directory, names: recorded),
                                      noTools: .all)
        defer { noTools.dispose() }
        #expect(noTools.getActiveToolNames().isEmpty)
        #expect(noTools.getAllToolNames().isEmpty)
    }

    @Test(.timeLimit(.minutes(1))) func appliesModifiersToRecordedLoadout() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let manager = recordedSession(directory, names: ["read", "grep", "inactive_tool"])
        let session = try await resume(directory, manager: manager, names: ["-grep", "+write"])
        defer { session.dispose() }
        #expect(session.getActiveToolNames().sorted() == ["inactive_tool", "read", "write"])
    }

    @Test(.timeLimit(.minutes(1))) func missingRecordedLoadoutKeepsDefaults() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let manager = SessionManager.inMemory(directory.path)
        manager.appendMessage(.user(UserMessage(content: .text("hi"))))
        let session = try await resume(directory, manager: manager)
        defer { session.dispose() }
        // The Swift SDK also activates its existing subagent tool by default.
        #expect(session.getActiveToolNames().sorted() == ["active_tool", "bash", "edit", "read", "subagent", "write"])
    }

    @Test(.timeLimit(.minutes(1))) func recordedEmptyLoadoutClearsDefaults() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let session = try await resume(directory, manager: recordedSession(directory, names: []))
        defer { session.dispose() }
        #expect(session.getActiveToolNames().isEmpty)
    }

    @Test(.timeLimit(.minutes(1))) func lateRegistrationKeepsModifiersAndExclusions() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let savedAPI = LockedState<HookAPI?>(nil)
        let capture = InlineExtension(name: "late-resume-tools") { api in savedAPI.withLock { $0 = api } }
        let manager = recordedSession(directory, names: ["read", "late_tool", "mcp__docs__search", "late_removed", "late_excluded"])
        let session = try await resume(directory, manager: manager, names: ["-late_removed", "+late_added"],
                                       exclude: ["late_excluded"], extraExtensions: [capture])
        defer { session.dispose() }
        #expect(session.getActiveToolNames() == ["read"])
        let api = try #require(savedAPI.withLock { $0 })
        for name in ["late_tool", "mcp__docs__search", "late_removed", "late_excluded", "late_added"] {
            try api.registerTool(tool(name)).get()
        }
        #expect(session.getActiveToolNames().sorted() == ["late_added", "late_tool", "mcp__docs__search", "read"])
        #expect(!session.getAllToolNames().contains("late_excluded"))
    }

    @Test(.timeLimit(.minutes(1))) func treeNavigationDoesNotApplyStartupModifiers() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let manager = recordedSession(directory, names: ["read", "grep", "inactive_tool"])
        let recordedLeaf = try #require(manager.getLeafId())
        manager.appendMessage(.user(UserMessage(content: .text("later branch"))))
        let session = try await resume(directory, manager: manager, names: ["-grep", "+write"])
        defer { session.dispose() }
        #expect(session.getActiveToolNames().sorted() == ["inactive_tool", "read", "write"])
        let result = await session.navigateTree(recordedLeaf)
        #expect(!result.cancelled)
        #expect(session.getActiveToolNames().sorted() == ["grep", "inactive_tool", "read"])
    }
}
