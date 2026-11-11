import Foundation
import Testing
import PiSwiftAI
import PiSwiftAgent
@testable import PiSwiftCodingAgent

private func billedUsage(_ billed: Bool?) -> Usage {
    Usage(input: 2, output: 3, cacheRead: 0, cacheWrite: 0, totalTokens: 5,
          cost: UsageCost(input: 0.2, output: 0.3, total: 0.5, totalFromProvider: billed))
}

@Test func costProvenanceSurvivesCombinationAndTotals() {
    let twoBilled = combineUsage(billedUsage(true), billedUsage(true))
    #expect(twoBilled.cost.total == 1)
    #expect(twoBilled.cost.totalFromProvider == true)
    let mixed = combineUsage(billedUsage(true), billedUsage(nil))
    #expect(mixed.cost.total == 1)
    #expect(mixed.cost.totalFromProvider == false)
    var totals = UsageTotals()
    totals.add(billedUsage(true))
    totals.add(billedUsage(nil))
    #expect(totals.cost == 1)
}

@Test func costProvenanceSurvivesSessionFileAndOldFileLoads() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("acost-session-\(UUID())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let manager = SessionManager.create("/tmp", directory.path)
    let assistant = AssistantMessage(content: [.text(TextContent(text: "done"))], api: .openAICompletions,
        provider: "openrouter", model: "test", usage: billedUsage(true), stopReason: .stop)
    manager.appendMessage(.assistant(assistant))
    manager.appendUsage("cacheWarming", "openrouter", "test", billedUsage(true))
    manager.appendCompaction("summary", nil, 5, usage: billedUsage(true))
    manager.appendBranchSummary("origin", "branch", usage: billedUsage(true))
    let file = try #require(manager.getSessionFile())
    let contents = try String(contentsOfFile: file, encoding: .utf8)
    #expect(contents.contains(#""totalFromProvider":true"#))
    let reloaded = SessionManager.open(file)
    let restored = reloaded.getEntries().compactMap { entry -> Usage? in
        if case .usage(let value) = entry { return value.usage }
        return nil
    }
    #expect(restored.first?.cost.totalFromProvider == true)
    #expect(reloaded.getEntries().contains { entry in
        if case .compaction(let value) = entry { return value.usage?.cost.totalFromProvider == true }
        return false
    })
    #expect(reloaded.getEntries().contains { entry in
        if case .branchSummary(let value) = entry { return value.usage?.cost.totalFromProvider == true }
        return false
    })

    // This is the JSON shape written by Swift before this order: cost has no provenance key.
    let oldFile = directory.appendingPathComponent("old.jsonl")
    try contents.replacingOccurrences(of: #","totalFromProvider":true"#, with: "")
        .replacingOccurrences(of: #""totalFromProvider":true,"#, with: "")
        .write(to: oldFile, atomically: true, encoding: .utf8)
    let old = SessionManager.open(oldFile.path)
    let oldUsage = old.getEntries().compactMap { entry -> Usage? in
        if case .usage(let value) = entry { return value.usage }
        return nil
    }
    #expect(oldUsage.first?.cost.totalFromProvider == nil)
}

@Test("refreshes catalogs that need only configured auth without refreshing OAuth")
func configuredCatalogRefreshSkipsOAuthRenewal() async {
    let renewed = LockedState(0)
    let requests = LockedState(0)
    let coordinator = ModelCatalogRefreshCoordinator(store: InMemoryModelsStore(), sources: [
        ModelsRefreshSource(id: "configured", readStoredCredential: { "expired-oauth" },
            resolveCredential: { _ in renewed.withLock { $0 += 1 }; return "new-token" },
            refreshAuth: .configured, hasConfiguredAuth: { true }, refresh: { context in
                if context.allowNetwork {
                    #expect(context.credential == nil)
                    requests.withLock { $0 += 1 }
                }
            }),
        ModelsRefreshSource(id: "missing", readStoredCredential: { nil },
            resolveCredential: { _ in renewed.withLock { $0 += 1 }; return "new-token" },
            refreshAuth: .configured, hasConfiguredAuth: { false }, refresh: { context in
                if context.allowNetwork { Issue.record("Unconfigured provider refreshed") }
            })
    ])
    let result = await coordinator.refresh()
    #expect(result.errors.isEmpty)
    #expect(renewed.withLock { $0 } == 0)
    #expect(requests.withLock { $0 } == 1)
}

private actor CopilotCostClient: ProviderHTTPClient {
    var request: URLRequest?
    func send(_ request: URLRequest) async throws -> ProviderHTTPResponse {
        self.request = request
        return ProviderHTTPResponse(statusCode: 200, headers: [:],
            body: Data(#"{"answers":{"approved":{"type":"noul","noul":0.8}}}"#.utf8))
    }
    func captured() -> URLRequest? { request }
}

@Test("routes GitHub Copilot Microsoft-Decision-1 to the account's /v1/systemone endpoint")
func copilotRegistryClassifierAccountEndpoint() async throws {
    let auth = AuthStorage.inMemory(["github-copilot": .oauth(OAuthCredential(
        access: "tid=x;exp=9999999999;proxy-ep=proxy.business.githubcopilot.com;",
        refresh: "refresh", expires: Date().timeIntervalSince1970 * 1_000 + 3_600_000))])
    let registry = ModelRegistry(auth, modelsStore: InMemoryModelsStore(), networkEnabled: false)
    guard case .classifier(let model)? = registry.getModelOfType(.classifier,
        provider: "github-copilot", modelId: "microsoft-decision-1") else {
        Issue.record("Missing Copilot classifier")
        return
    }
    let client = CopilotCostClient()
    let result = await registry.classify(model, context: ClassifierContext(state: [:], questions: [
        "approved": .bool(instructions: "Approved?", trueCriterion: "Yes", falseCriterion: "No")
    ]), options: ClassifierOptions(httpClient: client))
    #expect(result.stopReason == .stop)
    let request = try #require(await client.captured())
    #expect(request.url?.absoluteString == "https://api.business.githubcopilot.com/v1/systemone")
    #expect(request.value(forHTTPHeaderField: "Editor-Version") == "vscode/1.107.0")
}
