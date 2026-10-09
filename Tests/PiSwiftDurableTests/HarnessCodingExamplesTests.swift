import Foundation
import Synchronization
import Testing
import PiSwiftAI
import PiSwiftChord
import PiSwiftDurableTesting
@testable import PiSwiftDurable

private struct CodingExamplePlan: Codable, Sendable { var steps: [String] = [] }
private struct CodingExampleSandbox: Codable, Sendable { var path: String? }

private func codingSubmit(_ conversation: Conversation, text: String = "go") async throws -> SettledSubmission {
    try await conversation.submit(.input(content: .text(text)), context: .background).wait(context: .background)
}
private func codingSystemText(_ messages: [Message]) -> String {
    messages.compactMap { message in
        guard case .system(let value) = message else { return nil }
        return value.sections?.entries.compactMap(\.value).joined(separator: "\n")
    }.joined(separator: "\n")
}

@Suite struct HarnessCodingExamplesTests {
    // test/examples/15-system-prompt.ts. The local env supplies each section's cwd.
    @Test func systemPromptFollowsConversationDirectory() async throws {
        let setup = HarnessChatSetup()
        let coding = Extension(name: "coding", sections: [
            section("preamble", tag: false) { _, _ in "You are a coding agent." },
            section("cwd") { input, _ in input.env?.cwd }])
        let agents = Extension(name: "agents-md", sections: [section("agents_md") { _, _ in "Run npm run check after changes." }])
        try setup.registry.install(coding)
        try setup.registry.install(agents)
        try setup.registry.install(Extension(name: "terse", wraps: [wrapSection("preamble") { original in
            var wrapped = original
            wrapped.render = { input, context in (try await original.render(input, context) ?? "") + " Be terse." }
            return wrapped
        }]))
        setup.models.setResponses((0..<3).map { _ in .message(chatAssistant("Done.")) })
        let chat = try await codingChat(setup: setup, directory: "/repo")
        let child = try await chat.harness.createConversation(options: .init(ownership: .ownerless(),
            agent: .init(model: .set(.init(provider: "faux", modelId: "faux-1")),
                extensions: .set(.edit(remove: [agents])), instructions: .set("Only read; never edit files."), cwd: .set("/repo"))), context: .background)
        #expect(try await codingSubmit(chat.root).status == "done")
        #expect(try await codingSubmit(child).status == "done")
        let rootContext = try await chat.root.context(context: .background)
        let childContext = try await child.context(context: .background)
        #expect(codingSystemText(rootContext.messages).contains("You are a coding agent. Be terse."))
        #expect(codingSystemText(rootContext.messages).contains("/repo"))
        #expect(codingSystemText(childContext.messages).contains("Only read; never edit files."))
        #expect(!codingSystemText(childContext.messages).contains("Run npm run check"))
        try await chat.root.configure(change: .init(cwd: .set("/repo/packages")), context: .background)
        #expect(try await codingSubmit(chat.root).status == "done")
        let systemEntries = try await allEntries(chat.root).filter { $0.kind == "pi.system" }
        #expect(systemEntries.count == 2)
        let last = try #require(try systemEntries.last?.messages()?.first)
        guard case .system(let system) = last else { Issue.record("Expected a system message"); return }
        #expect(system.sections == SystemPromptSections([("cwd", "<cwd>\n/repo/packages\n</cwd>")]))
        try await chat.harness.close(context: .background)
    }

