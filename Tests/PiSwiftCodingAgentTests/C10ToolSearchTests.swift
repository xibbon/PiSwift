import Foundation
import Testing
import PiSwiftAI
import PiSwiftAgent
@testable import PiSwiftCodingAgent

private func c10Tool(_ name: String, _ description: String,
                     parameters: [String: Any] = ["type": "object"],
                     namespace: ToolNamespace? = nil) -> ToolInfo {
    ToolInfo(name: name, description: description,
             parameters: parameters.mapValues(AnyCodable.init), exposure: .deferred,
             namespace: namespace)
}

@Test("segments Unicode words in %s") func c10UnicodeTokenization() {
    let examples: [(String, [String])] = [
        ("搜索仓库问题", ["搜索", "仓库", "问题"]),
        ("文書を検索", ["文書", "を", "検索"]),
        ("문서 검색", ["문서", "검색"]),
        ("ค้นหาเอกสาร", ["ค้นหา", "เอกสาร"]),
        ("Поиск документов", ["поиск", "документов"]),
        ("البحث عن الملفات", ["البحث", "عن", "الملفات"]),
        ("फ़ाइल खोजें", ["फ़ाइल", "खोजें"]),
        ("Éléments cafés", ["éléments", "cafés"]),
        ("搜索GitHub_repoIssues résumé cafés", ["搜索", "git", "hub", "repo", "issue", "résumé", "cafés"]),
        ("工具Screenshot9", ["工具", "screenshot9"]),
        ("CAFÉ cafe\u{0301}", ["café", "café"]),
        (" \t，。!? 😀 ", []),
    ]
    for (input, expected) in examples { #expect(tokenize(input) == expected) }
}

// v1.5.2 C-CM: coding-agent/test/tool-search.test.ts:19-22.
@Test("splits camelCase and snake_case, drops stop words, and folds plurals")
func c10UpstreamAsciiAndPunctuationTokens() {
    #expect(tokenize("listIssues for the GitHub_repo") == ["list", "issue", "git", "hub", "repo"])
    #expect(tokenize("searches queries HTTPServer") == ["search", "query", "http", "server"])
    #expect(tokenize("repo.issues/search:queries") == ["repo", "issue", "search", "query"])
}

// v1.5.2 C-CM: coding-agent/test/tool-search.test.ts:38,50,54.
@Test("preserves non-ASCII words and splits mixed-language identifiers")
func c10UpstreamMixedLanguageTokens() {
    #expect(tokenize("搜索GitHub_repoIssues résumé cafés") ==
        ["搜索", "git", "hub", "repo", "issue", "résumé", "cafés"])
}

@Test("normalizes canonically equivalent Unicode text")
func c10UpstreamNfcTokens() {
    #expect(tokenize("CAFÉ cafe\u{0301}") == ["café", "café"])
}

@Test("ignores whitespace, punctuation, and emoji")
func c10UpstreamEmptyTokens() {
    #expect(tokenize(" \t，。!? 😀 ").isEmpty)
}

@Test func c10SearchesUnicodeDescriptions() {
    let examples = [
        ("搜索仓库问题", "问题"), ("文書を検索", "検索"), ("문서 검색", "검색"),
        ("ค้นหาเอกสาร", "เอกสาร"), ("Поиск документов", "документов"),
        ("البحث عن الملفات", "الملفات"), ("फ़ाइल खोजें", "खोजें"),
        ("Rechercher un café", "cafe\u{0301}")
    ]
    for (description, query) in examples {
        let document = createToolSearchDocument(c10Tool("localized", description))
        #expect(Bm25Ranker().rank(query, documents: [document], limit: 8).map(\.name) == ["localized"])
    }
}

