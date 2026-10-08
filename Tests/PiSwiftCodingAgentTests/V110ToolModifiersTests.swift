import Foundation
import Testing
import PiSwiftAI
import PiSwiftAgent
@testable import PiSwiftCodingAgent

// v1.1.0 settings-manager.ts:218-267 and default-tools-setting.test.ts:159-201,258-267.
@Suite("v1.1.0 tool modifiers")
struct V110ToolModifiersTests {
    @Test func validatesToolListsWithUpstreamTexts() {
        #expect(isToolModifier("+grep"))
        #expect(isToolModifier("-"))
        #expect(!isToolModifier("grep"))
        for entries in [[], ["read", "gr*"], ["+grep", "-write"], ["+", "-"]] {
            #expect(getToolListError(entries) == nil)
        }
        #expect(getToolListError(["read", "+grep"]) == "tool names cannot be mixed with +name or -name entries")
        #expect(getToolListError(["-gr*"]) == "+name and -name entries take exact tool names, not patterns: -gr*")
        #expect(getToolListError(["+*", "read"]) == "tool names cannot be mixed with +name or -name entries")
    }

    @Test func modifiersRemoveOnlyTheFirstMatch() {
        #expect(applyToolModifiers(base: ["read", "read", "bash"], entries: ["-read"]) == ["read", "bash"])
        #expect(applyToolModifiers(base: ["read"], entries: ["write", "+grep", "+grep", "-read", "+read", "+", "-"]) == ["grep", "read"])
        var settings = Settings()
        settings.defaultTools = ["read", "read", "-read"]
        #expect(SettingsManager.inMemory(settings).getDefaultTools() == ["read"])
    }

    @Test func selectionReturnsTheHostConfigAndAppliesExclusionsLast() {
        let tools = [InitialToolRegistration(name: "read", isBuiltin: true),
                     InitialToolRegistration(name: "grep", isBuiltin: true),
                     InitialToolRegistration(name: "inactive", defaultActive: false),
                     InitialToolRegistration(name: "active"),
                     InitialToolRegistration(name: "indirect", exposure: .deferred, defaultActive: false)]
        let selection = selectInitialTools(registeredTools: tools, toolNames: ["+inactive", "+indirect", "-read"],
                                           excludeTools: ["inact*"], defaultToolNames: ["read", "grep"])
        #expect(selection.activeToolNames == ["grep", "indirect", "active"])
        #expect(!selection.registeredToolNames.contains("inactive"))
        #expect(selection.allowedToolNames == nil)
        #expect(selection.usesDefaultTools)
        #expect(selection.defaultToolModifiers == ["+inactive", "+indirect", "-read"])
        let all = selectInitialTools(registeredTools: tools, toolNames: ["+inactive"], noTools: .all,
                                     defaultToolNames: ["read"])
        #expect(all.activeToolNames == ["inactive"])
        #expect(all.allowedToolNames == ["inactive"])
        // Upstream sdk.ts:472 also checks !noTools for a modifier list.
        #expect(!all.usesDefaultTools)
        let builtin = selectInitialTools(registeredTools: tools, toolNames: ["+grep"], noTools: .builtin,
                                         defaultToolNames: ["read"])
        #expect(builtin.activeToolNames == ["grep", "active"])
        #expect(builtin.allowedToolNames == nil)
        #expect(!builtin.usesDefaultTools)
    }