    // test/examples/27-plan-mode.ts. The plan and tool offer survive mode changes.
    @Test func planModeReadsAndStoresPlanThenRestoresTools() async throws {
        let directory = try toolTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("app.listen(3000);\n".utf8).write(to: directory.appendingPathComponent("server.ts"))
        let token = try RewindableConversationDocToken<CodingExamplePlan>(kind: "app.plan", version: 1, fork: .asOf, initial: { .init() })
        let submit = try ToolRegistration(name: "submit_plan", description: "Submit the plan as a list of steps.",
            parameters: ["type": "object", "properties": ["steps": ["type": "array", "items": ["type": "string"]]], "required": ["steps"]]) { args, api, context in
                let steps = (args["steps"]?.arrayValue ?? []).compactMap(\.stringValue)
                try await api.commit({ tx in
                    let draft = try await tx.doc(token, conversationId: api.conversationId)
                    try draft.set("steps", .array(steps.map(JSONValue.string)))
                }, context: context)
                return .init(content: [.text(.init(text: "Plan submitted."))], control: .init(terminate: true))
            }
        let plan = Extension(name: "plan", tools: [submit], sections: [section("plan_mode") { _, _ in "You are in plan mode. Read the code, then call submit_plan. Change nothing." }])
        let coding = try CodingTools
        let setup = HarnessChatSetup(settings: .init(extensions: [coding]))
        try setup.registry.install(coding); try setup.registry.install(plan)
        setup.models.setResponses([
            .message(try toolCalls([("read", ["path": "server.ts"], "r")])),
            .message(try toolCalls([("submit_plan", ["steps": ["Read PORT from the environment", "Default to 3000"]], "p")])),
            .message(chatAssistant("Implementing step 1."))])
        let chat = try await codingChat(setup: setup, directory: directory.path)
        #expect(try await chat.root.agent(context: .background).tools.map(\.name) == ["read", "write", "edit", "bash"])
        try await chat.root.configure(change: .init(extensions: .set(.edit(add: [plan])), tools: .set(.exact([createReadTool(), submit]))), context: .background)
        #expect(try await chat.root.agent(context: .background).tools.map(\.name) == ["read", "submit_plan"])
        #expect(try await codingSubmit(chat.root, text: "Make the port configurable.").status == "done")
        #expect(try await chat.harness.snapshot(token, conversationId: chat.root.id, context: .background)?.steps == ["Read PORT from the environment", "Default to 3000"])
        #expect(try String(contentsOf: directory.appendingPathComponent("server.ts"), encoding: .utf8) == "app.listen(3000);\n")
        try await chat.root.configure(change: .init(extensions: .clear, tools: .clear), context: .background)
        #expect(try await chat.root.agent(context: .background).tools.map(\.name) == ["read", "write", "edit", "bash"])
        #expect(try await codingSubmit(chat.root, text: "Go ahead.").status == "done")
        let systems = try await allEntries(chat.root).filter { $0.kind == "pi.system" }
        #expect(systems.count == 2)
        try await chat.harness.close(context: .background)
    }

    // test/examples/28-reviewer.ts. A separate directory and read-only offer.
    @Test func reviewerReadsOwnDirectoryAndContinuesUntilDone() async throws {
        let directory = try toolTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("export const name = (user) => user.name;\n".utf8).write(to: directory.appendingPathComponent("user.ts"))
        let coding = try CodingTools
        let reviewer = Extension(name: "reviewer", sections: [section("role") { _, _ in "You review diffs. Report problems as a list. Never edit files." }],
            hooks: [hook(GenerationHooks(onYield: { answer, _, _ in
                let text = answer.content.compactMap { if case .text(let value) = $0 { value.text } else { nil } }.joined()
                return text.contains("No further findings.") ? nil : .init(continue: .text("Look again for anything you missed. Say \"No further findings.\" when there is nothing left."))
            }))])
        let setup = HarnessChatSetup(settings: .init(extensions: [coding]))
        try setup.registry.install(coding); try setup.registry.install(reviewer)
        setup.models.setResponses([
            .message(try toolCalls([("read", ["path": "user.ts"], "r")])),
            .message(chatAssistant("1. `name` does not handle a missing user.")),
            .message(chatAssistant("2. `user` has no type. No further findings."))])
        let chat = try await codingChat(setup: setup, directory: directory.path)
        let child = try await chat.harness.createConversation(options: .init(ownership: .ownerless(),
            agent: .init(model: .set(.init(provider: "faux", modelId: "faux-1")), extensions: .set(.exact([coding, reviewer])),
                tools: .set(.exact([createReadTool()])), cwd: .set(directory.path))), context: .background)
        let agent = try await child.agent(context: .background)
        #expect(agent.extensions.map(\.name) == ["coding-tools", "reviewer"])
        #expect(agent.tools.map(\.name) == ["read"])
        #expect(agent.cwd == directory.path)
        #expect(try await codingSubmit(child, text: "Review user.ts.").status == "done")
        let entries = try await allEntries(child)
        #expect(try harnessToolResults(entries).map(harnessToolText) == ["export const name = (user) => user.name;\n"])
        #expect(entries.filter { $0.kind == "pi.user" }.count == 2)
        let answers = try entries.filter { $0.kind == "pi.assistant" }.flatMap { try $0.messages() ?? [] }.compactMap(textOf).filter { !$0.isEmpty }
        #expect(answers == ["1. `name` does not handle a missing user.", "2. `user` has no type. No further findings."])
        try await chat.harness.close(context: .background)
    }

