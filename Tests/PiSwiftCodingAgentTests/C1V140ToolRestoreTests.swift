import Foundation
import Testing
import PiSwiftAI
import PiSwiftAgent
@testable import PiSwiftCodingAgent

// Upstream bd3c9b823, default-tools-setting.test.ts:369-423.
@Suite("C1 v1.4.0 branch tool restore")
struct C1V140ToolRestoreTests {
    private func record(_ manager: SessionManager, added: [String], removed: [String] = []) {
        manager.appendMessage(.system(SystemMessage(content: .text(""),
            toolsAdded: added.map { AITool(name: $0, description: $0, parameters: ["type": AnyCodable("object")]) },
            toolsRemoved: removed.map { ToolReference(name: $0) })))
    }

    private func tool(_ name: String, active: Bool) -> CustomTool {
        CustomTool(name: name, label: name, description: name, parameters: [:],
            execute: { _, _, _, _, _ in AgentToolResult(content: []) }, defaultActive: active)
    }

    private func resume(_ manager: SessionManager, names: [String]? = nil) async throws -> AgentSession {
        let model = getModel(provider: .openai, modelId: "gpt-4o-mini")
        let tools = [tool("active_tool", active: true), tool("inactive_tool", active: false),
                     tool("mcp__server__lookup", active: true)]
        return try await createAgentSession(CreateAgentSessionOptions(
            cwd: manager.getCwd(), agentDir: manager.getCwd(),
            authStorage: .inMemory([model.provider: .apiKey(ApiKeyCredential(key: "test"))]),
            model: model, offline: true, toolNames: names,
            customTools: [], resourceLoader: TestResourceLoader(), hooks: [],
            inlineExtensions: [InlineExtension(name: "v140-restore-tools") { api in
                for tool in tools { try api.registerTool(tool).get() }
            }], sessionManager: manager, settingsManager: .inMemory())).session
    }

    private func directory() throws -> URL {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("v140-restore-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        return path
    }

    @Test func unmentionedDefaultActiveToolsBecomeActive() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let manager = SessionManager.inMemory(directory.path)
        record(manager, added: ["read", "grep"], removed: ["mcp__server__lookup"])
        let session = try await resume(manager)
        defer { session.dispose() }
        #expect(session.getActiveToolNames().sorted() == ["active_tool", "grep", "read"])
        #expect(!session.getActiveToolNames().contains("inactive_tool"))
    }

    @Test func removalBeforeCompactionStaysInactive() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let manager = SessionManager.inMemory(directory.path)
        record(manager, added: ["read", "grep", "active_tool"])
        record(manager, added: ["inactive_tool"], removed: ["active_tool", "mcp__server__lookup"])
        let kept = manager.appendMessage(.user(UserMessage(content: .text("hi"))))
        manager.appendCompaction("summary", kept, 1000)
        let session = try await resume(manager)
        defer { session.dispose() }
        #expect(session.getActiveToolNames().sorted() == ["grep", "inactive_tool", "read"])
    }

    @Test func treeNavigationReplaysTheTargetBranch() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let manager = SessionManager.inMemory(directory.path)
        record(manager, added: ["read", "grep"], removed: ["mcp__server__lookup"])
        record(manager, added: [], removed: ["grep"])
        let target = manager.appendMessage(.user(UserMessage(content: .text("first"))))
        record(manager, added: ["grep"], removed: ["active_tool"])
        let session = try await resume(manager)
        defer { session.dispose() }
        #expect(session.getActiveToolNames().sorted() == ["grep", "read"])
        let result = await session.navigateTree(target)
        #expect(!result.cancelled)
        #expect(session.getActiveToolNames().sorted() == ["active_tool", "read"])
    }

    @Test func treeNavigationKeepsMcpOutsideAllowlistInactive() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let manager = SessionManager.inMemory(directory.path)
        record(manager, added: ["read"])
        let target = manager.appendMessage(.user(UserMessage(content: .text("first"))))
        let session = try await resume(manager, names: ["read"])
        defer { session.dispose() }
        #expect(session.getAllToolNames().contains("mcp__server__lookup"))
        #expect(session.getActiveToolNames() == ["read"])
        let result = await session.navigateTree(target)
        #expect(!result.cancelled)
        #expect(session.getAllToolNames().contains("mcp__server__lookup"))
        #expect(session.getActiveToolNames() == ["read"])
    }

    // Upstream bd3c9b823: Restore honors defaultActive even when an allowlist names the tool.
    @Test(.timeLimit(.minutes(1))) func allowlistDoesNotActivateUnmentionedInactiveToolsOnResumeOrTree() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let manager = SessionManager.create(directory.path, directory.path)
        record(manager, added: ["read"])
        let target = manager.appendMessage(.user(UserMessage(content: .text("first"))))
        let model = getModel(provider: .openai, modelId: "gpt-4o-mini")
        manager.appendMessage(.assistant(AssistantMessage(content: [.text(TextContent(text: "done"))],
            api: model.api, provider: model.provider, model: model.id,
            usage: Usage(input: 1, output: 1, cacheRead: 0, cacheWrite: 0, totalTokens: 2), stopReason: .stop)))
        manager.appendMessage(.user(UserMessage(content: .text("later"))))
        let path = try #require(manager.getSessionFile())
        let session = try await resume(SessionManager.inMemory(directory.path),
            names: ["read", "active_tool", "inactive_tool"])
        defer { session.dispose() }
        // Explicit initial selection can still activate a default-inactive tool.
        #expect(session.getActiveToolNames().sorted() == ["active_tool", "inactive_tool", "read"])
        session.setActiveToolsByName(["read"])
        #expect(await session.switchSession(path))
        #expect(session.getAllToolNames().contains("inactive_tool"))
        #expect(session.getActiveToolNames().sorted() == ["active_tool", "read"])
        session.setActiveToolsByName(["read"])
        let navigation = await session.navigateTree(target, summarize: false)
        #expect(!navigation.cancelled)
        #expect(session.getAllToolNames().contains("inactive_tool"))
        #expect(session.getActiveToolNames().sorted() == ["active_tool", "read"])
    }
}
