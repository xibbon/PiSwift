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
        #expect(try codemodeSection(tools: [createReadTool()], namespaces: [], inlineBudget: 10_000) == expected)
    }

    @Test func malformedLocalReferenceRendersUnknown() {
        // v1.5.2 codemode/test/declarations.test.ts:246; codemode/src/declarations.ts:160-181.
        let schema = AnyCodable(["$defs": ["ok": ["type": "string"]], "$ref": "#/$defs/%E0"] as [String: Any])
        #expect(schemaToType(schema) == "unknown")
    }
    let github = CodemodeNamespace(name: "github", prefix: "mcp__github__", description: "GitHub MCP server")

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
        let text = try #require(try codemodeSection(tools: [e10Tool("read", description: "Read a file."), e10Tool("mcp__github__list_issues", description: "List issues.")], namespaces: [github], inlineBudget: 3000))
        #expect(text.contains("### `read`\nRead a file."))
        #expect(text.contains("read(args: {"))
        #expect(text.contains("## github\nGitHub MCP server"))
        #expect(try #require(text.range(of: "### `read`")) .lowerBound < #require(text.range(of: "## github")).lowerBound)
        #expect(try #require(text.range(of: "## github")).lowerBound < #require(text.range(of: "### `mcp__github__list_issues`")).lowerBound)
        #expect(text.contains("Promise<string>"))
    }
    @Test func budgetRoundsAndOmissions() throws {
        let tools = try (0..<30).map { try e10Tool("mcp__github__tool\($0)", description: String(repeating: "x", count: 200)) }
        let text = try #require(try codemodeSection(tools: [e10Tool("read", description: "Read a file.")] + tools, namespaces: [github], inlineBudget: 400))
        #expect(text.contains("### `read`"))
        #expect(text.contains("## github (some tools not listed)"))
        #expect(!text.contains("tool29"))
        #expect(try codemodeSection(tools: tools, namespaces: [github], inlineBudget: 10)?.contains("## github (tools not listed)") == true)
        #expect(try codemodeSection(tools: [], namespaces: [github], inlineBudget: 3000) == nil)
    }
    @Test func longestPrefix() throws {
        let text = try #require(try codemodeSection(tools: [e10Tool("mcp__github__x")], namespaces: [.init(name: "git", prefix: "mcp__git"), github], inlineBudget: 3000))
        #expect(text.contains("## github"))
        #expect(!text.contains("## git\n"))
    }
    @Test func callablePromptSectionAndGrammar() async throws {
        let setup = HarnessChatSetup()
        try setup.registry.install(createCodemodeExtension(options: .init(sandbox: DeterministicCodemodeSandbox(), namespaces: [github])))
        try setup.registry.install(Extension(name: "tools", tools: [e10Tool("read"), e10Tool("mcp__github__list_issues", callers: [.tools]), e10Tool("mcp__github__get_issue", deferred: true)]))
        setup.models.setResponses([.message(chatAssistant("hi"))])
        let opened = try await e10Open(setup: setup)
        try await e10Submit(opened)
        let system = try #require(await allEntries(opened.root).first { $0.kind == "pi.system" }?.model?.first)
        let section = try #require(system["sections"]?["codemode"]?.stringValue)
        #expect(section.contains("### `read`"))
        #expect(section.contains("### `mcp__github__list_issues`"))
        #expect(!section.contains("mcp__github__get_issue"))
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