@Test func c10ExactAndLocalNameRanking() {
    let named = [
        c10Tool("mcp__app__queue_read", "Read a queued message of this thread."),
        c10Tool("mcp__dev-app__thread_read", "Read durable state and a paginated timeline from any thread. The default view returns user messages, assistant messages and plans. Continue with afterPosition until hasMore is false.")
    ].map { createToolSearchDocument($0) }
    let ranker = Bm25Ranker()
    for query in ["thread_read", "dev_app__thread_read", "mcp__dev-app__thread_read", "Thread_Read", "thread read"] {
        #expect(ranker.rank(query, documents: named, limit: 1).map(\.name) == ["mcp__dev-app__thread_read"])
    }
    #expect(ranker.rank("read", documents: named, limit: 1).map(\.name) == ["mcp__app__queue_read"])

    let peekaboo = ToolNamespace(name: "mcp__peekaboo", instructions: "Peekaboo controls macOS apps by app name.")
    let peekabooDocuments = [
        c10Tool("mcp__peekaboo__see", "Capture the app window of the peekaboo app and describe the app.", namespace: peekaboo),
        c10Tool("mcp__peekaboo__menu", "Click a menu item of an app.", namespace: peekaboo),
        c10Tool("mcp__peekaboo__app", "Launch, quit, relaunch, focus, hide, or switch applications. Targets an application by name, bundle identifier, or process ID, and can wait until it is ready.", namespace: peekaboo)
    ].map { createToolSearchDocument($0) }
    let documents = peekabooDocuments + named
    for query in ["peekaboo app", "open the peekaboo app tool"] {
        #expect(ranker.rank(query, documents: documents, limit: 1).map(\.name) == ["mcp__peekaboo__app"])
    }
    #expect(ranker.rank("read thread_read state", documents: documents, limit: 1).map(\.name) == ["mcp__dev-app__thread_read"])
    #expect(ranker.rank("describe window", documents: documents, limit: 1).map(\.name) == ["mcp__peekaboo__see"])
}

@Test func c10CoverageAndNameWeights() {
    let deploy = [
        c10Tool("mcp__ci__status", "Deploy status: last deploy, deploy log, deploy errors."),
        c10Tool("mcp__ci__deploy_release", "Start a release of the current branch to an environment, run the migrations, switch traffic over, and wait until the new version is live and healthy.")
    ].map { createToolSearchDocument($0) }
    #expect(Bm25Ranker().rank("deploy", documents: deploy, limit: 1).map(\.name) == ["mcp__ci__deploy_release"])
    let windows = [
        c10Tool("mcp__peekaboo__app", "Launch, quit, focus, or switch applications by name or bundle identifier."),
        c10Tool("mcp__peekaboo__see", "Capture the app window and describe the UI elements of the app."),
        c10Tool("mcp__peekaboo__window", "Move, resize, or close a window of an app."),
        c10Tool("mcp__peekaboo__image", "Take a screenshot of the screen, an app, or a window.")
    ].map { createToolSearchDocument($0) }
    let ranker = Bm25Ranker()
    #expect(ranker.rank("screenshot window", documents: windows, limit: 1).map(\.name) == ["mcp__peekaboo__image"])
    #expect(ranker.rank("describe app", documents: windows, limit: 1).map(\.name) == ["mcp__peekaboo__see"])
    #expect(ranker.rank("window", documents: windows, limit: 1).map(\.name) == ["mcp__peekaboo__window"])
}

@Test func c10SchemaReferences() {
    let referenced = c10Tool("mcp__ledger__inspect", "Inspect records", parameters: [
        "type": "object", "properties": ["options": ["$ref": "#/$defs/options"]],
        "$defs": ["options": ["type": "object", "properties": ["mode": ["type": "string", "description": "reconciliation"]]]]
    ])
    #expect(createToolSearchDocument(referenced).text == "Inspect records options mode reconciliation")

    let escaped = c10Tool("mcp__ledger__inspect", "Inspect records", parameters: [
        "type": "object", "properties": ["range": ["$ref": "#/$defs/date~1range"]],
        "$defs": ["date/range": ["description": "fiscal period"]]
    ])
    #expect(createToolSearchDocument(escaped).text == "Inspect records range fiscal period")

    let recursive = c10Tool("mcp__ledger__inspect", "Inspect records", parameters: [
        "type": "object", "properties": ["root": ["$ref": "#/$defs/node"], "self": ["$ref": "#"]],
        "$defs": ["node": ["description": "tree node", "properties": ["children": ["type": "array", "items": ["$ref": "#/$defs/node"]]]]]
    ])
    #expect(createToolSearchDocument(recursive).text == "Inspect records root tree node children self")

    let missing = c10Tool("mcp__ledger__inspect", "Inspect records", parameters: [
        "type": "object", "properties": ["remote": ["$ref": "https://example.com/schema.json#/$defs/x"]],
        "$defs": ["unused": ["description": "reconciliation"]]
    ])
    #expect(createToolSearchDocument(missing).text == "Inspect records remote")
}

