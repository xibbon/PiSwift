import Foundation
import Testing
import PiSwiftAI
import PiSwiftAgent
@testable import PiSwiftCodingAgent

// Port of v1.0.0 default-tools-setting.test.ts, reload (#10245).
@Suite("C3 default tools reload")
struct C3DefaultToolsReloadTests {
    private func writeSettings(_ directory: URL, _ json: String) throws {
        try json.write(to: directory.appendingPathComponent("settings.json"), atomically: true, encoding: .utf8)
    }

    private func createSession(_ directory: URL, tools: [String]? = nil,
                               noTools: NoToolsMode? = nil, exclude: [String]? = nil) async throws -> AgentSession {
        let model = getModel(provider: .openai, modelId: "gpt-4o-mini")
        let auth = AuthStorage.inMemory([model.provider: .apiKey(ApiKeyCredential(key: "test"))])
        let extensionFactory = InlineExtension(name: "inactive") { api in
            _ = api.registerTool(CustomTool(name: "inactive_tool", label: "Inactive", description: "inactive",
                parameters: [:], execute: { _, _, _, _, _ in AgentToolResult(content: []) }, defaultActive: false))
        }
        let created = await createAgentSession(CreateAgentSessionOptions(
            cwd: directory.path, agentDir: directory.path, authStorage: auth, model: model,
            offline: true, toolNames: tools, excludeTools: exclude, noTools: noTools,
            customTools: [], resourceLoader: TestResourceLoader(), hooks: [],
            inlineExtensions: [extensionFactory], sessionManager: .inMemory(directory.path),
            settingsManager: .create(directory.path, directory.path)))
        return created.session
    }

    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("c3-default-tools-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test(.timeLimit(.minutes(1))) func reloadActivatesOnlyNewDefaultNames() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let session = try await createSession(directory)
        defer { session.dispose() }
        // Swift also includes its existing subagent tool in the default SDK roster.
        #expect(session.getActiveToolNames() == ["read", "bash", "edit", "write", "subagent"])
        #expect(session.getAllTools().contains { $0.name == "grep" })
        session.setActiveToolsByName(["read", "edit", "write"])
        try writeSettings(directory, #"{"defaultTools":["+inactive_tool","+grep"]}"#)
        await session.reload()
        #expect(session.getActiveToolNames() == ["read", "edit", "write"])
        await session.reloadExtensions()
        #expect(session.getActiveToolNames().sorted() == ["edit", "grep", "inactive_tool", "read", "write"])
        try writeSettings(directory, #"{"defaultTools":["-read"]}"#)
        await session.reload()
        await session.reloadExtensions()
        #expect(session.getActiveToolNames().sorted() == ["edit", "grep", "inactive_tool", "read", "write"])
    }

    @Test(.timeLimit(.minutes(1))) func reloadKeepsExplicitToolOptionPriority() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        for noTools in [NoToolsMode.builtin, .all] {
            try writeSettings(directory, "{}")
            let session = try await createSession(directory, noTools: noTools)
            try writeSettings(directory, #"{"defaultTools":["+grep"]}"#)
            await session.reload()
            await session.reloadExtensions()
            #expect(session.getActiveToolNames().isEmpty)
            session.dispose()
        }
        try writeSettings(directory, "{}")
        let allowlisted = try await createSession(directory, tools: ["read"])
        defer { allowlisted.dispose() }
        try writeSettings(directory, #"{"defaultTools":["+grep"]}"#)
        await allowlisted.reload()
        await allowlisted.reloadExtensions()
        #expect(allowlisted.getActiveToolNames() == ["read"])
        try writeSettings(directory, "{}")
        let excluded = try await createSession(directory, exclude: ["grep"])
        defer { excluded.dispose() }
        try writeSettings(directory, #"{"defaultTools":["+grep","+inactive_tool"]}"#)
        await excluded.reload()
        await excluded.reloadExtensions()
        #expect(excluded.getActiveToolNames().sorted() == ["bash", "edit", "inactive_tool", "read", "subagent", "write"])
    }
}
