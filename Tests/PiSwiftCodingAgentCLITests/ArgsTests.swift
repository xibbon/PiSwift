import Testing
import PiSwiftCodingAgent
@testable import PiSwiftCodingAgentCLI

private func parseCLI(_ args: [String]) throws -> Args {
    let processed = PiCodingAgentCLI.preprocessArguments(args)
    let options = try CLIOptions.parse(processed)
    return options.toArgs()
}

@Test func parseArgsPrintFlag() throws {
    let result = try parseCLI(["--print"])
    #expect(result.print == true)

    let shortResult = try parseCLI(["-p"])
    #expect(shortResult.print == true)
}

@Test func parseArgsContinueFlag() throws {
    let result = try parseCLI(["--continue"])
    #expect(result.continue == true)

    let shortResult = try parseCLI(["-c"])
    #expect(shortResult.continue == true)
}

@Test func parseArgsResumeFlag() throws {
    let result = try parseCLI(["--resume"])
    #expect(result.resume == true)

    let shortResult = try parseCLI(["-r"])
    #expect(shortResult.resume == true)
}

@Test func parseArgsWithValues() throws {
    #expect(try parseCLI(["--provider", "openai"]).provider == "openai")
    #expect(try parseCLI(["--model", "gpt-4o"]).model == "gpt-4o")
    #expect(try parseCLI(["--api-key", "sk-test-key"]).apiKey == "sk-test-key")
    #expect(try parseCLI(["--system-prompt", "You are helpful"]).systemPrompt == "You are helpful")
    #expect(try parseCLI(["--append-system-prompt", "More"]).appendSystemPrompt == "More")
    #expect(try parseCLI(["--mode", "json"]).mode == .json)
    #expect(try parseCLI(["--mode", "rpc"]).mode == .rpc)
    #expect(try parseCLI(["--session", "/path/session.jsonl"]).session == "/path/session.jsonl")
    #expect(try parseCLI(["--session-id", "session-123"]).sessionId == "session-123")
    #expect(try parseCLI(["--export", "session.jsonl"]).export == "session.jsonl")
    #expect(try parseCLI(["--thinking", "high"]).thinking == .high)

    let models = try parseCLI(["--models", "gpt-4o,claude-sonnet,gemini-pro"]).models
    #expect(models == ["gpt-4o", "claude-sonnet", "gemini-pro"])
}

@Test func parseArgsListModels() throws {
    let all = try parseCLI(["--list-models"])
    #expect(all.listModels == .all)

    let search = try parseCLI(["--list-models", "haiku"])
    #expect(search.listModels == .search("haiku"))

    let equalsSearch = try parseCLI(["--list-models=sonnet"])
    #expect(equalsSearch.listModels == .search("sonnet"))
}

@Test func parseArgsNoSessionFlag() throws {
    #expect(try parseCLI(["--no-session"]).noSession == true)
}

@Test func parseArgsHookFlags() throws {
    let single = try parseCLI(["--hook", "./my-hook.ts"])
    #expect(single.hooks == ["./my-hook.ts"])

    let multiple = try parseCLI(["--hook", "./hook1.ts", "--hook", "./hook2.ts"])
    #expect(multiple.hooks == ["./hook1.ts", "./hook2.ts"])
}

@Test func parseArgsMessagesAndFiles() throws {
    let text = try parseCLI(["hello", "world"])
    #expect(text.messages == ["hello", "world"])

    let files = try parseCLI(["@README.md", "@src/main.ts"])
    #expect(files.fileArgs == ["README.md", "src/main.ts"])

    let mixed = try parseCLI(["@file.txt", "explain this", "@image.png"])
    #expect(mixed.fileArgs == ["file.txt", "image.png"])
    #expect(mixed.messages == ["explain this"])

    var didThrow = false
    do {
        _ = try CLIOptions.parse(["--unknown-flag", "message"])
    } catch {
        didThrow = true
    }
    #expect(didThrow)
}

@Test func parseArgsToolsAndSkills() throws {
    let tools = try parseCLI(["--tools", "read,grep"])
    #expect(tools.tools == [.read, .grep])

    let excluded = try parseCLI(["--exclude-tools", "bash,write,custom-tool"])
    #expect(excluded.excludeTools == ["bash", "write", "custom-tool"])

    let shortExcluded = try parseCLI(["-xt", "edit"])
    #expect(shortExcluded.excludeTools == ["edit"])

    let skills = try parseCLI(["--skills", "git-*,docker"])
    #expect(skills.skills == ["git-*", "docker"])

    let noPrompts = try parseCLI(["--no-prompt-templates"])
    #expect(noPrompts.noPromptTemplates == true)
}

@Test func parseShortAliasesForNoFlags() throws {
    let noExtensions = try parseCLI(["-ne"])
    #expect(noExtensions.noExtensions == true)

    let noSkills = try parseCLI(["-ns"])
    #expect(noSkills.noSkills == true)

    let noPrompts = try parseCLI(["-np"])
    #expect(noPrompts.noPromptTemplates == true)
}

@Test func parseArgsComplex() throws {
    let result = try parseCLI([
        "--provider", "anthropic",
        "--model", "claude-sonnet",
        "--print",
        "--thinking", "high",
        "@prompt.md",
        "Do the task",
    ])
    #expect(result.provider == "anthropic")
    #expect(result.model == "claude-sonnet")
    #expect(result.print == true)
    #expect(result.thinking == .high)
    #expect(result.fileArgs == ["prompt.md"])
    #expect(result.messages == ["Do the task"])
}