// v1.5.2 C-CM: coding-agent/test/tool-search.test.ts:225,239.
@Test("reads recursive and shared definitions once")
func c10UpstreamSharedDefinitions() {
    let tool = c10Tool("mcp__ledger__inspect", "Inspect records", parameters: [
        "type": "object", "properties": ["root": ["$ref": "#/$defs/node"],
                                         "other": ["$ref": "#/$defs/node"], "self": ["$ref": "#"]],
        "$defs": ["node": ["description": "tree node", "properties":
            ["children": ["type": "array", "items": ["$ref": "#/$defs/node"]]]]]
    ])
    #expect(createToolSearchDocument(tool).text == "Inspect records other tree node children root self")
}

@Test("leaves out unreferenced definitions and remote or missing references")
func c10UpstreamUnresolvedDefinitions() {
    let tool = c10Tool("mcp__ledger__inspect", "Inspect records", parameters: [
        "type": "object", "properties": [
            "remote": ["$ref": "https://example.com/schema.json#/$defs/x"],
            "missing": ["$ref": "#/$defs/missing"],
            "malformed": ["$ref": "#/$defs/%E0%A4%A"]],
        "$defs": ["unused": ["description": "reconciliation"]]
    ])
    #expect(createToolSearchDocument(tool).text == "Inspect records malformed missing remote")
}

@Test func c10SearchDocumentBoundsHostileMetadata() {
    let huge = String(repeating: "é", count: 600_000)
    let document = createToolSearchDocument(c10Tool("huge", huge,
        parameters: ["type": "object", "description": huge],
        namespace: ToolNamespace(name: "huge", description: huge)))
    #expect(document.text.utf8.count + document.namespaceText.utf8.count <= 1_000_000)

    var nested: [String: Any] = ["description": "too deep"]
    for _ in 0..<70 { nested = ["items": nested] }
    let deep = createToolSearchDocument(c10Tool("deep", "root", parameters: nested))
    #expect(deep.text == "root")
}

private struct C10Fixture: Decodable {
    let tag: String
    let tools: [C10FixtureTool]
    let ranking: [C10FixtureRank]
}

private struct C10FixtureTool: Decodable {
    let name: String
    let description: String
    let parameters: [String: AnyCodable]
    let exposure: ToolExposure
    let namespace: ToolNamespace?

    var info: ToolInfo {
        ToolInfo(name: name, description: description, parameters: parameters,
                 exposure: exposure, namespace: namespace)
    }
}

private struct C10FixtureRank: Decodable {
    let query: String
    let limit: Int
    let names: [String]
    let text: String
}

private struct C10ToolAccess: ToolSearchToolAccess {
    private let tools: [ToolInfo]
    private let active = LockedState<[String]>([])

    init(_ tools: [ToolInfo]) { self.tools = tools }
    func getAllTools() -> [ToolInfo] { tools }
    func getActiveTools() -> [String] { active.withLock { $0 } }
    func setActiveTools(_ names: [String]) { active.withLock { $0 = names } }
}

@Test func c10TaggedToolSearchDifferentialFixtures() async throws {
    let url = try #require(Bundle.module.url(forResource: "codemode-cm-v152", withExtension: "json", subdirectory: "fixtures"))
    let fixture = try JSONDecoder().decode(C10Fixture.self, from: Data(contentsOf: url))
    #expect(fixture.tag == "v1.5.2")
    #expect(fixture.tools.count >= 80)
    #expect(fixture.ranking.count >= 60)
    let tools = fixture.tools.map(\.info)
    let candidates = tools.filter { $0.exposure == .deferred || $0.exposure == .codemode }
    let documents = candidates.map { createToolSearchDocument($0) }
    let context = CustomToolContext(sessionManager: .inMemory(),
        modelRegistry: ModelRegistry(AuthStorage(":memory:")), model: nil,
        isIdle: { true }, hasPendingMessages: { false }, abort: {},
        events: createEventBus(), sendMessage: { _, _ in })
    for row in fixture.ranking {
        let names = Bm25Ranker().rank(row.query, documents: documents, limit: row.limit).map(\.name)
        #expect(names == row.names, "Ranking: \(row.query)")
        let access = C10ToolAccess(tools)
        let tool = createToolSearchToolDefinition(options: ToolSearchToolOptions(tools: access))
        let result = try await tool.execute("fixture", ["query": AnyCodable(row.query), "limit": AnyCodable(row.limit)], nil, context, nil)
        let output = result.content.compactMap { block -> String? in
            if case .text(let value) = block { return value.text }
            return nil
        }.joined()
        #expect(output == row.text, "Output: \(row.query)")
        #expect(access.getActiveTools() == row.names, "Loaded: \(row.query)")
    }
}