    // test/examples/29-sandbox-per-conversation.ts. The document chooses the env.
    @Test func sandboxPerConversationKeepsFilesSeparate() async throws {
        let aliceDirectory = try toolTestDirectory(), bobDirectory = try toolTestDirectory()
        defer { try? FileManager.default.removeItem(at: aliceDirectory); try? FileManager.default.removeItem(at: bobDirectory) }
        let token = try ConversationDocToken<CodingExampleSandbox>(kind: "app.sandbox", version: 1, fork: .initial, initial: { .init() })
        let setup = HarnessChatSetup()
        try setup.registry.install(try CodingTools)
        setup.models.setResponses([
            .message(try toolCalls([("write", ["path": "note.txt", "content": "from alice"], "a")])), .message(chatAssistant("Saved.")),
            .message(try toolCalls([("write", ["path": "note.txt", "content": "from bob"], "b")])), .message(chatAssistant("Saved."))])
        let harness = try await Harness.open(storage: MemoryStorage(), options: .init(models: setup.models, registry: setup.registry,
            env: { target, context in
                guard let path = try await target.read.snapshot(token, conversationId: target.conversationId, context: context)?.path else { return nil }
                return LocalExecutionEnv(cwd: path)
            }), context: .background)
        func conversation(_ directory: URL) async throws -> Conversation {
            try await harness.createConversation(options: .init(ownership: .ownerless(),
                agent: .init(model: .set(.init(provider: "faux", modelId: "faux-1"))), initialize: { tx, id in
                    let draft = try await tx.doc(token, conversationId: id)
                    try draft.set("path", .string(directory.path))
                }), context: .background)
        }
        let alice = try await conversation(aliceDirectory), bob = try await conversation(bobDirectory)
        #expect(try await codingSubmit(alice).status == "done")
        #expect(try await codingSubmit(bob).status == "done")
        #expect(try String(contentsOf: aliceDirectory.appendingPathComponent("note.txt"), encoding: .utf8) == "from alice")
        #expect(try String(contentsOf: bobDirectory.appendingPathComponent("note.txt"), encoding: .utf8) == "from bob")
        try await harness.close(context: .background)
    }

    #if os(macOS)
    // test/examples/26-coding-agent.ts. Cwd and settings apply at the next use.
    @Test func codingAgentUsesChangedCwdAndLiveSettings() async throws {
        let directory = try toolTestDirectory(), app = directory.appendingPathComponent("app")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        let setup = HarnessChatSetup(settings: .init(toolExecution: .parallel))
        try setup.registry.install(try CodingTools)
        try setup.registry.install(Extension(name: "coding", sections: [section("preamble", tag: false) { _, _ in "You are a coding agent. Use the tools to inspect the project." }, section("cwd") { input, _ in input.env?.cwd }]))
        setup.models.setResponses([
            .message(try toolCalls([("bash", ["command": "pwd"], "p1")])), .message(chatAssistant("Done.")),
            .message(try toolCalls([("bash", ["command": "pwd"], "p2")])), .message(chatAssistant("Done."))])
        let chat = try await codingChat(setup: setup, directory: directory.path)
        #expect(try await codingSubmit(chat.root).status == "done")
        try await chat.root.configure(change: .init(cwd: .set(app.path)), context: .background)
        setup.updateSettings { $0.toolExecution = .sequential }
        #expect(try await codingSubmit(chat.root).status == "done")
        let results = try harnessToolResults(try await allEntries(chat.root))
        let canonical = try await LocalExecutionEnv().canonicalPath(directory.path, context: .background).get()
        #expect(results.map(harnessToolText) == [canonical + "\n", canonical + "/app\n"])
        #expect(setup.settings.toolExecution == .sequential)
        try await chat.harness.close(context: .background)
    }

