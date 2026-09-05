import Foundation
import Testing
import PiSwiftAI
import PiSwiftAgent
@testable import PiSwiftCodingAgent

private struct V085Directory {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("pi-v085-utils-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func path(_ relative: String) -> String { url.appendingPathComponent(relative).path }

    @discardableResult
    func write(_ relative: String, _ content: String) throws -> String {
        let file = url.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(content.utf8).write(to: file)
        return file.path
    }

    func remove() { try? FileManager.default.removeItem(at: url) }
}

private func v085Text(_ result: AgentToolResult) -> String {
    result.content.compactMap { if case .text(let text) = $0 { text.text } else { nil } }.joined(separator: "\n")
}

@Suite("v0.85 tools and resources")
struct WorkOrderV085UtilsTests {
    @Test func singleEditObjectsAndEncodedObjects() async throws {
        let directory = try V085Directory()
        defer { directory.remove() }
        let tool = createEditTool(cwd: directory.url.path)
        for encoded in [false, true] {
            let path = try directory.write("edit.txt", "\u{FEFF}before\r\n")
            let object: [String: Any] = ["oldText": "before", "newText": "after"]
            let value: Any = encoded ? String(data: try JSONSerialization.data(withJSONObject: object), encoding: .utf8)! : object
            _ = try await tool.execute("edit", ["path": AnyCodable(path), "edits": AnyCodable(value)], nil, nil)
            #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == Data("\u{FEFF}after\r\n".utf8))
        }
        let malformed = ["path": AnyCodable("edit.txt"), "edits": AnyCodable(["oldText": 1, "newText": "after"])]
        await #expect(throws: (any Error).self) { try await tool.execute("bad", malformed, nil, nil) }
    }

    @Test func fileToolsUseExecutionCwdAndKeepFactoryFallback() async throws {
        let directory = try V085Directory()
        defer { directory.remove() }
        try directory.write("factory/sample.txt", "factory")
        try directory.write("execution/sample.txt", "execution marker")
        let cwd = directory.path("factory")
        let context = AgentToolExecutionContext(cwd: directory.path("execution"))
        let inputs: [(AgentTool, [String: AnyCodable], String)] = [
            (createReadTool(cwd: cwd), ["path": AnyCodable("sample.txt")], "execution marker"),
            (createGrepTool(cwd: cwd), ["pattern": AnyCodable("execution marker")], "execution marker"),
            (createFindTool(cwd: cwd), ["pattern": AnyCodable("*.txt")], "sample.txt"),
            (createLsTool(cwd: cwd), [:], "sample.txt"),
        ]
        for (tool, arguments, expected) in inputs {
            let execute = try #require(tool.executeWithContext)
            #expect(v085Text(try await execute("call", arguments, nil, nil, context)).contains(expected))
        }
        let read = createReadTool(cwd: cwd)
        #expect(v085Text(try await read.execute("call", ["path": AnyCodable("sample.txt")], nil, nil)) == "factory")
        let fallback = try #require(read.executeWithContext)
        #expect(v085Text(try await fallback("call", ["path": AnyCodable("sample.txt")], nil, nil, .init(cwd: ""))) == "factory")
        let write = try #require(createWriteTool(cwd: cwd).executeWithContext)
        let written = try await write("call", ["path": AnyCodable("new.txt"), "content": AnyCodable("before")], nil, nil, context)
        #expect(v085Text(written) == "Successfully wrote to new.txt")
        #expect(!FileManager.default.fileExists(atPath: directory.path("factory/new.txt")))
        let edit = try #require(createEditTool(cwd: cwd).executeWithContext)
        _ = try await edit("call", ["path": AnyCodable("new.txt"), "edits": AnyCodable(["oldText": "before", "newText": "after"])], nil, nil, context)
        #expect(try String(contentsOfFile: directory.path("execution/new.txt"), encoding: .utf8) == "after")
    }

    @Test func bashPassesExecutionCwdToOperations() async throws {
        struct Operations: BashOperations {
            func execute(_ command: String, options: BashExecutorOptions?) async throws -> BashResult {
                options?.onChunk?(options?.cwd ?? "missing")
                return BashResult(output: "", exitCode: 0, cancelled: false, truncated: false)
            }
        }
        let tool = createBashTool(cwd: "/factory", options: BashToolOptions(operations: Operations()))
        #expect(v085Text(try await tool.execute("call", ["command": AnyCodable("pwd")], nil, nil)) == "/factory")
        let execute = try #require(tool.executeWithContext)
        #expect(v085Text(try await execute("call", ["command": AnyCodable("pwd")], nil, nil, .init(cwd: "/execution"))) == "/execution")
    }