    private func makeSession(_ directory: URL, settings: SettingsManager, names: [String],
                             noTools: NoToolsMode? = nil, exclude: [String]? = nil) async throws -> AgentSession {
        let model = getModel(provider: .openai, modelId: "gpt-4o-mini")
        let auth = AuthStorage.inMemory([model.provider: .apiKey(ApiKeyCredential(key: "test"))])
        let inline = InlineExtension(name: "modifier-test") { api in
            for (name, active) in [("inactive_tool", false), ("active_tool", true)] {
                _ = api.registerTool(CustomTool(name: name, label: name, description: name, parameters: [:],
                    execute: { _, _, _, _, _ in AgentToolResult(content: []) }, defaultActive: active))
            }
        }
        let custom = CustomTool(name: "sdk_tool", label: "SDK", description: "SDK", parameters: [:],
                                execute: { _, _, _, _, _ in AgentToolResult(content: []) })
        return try await createAgentSession(CreateAgentSessionOptions(cwd: directory.path, agentDir: directory.path,
            authStorage: auth, model: model, offline: true, toolNames: names, excludeTools: exclude, noTools: noTools,
            customTools: [CustomToolDefinition(tool: custom)], resourceLoader: TestResourceLoader(), hooks: [],
            inlineExtensions: [inline], sessionManager: .inMemory(directory.path), settingsManager: settings)).session
    }

    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("v110-tools-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func sdkModifiersUseResolvedDefaultsAndKeepCustomTools() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var config = Settings()
        config.defaultTools = ["+grep"]
        let session = try await makeSession(directory, settings: .inMemory(config), names: ["+inactive_tool", "-write"])
        defer { session.dispose() }
        #expect(session.getActiveToolNames().sorted() == ["active_tool", "bash", "edit", "grep", "inactive_tool", "read", "sdk_tool"])
        let excluded = try await makeSession(directory, settings: .inMemory(config), names: ["+inactive_tool", "-write"], exclude: ["grep", "inactive_*"])
        defer { excluded.dispose() }
        #expect(excluded.getActiveToolNames().sorted() == ["active_tool", "bash", "edit", "read", "sdk_tool"])
    }

    @Test func sdkModifiersCanSelectToolsWithNoToolsModes() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var config = Settings()
        config.defaultTools = ["read"]
        let all = try await makeSession(directory, settings: .inMemory(config), names: ["+inactive_tool"], noTools: .all)
        defer { all.dispose() }
        #expect(all.getActiveToolNames() == ["inactive_tool"])
        #expect(all.getAllToolNames() == ["inactive_tool"])
        let custom = try await makeSession(directory, settings: .inMemory(config), names: ["+sdk_tool"], noTools: .all)
        defer { custom.dispose() }
        #expect(custom.getActiveToolNames() == ["sdk_tool"])
        let builtin = try await makeSession(directory, settings: .inMemory(config), names: ["+grep"], noTools: .builtin)
        defer { builtin.dispose() }
        #expect(builtin.getActiveToolNames().sorted() == ["active_tool", "grep", "sdk_tool"])
    }

    @Test func sdkRejectsInvalidListsWithTypedErrors() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        for (names, problem) in [(["read", "+grep"], "tool names cannot be mixed with +name or -name entries"),
                                 (["-gr*"], "+name and -name entries take exact tool names, not patterns: -gr*")] {
            do {
                let session = try await makeSession(directory, settings: .inMemory(), names: names)
                session.dispose()
                Issue.record("An invalid tool list did not throw")
            } catch let error as ToolSelectionError {
                #expect(error == .invalidToolsOption(problem))
                #expect(error.localizedDescription == "Invalid tools option: \(problem)")
            }
        }
    }

    @Test func removedToolsStayRemovedAfterReload() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("settings.json")
        try #"{"defaultTools":["read"]}"#.write(to: path, atomically: true, encoding: .utf8)
        let session = try await makeSession(directory, settings: .create(directory.path, directory.path), names: ["-bash", "+grep"])
        defer { session.dispose() }
        #expect(session.getActiveToolNames().sorted() == ["active_tool", "grep", "read", "sdk_tool"])
        try #"{"defaultTools":["read","bash","inactive_tool"]}"#.write(to: path, atomically: true, encoding: .utf8)
        await session.reload()
        await session.reloadExtensions()
        #expect(session.getActiveToolNames().sorted() == ["active_tool", "grep", "inactive_tool", "read", "sdk_tool"])
    }
}
