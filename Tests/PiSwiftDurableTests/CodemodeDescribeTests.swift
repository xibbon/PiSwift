import Foundation
import PiSwiftAI
import PiSwiftChord
import PiSwiftDurable
import PiSwiftDurableTesting
import Testing

@Suite(.timeLimit(.minutes(1)))
struct CodemodeDescribeTests {
    @Test func readDeclarationMatchesTaggedText() throws {
        // v1.5.2 durable/src/tools/read.ts:34-56; durable/src/codemode/describe.ts:43-108.
        let expected = """
        Tools scripts can call (`await tools.<name>(args)`):

        ### `read`
        Read the contents of a file. Supports text files and images (jpg, png, gif, webp). Images are sent as attachments. For text files, output is truncated to 2000 lines or 50KB (whichever is hit first). Use offset/limit for large files. When you need the full file, continue with offset until complete.

        codemode tool declaration:
        ```ts
        declare const tools: { read(args: {
          // Maximum number of lines to read
          limit?: number;
          // Line number to start reading from (1-indexed)
          offset?: number;
          // Path to the file to read (relative or absolute)
          path: string;
        }): Promise<string | { data: string; mimeType: string; type: "image"; }>; };
        ```
        """
        #expect(try codemodeSection(tools: [createReadTool()], extensions: [], inlineBudget: 10_000) == expected)
    }

    @Test func malformedLocalReferenceRendersUnknown() {
        // v1.5.2 codemode/test/declarations.test.ts:246; codemode/src/declarations.ts:160-181.
        let schema = AnyCodable(["$defs": ["ok": ["type": "string"]], "$ref": "#/$defs/%E0"] as [String: Any])
        #expect(schemaToType(schema) == "unknown")
    }
    let github = ToolNamespace(name: "mcp__github", description: "GitHub MCP server", instructions: "Pass repositories as owner/name.")

    @Test func fixedDescription() {
        let text = codemodeDescription(models: false)
        #expect(text.contains("`await tools.<name>({ ...args })`"))
        #expect(text.contains("searchTools(query"))
        #expect(text.contains("The `codemode` section of the system prompt lists the tools scripts can call"))
        #expect(!text.contains("`models`"))
        #expect(codemodeDescription(models: true).contains("`models`"))
        #expect(!text.contains("QuickJS"))
    }
    @Test func namespaceDeclarations() throws {
        let read = try e10Tool("read", description: "Read a file.")
        let issues = try e10Tool("list_issues", description: "List issues.")
        let extensions = [Extension(name: "coding", tools: [read]), Extension(name: "github", namespace: github, tools: [issues])]
        let text = try #require(try codemodeSection(tools: [read, issues], extensions: extensions, inlineBudget: 3000))
        #expect(text.contains("### `read`\nRead a file."))
        #expect(text.contains("read(args: {"))
        #expect(text.contains("## mcp__github\nGitHub MCP server"))
        #expect(!text.contains("owner/name"))
        #expect(try #require(text.range(of: "### `read`")) .lowerBound < #require(text.range(of: "## mcp__github")).lowerBound)
        #expect(try #require(text.range(of: "## mcp__github")).lowerBound < #require(text.range(of: "### `list_issues`")) .lowerBound)
        #expect(text.contains("Promise<string>"))
    }
    @Test func namespaceWithoutToolsAndStableDeferredSection() throws {
        let read = try e10Tool("read")
        let before = try codemodeSection(tools: [read], extensions: [Extension(name: "coding", tools: [read]), Extension(name: "github", namespace: github)], inlineBudget: 3000)
        let deferred = try e10Tool("list_issues", deferred: true)
        let after = try codemodeSection(tools: [read], extensions: [Extension(name: "coding", tools: [read]), Extension(name: "github", namespace: github, tools: [deferred])], inlineBudget: 3000)
        #expect(before == after)
        #expect(before?.contains("## mcp__github\nGitHub MCP server") == true)
        #expect(try codemodeSection(tools: [], extensions: [Extension(name: "github", namespace: github)], inlineBudget: 3000)?.contains("## mcp__github") == true)
        #expect(try codemodeSection(tools: [], extensions: [], inlineBudget: 3000) == nil)
    }
    @Test func budgetRoundsAndOmissions() throws {
        let tools = try (0..<30).map { try e10Tool("tool\($0)", description: String(repeating: "x", count: 200)) }
        let read = try e10Tool("read", description: "Read a file.")
        let text = try #require(try codemodeSection(tools: [read] + tools, extensions: [Extension(name: "coding", tools: [read]), Extension(name: "github", namespace: github, tools: tools)], inlineBudget: 400))
        #expect(text.contains("### `read`"))
        #expect(text.contains("Some tools are not listed: find them with `searchTools()`."))
        #expect(text.contains("## mcp__github\nGitHub MCP server"))
        #expect(!text.contains("tool29"))
        #expect(!text.contains("not listed)"))
    }
    @Test func firstExtensionNamingAToolWins() throws {
        let shared = try e10Tool("read")
        let issues = try e10Tool("list_issues")
        let first = namespacesOf([Extension(name: "coding", tools: [shared]), Extension(name: "github", namespace: github, tools: [issues, shared])])
        #expect(first["read"] == nil)
        #expect(first["list_issues"] == github)
        let second = namespacesOf([Extension(name: "github", namespace: github, tools: [issues, shared]), Extension(name: "coding", tools: [shared])])
        #expect(second["read"] == github)
    }
    @Test func callablePromptSectionAndGrammar() async throws {
        let setup = HarnessChatSetup()
        try setup.registry.install(createCodemodeExtension(options: .init(sandbox: DeterministicCodemodeSandbox())))
        try setup.registry.install(Extension(name: "tools", tools: [e10Tool("read")]))
        try setup.registry.install(Extension(name: "github", namespace: github, tools: [e10Tool("list_issues", callers: [.tools]), e10Tool("get_issue", deferred: true)]))
        setup.models.setResponses([.message(chatAssistant("hi"))])
        let opened = try await e10Open(setup: setup)
        try await e10Submit(opened)
        let system = try #require(await allEntries(opened.root).first { $0.kind == "pi.system" }?.model?.first)
        let section = try #require(system["sections"]?["codemode"]?.stringValue)
        #expect(section.contains("### `read`"))
        #expect(section.contains("### `list_issues`"))
        #expect(!section.contains("get_issue"))
        #expect(!section.contains("### `codemode`"))
        let tool = try #require(system["toolsAdded"]?.arrayValue?.first { $0["name"] == "codemode" })
        #expect(tool["constrainedSampling"]?["type"] == "grammar")
        #expect(tool["constrainedSampling"]?["variants"]?["openai_lark"]?.stringValue?.contains("start:") == true)
        let registered = try #require(setup.registry.snapshot().tools().first { $0.tool.name == "codemode" }?.tool)
        #expect(registered.callers == [.model])
        #expect(registered.replay == .safe)
        #expect(setup.registry.snapshot().tools().filter { $0.tool.name.hasPrefix("pi.codemode.models.") }.allSatisfy { $0.tool.callers == [.tools] })
        try await opened.harness.close(context: .background)
    }
}