    @Test func experimentalSamplingRequiresExactFlag() {
        for value in ["", "0", "true"] {
            #expect(getExperimentalToolSampling(environment: ["PI_EXPERIMENTAL": value]) == nil)
        }
        guard case .jsonSchema(strict: .prefer) = getExperimentalToolSampling(environment: ["PI_EXPERIMENTAL": "1"]) else {
            Issue.record("PI_EXPERIMENTAL=1 must prefer strict JSON schema sampling")
            return
        }
        let tools = [createReadTool(cwd: "/"), createWriteTool(cwd: "/"), createEditTool(cwd: "/"), createBashTool(cwd: "/")]
        for tool in tools {
            if areExperimentalFeaturesEnabled() {
                guard case .jsonSchema(strict: .prefer) = tool.aiTool.constrainedSampling else {
                    Issue.record("Built-in tool sampling must reach the AI tool")
                    continue
                }
            } else {
                #expect(tool.aiTool.constrainedSampling == nil)
            }
        }
    }

    @Test func skillPromptsChooseReadThenBash() {
        let skill = Skill(name: "demo", description: "Demo", filePath: "/skills/demo/SKILL.md", baseDir: "/skills/demo", source: "test")
        for custom in [nil, "Custom prompt"] as [String?] {
            for tools: [ToolName] in [[.read, .bash], [.bash], [.write], []] {
                let prompt = buildSystemPrompt(BuildSystemPromptOptions(customPrompt: custom, selectedTools: tools, cwd: "/work", contextFiles: [], skills: [skill]))
                if tools.contains(.read) {
                    #expect(prompt.contains("Use the read tool to load a skill's file"))
                } else if tools.contains(.bash) {
                    #expect(prompt.contains("Use bash to load a skill's file"))
                } else {
                    #expect(!prompt.contains("<available_skills>"))
                }
                if custom != nil { #expect(prompt.hasSuffix("Current working directory: /work\n")) }
            }
        }
    }

    @Test func ordinaryMarkdownIsQuietAndDeclaredSkillsValidateTypes() throws {
        let directory = try V085Directory()
        defer { directory.remove() }
        for value in ["", "123", "false", "[one, two]", "{key: value}"] {
            let body = "---\nname: 123\ndescription: \(value)\n---\nBody"
            let ordinary = loadSkillFromFile(try directory.write("demo/notes.md", body), source: "test")
            #expect(ordinary.skill == nil)
            #expect(ordinary.warnings.isEmpty)
            let declared = loadSkillFromFile(try directory.write("demo/SKILL.md", body), source: "test")
            #expect(declared.skill == nil)
            #expect(declared.warnings.contains { $0.message == "description is required" })
        }
        let valid = loadSkillFromFile(try directory.write("demo/SKILL.md", "---\nname: 123\ndescription: '123'\n---\nBody"), source: "test")
        #expect(valid.skill?.name == "demo")
        #expect(valid.skill?.description == "123")
        for file in ["notes.md", "SKILL.md"] {
            let invalid = loadSkillFromFile(try directory.write("demo/\(file)", "---\ndescription: [unterminated\n---\nBody"), source: "test")
            #expect(invalid.skill == nil)
            #expect(invalid.warnings.isEmpty == (file != "SKILL.md"))
        }
    }

    @Test func bomIsRemovedOnceAndEditsPreserveIt() {
        #expect(splitBom("\u{FEFF}text").bom == "\u{FEFF}")
        let legacy = stripBom("\u{FEFF}text")
        #expect(legacy.text == "text")
        let text: String = stripBom("\u{FEFF}\u{FEFF}text")
        #expect(text == "\u{FEFF}text")
        let parsed = parseFrontmatter("\u{FEFF}---\r\nname: demo\r\ndescription: Demo\r\n---\r\nBody")
        #expect(parsed.frontmatter["name"] == "demo")
        #expect(parsed.body == "Body")
        #expect(parseFrontmatter("\u{FEFF}Body").body == "Body")
    }

    @Test func authCreationAndExistingModes() async throws {
        let directory = try V085Directory()
        defer { directory.remove() }
        let path = directory.path("auth.json")
        let backend = FileAuthStorageBackend(path)
        try backend.withLock { _ in AuthStorageLockResult(result: (), next: "{}") }
        func mode() throws -> Int { try #require(FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int) & 0o777 }
        #expect(try mode() == 0o600)
        try FileManager.default.setAttributes([.posixPermissions: 0o660], ofItemAtPath: path)
        try backend.withLock { _ in AuthStorageLockResult(result: (), next: "{\"sync\":true}") }
        #expect(try mode() == 0o660)
        try await backend.withLockAsync { _ in AuthStorageLockResult(result: (), next: "{\"async\":true}") }
        #expect(try mode() == 0o660)
    }

    @Test func jsonUpdatesCarryUsageAndToolStartMetadata() throws {
        let call = ToolCall(id: "call-1", name: "read", arguments: [:])
        let usage = Usage(input: 11, output: 3, cacheRead: 4, cacheWrite: 5, totalTokens: 23)
        let assistant = AssistantMessage(content: [.toolCall(call)], api: .openAICompletions, provider: "test", model: "test", usage: usage, stopReason: .toolUse)
        let events: [AssistantMessageEvent] = [
            .toolCallStart(contentIndex: 0, partial: assistant),
            .toolCallDelta(contentIndex: 0, delta: "{}", partial: assistant),
            .done(reason: .toolUse, message: assistant),
        ]
        for event in events {
            let encoded = encodeSessionEvent(.agent(.messageUpdate(message: .assistant(assistant), assistantMessageEvent: event)))
            let encodedUsage = try #require(encoded["usage"] as? [String: Any])
            #expect(encodedUsage["input"] as? Int == 11)
            #expect(encodedUsage["totalTokens"] as? Int == 23)
            #expect(encoded["message"] == nil)
            let delta = try #require(encoded["assistantMessageEvent"] as? [String: Any])
            #expect(delta["partial"] == nil)
            if case .toolCallStart = event {
                #expect(delta["type"] as? String == "toolcall_start")
                #expect(delta["id"] as? String == "call-1")
                #expect(delta["toolName"] as? String == "read")
            }
            #expect(JSONSerialization.isValidJSONObject(encoded))
        }
    }

    @Test func packageGlobsAreOrderedAndExactPathsCanReachHiddenAndLinkedFiles() async throws {
        let directory = try V085Directory()
        defer { directory.remove() }
        try directory.write("pkg/files/z.ts", "")
        try directory.write("pkg/files/a.ts", "")
        try directory.write("pkg/files/.ignored.ts", "")
        try directory.write("pkg/files/nested/.hidden.ts", "")
        try directory.write("pkg/groups/group/index.ts", "")
        try directory.write("pkg/plugins/local/skills/local-skill/SKILL.md", "---\ndescription: Local\n---")
        try directory.write("pkg/linked-source/skills/linked-skill/SKILL.md", "---\ndescription: Linked\n---")
        try FileManager.default.createSymbolicLink(atPath: directory.path("pkg/plugins/linked"), withDestinationPath: directory.path("pkg/linked-source"))
        try directory.write("pkg/package.json", #"{"pi":{"extensions":["./files/*.ts","./files/**/.ignored.ts","./files/nested/.hidden.ts","./groups/*/"],"skills":["./plugins/*/skills","./plugins/linked/skills"]}}"#)
        let manager = DefaultPackageManager(cwd: directory.url.path, agentDir: directory.path("agent"), settingsManager: .inMemory())
        let result = try await manager.resolveExtensionSources([directory.path("pkg")])
        #expect(result.extensions.map { URL(fileURLWithPath: $0.path).resolvingSymlinksInPath().path } == ["files/a.ts", "files/z.ts", "files/nested/.hidden.ts", "groups/group/index.ts"].map { directory.path("pkg/\($0)") })
        let discovered = expandPackageGlob("./plugins/*/skills", root: directory.path("pkg"))
        #expect(discovered.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path } == [directory.path("pkg/plugins/local/skills")])
        #expect(result.skills.contains { $0.path.hasSuffix("linked-skill/SKILL.md") })
        #expect(result.skills.contains { $0.path.hasSuffix("local-skill/SKILL.md") })
    }

    @Test func agentsSkillsDiscoverNestedMarkdownOnly() async throws {
        let directory = try V085Directory()
        defer { directory.remove() }
        try directory.write(".agents/skills/root.md", "---\ndescription: Root\n---")
        let nested = try directory.write(".agents/skills/ordinary/extra.md", "---\ndescription: Nested\n---")
        let declared = try directory.write(".agents/skills/declared/SKILL.md", "---\ndescription: Declared\n---")
        let support = try directory.write(".agents/skills/declared/support.md", "---\ndescription: Support\n---")
        let child = try directory.write(".agents/skills/declared/child/SKILL.md", "---\ndescription: Child\n---")
        let manager = DefaultPackageManager(cwd: directory.url.path, agentDir: directory.path("agent"), settingsManager: .inMemory())
        let result = try await manager.resolve()
        #expect(result.skills.contains { URL(fileURLWithPath: $0.path).resolvingSymlinksInPath().path == nested })
        #expect(result.skills.contains { URL(fileURLWithPath: $0.path).resolvingSymlinksInPath().path == declared })
        #expect(!result.skills.contains { URL(fileURLWithPath: $0.path).resolvingSymlinksInPath().path == directory.path(".agents/skills/root.md") })
        #expect(!result.skills.contains { URL(fileURLWithPath: $0.path).resolvingSymlinksInPath().path == support })
        #expect(!result.skills.contains { URL(fileURLWithPath: $0.path).resolvingSymlinksInPath().path == child })

        // The root Markdown exclusion does not exclude a declared root SKILL.md.
        let rootSkill = try directory.write(".agents/skills/SKILL.md", "---\ndescription: Root skill\n---")
        let rootResult = try await manager.resolve()
        let ownSkills = rootResult.skills.filter { $0.path.contains(directory.url.lastPathComponent) }
        #expect(ownSkills.map { URL(fileURLWithPath: $0.path).resolvingSymlinksInPath().path } == [rootSkill])
    }

    @Test func npmUpdateDoesNotDowngradeNewerInstalledVersion() async throws {
        let directory = try V085Directory()
        defer { directory.remove() }
        try directory.write(".pi/npm/node_modules/example/package.json", #"{"name":"example","version":"2.0.0","pi":{"extensions":["index.ts"]}}"#)
        try directory.write(".pi/npm/node_modules/example/index.ts", "")
        let settings = SettingsManager.inMemory()
        settings.setProjectPackages([.simple("npm:example")])
        let manager = DefaultPackageManager(cwd: directory.url.path, agentDir: directory.path("agent"), settingsManager: settings)
        let commands = LockedState<[[String]]>([])
        manager.setCommandRunnerForTests { command, arguments, _ in
            commands.withLock { $0.append([command] + arguments) }
            return ExecResult(stdout: "1.0.0\n", stderr: "", code: 0, killed: false)
        }
        try await manager.update("npm:example")
        let result = try await manager.resolve()
        #expect(result.extensions.contains { $0.path.hasSuffix("example/index.ts") })
        #expect(!commands.withLock { $0.contains { $0.contains("install") } })
    }

    @Test func semanticVersionPrecedence() {
        #expect(packageVersionIsNewer("1.0.0", than: "2.0.0") == false)
        #expect(packageVersionIsNewer("2.0.0", than: "1.0.0") == true)
        #expect(packageVersionIsNewer("1.0.0+build", than: "1.0.0+other") == false)
        #expect(packageVersionIsNewer("1.0.0", than: "1.0.0-rc.1") == true)
        #expect(packageVersionIsNewer("1.0.0-rc.10", than: "1.0.0-rc.2") == true)
        #expect(packageVersionIsNewer("1.0.0-alpha.1", than: "1.0.0-alpha") == true)
        #expect(packageVersionIsNewer("bad", than: "1.0.0") == nil)
    }

    @Test func installedToolLookupReportsStatusOnlyThroughCallback() async {
        let statuses = LockedState<[ToolStatus]>([])
        let path = await ensureTool("pi-nonexistent-\(UUID().uuidString)", onStatus: { status in statuses.withLock { $0.append(status) } })
        #expect(path == nil)
        #expect(statuses.withLock { $0.count } == 1)
        #expect(statuses.withLock { $0.first?.type } == .warning)
    }
}