    // test/examples/30-tool-override.ts. The wrapper sees whichever bash wins.
    @Test func toolOverrideUsesVenvAndWrapper() async throws {
        let directory = try toolTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let env = LocalExecutionEnv(cwd: directory.path)
        try await env.writeFile(".venv/bin/activate", content: .text("export VIRTUAL_ENV='\(directory.path)/.venv'\n"), context: .background).get()
        let coding = try CodingTools, calls = Mutex(0)
        let timing = Extension(name: "timing", wraps: [wrapTool(try createBashTool()) { original in
            var wrapped = original
            wrapped.execute = { args, api, context in
                defer { calls.withLock { $0 += 1 } }
                return try await original.execute(args, api, context)
            }
            return wrapped
        }])
        let venv = Extension(name: "venv", tools: [try createBashTool(options: .init(commandPrefix: "source .venv/bin/activate"))])
        let setup = HarnessChatSetup(settings: .init(extensions: [coding, timing]))
        try setup.registry.install(coding); try setup.registry.install(timing); try setup.registry.install(venv)
        setup.models.setResponses([
            .message(try toolCalls([("bash", ["command": "echo venv: $VIRTUAL_ENV"], "p")])), .message(chatAssistant("Done.")),
            .message(try toolCalls([("bash", ["command": "echo venv: $VIRTUAL_ENV"], "v")])), .message(chatAssistant("Done."))])
        let chat = try await codingChat(setup: setup, directory: directory.path)
        let python = try await chat.harness.createConversation(options: .init(ownership: .ownerless(),
            agent: .init(model: .set(.init(provider: "faux", modelId: "faux-1")), extensions: .set(.edit(add: [venv])), cwd: .set(directory.path))), context: .background)
        #expect(try await codingSubmit(chat.root).status == "done")
        #expect(try await codingSubmit(python).status == "done")
        #expect(try harnessToolResults(try await allEntries(chat.root)).map(harnessToolText) == ["venv:\n"])
        #expect(try harnessToolResults(try await allEntries(python)).map(harnessToolText) == ["venv: \(directory.path)/.venv\n"])
        #expect(calls.withLock { $0 } == 2)
        try await chat.harness.close(context: .background)
    }

    // test/examples/17-coding-tools.ts. Deterministic large output replaces /tmp/1gb.txt.
    @Test func codingToolsUseJsonlStorageAndTimingHook() async throws {
        let directory = try toolTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("hello world\n".utf8).write(to: directory.appendingPathComponent("notes.txt"))
        try Data(String(repeating: "large output\n", count: 3000).utf8).write(to: directory.appendingPathComponent("large.txt"))
        let setup = HarnessChatSetup(), hooks = Mutex<[String]>([])
        try setup.registry.install(try CodingTools)
        try setup.registry.install(Extension(name: "timing", hooks: [hook(ToolHooks(beforeTool: { call, _, _ in
            if call.id == "c" { hooks.withLock { $0.append("before") } }; return nil
        }, afterTool: { call, _, _, _ in
            if call.id == "c" { hooks.withLock { $0.append("after") } }; return nil
        }))]))
        setup.models.setResponses([
            .message(try toolCalls([("read", ["path": "notes.txt"], "r")])),
            .message(try toolCalls([("edit", ["path": "notes.txt", "edits": [["oldText": "world", "newText": "durable"]]], "e")])),
            .message(try toolCalls([("bash", ["command": "cat notes.txt"], "b")])),
            .message(try toolCalls([("bash", ["command": "cat large.txt"], "c")])),
            .message(chatAssistant("The file now greets durable."))])
        let storage = try await JsonlStorage.open(directory: directory.appendingPathComponent("storage").path)
        let chat = try await codingChat(storage: storage, setup: setup, directory: directory.path)
        #expect(try await codingSubmit(chat.root, text: "Greet durable instead.").status == "done")
        let entries = try await allEntries(chat.root)
        let results = try harnessToolResults(entries)
        #expect(results.map(\.toolName) == ["read", "edit", "bash", "bash"])
        #expect(results.allSatisfy { !$0.isError })
        #expect(hooks.withLock { $0 } == ["before", "after"])
        #expect(results.last.map(harnessToolText)?.contains("[info] Full output: ") == true)
        #expect(try String(contentsOf: directory.appendingPathComponent("notes.txt"), encoding: .utf8) == "hello durable\n")
        for entry in entries where entry.kind == "pi.tool-result" {
            for diagnostic in (try entry.data?.decode(ToolResultEntryData.self).diagnostics ?? []) where diagnostic.code == "full_output" {
                let path = diagnostic.message.replacingOccurrences(of: "Full output: ", with: "")
                try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent)
            }
        }
        try await chat.harness.close(context: .background)
    }
    #endif
}
