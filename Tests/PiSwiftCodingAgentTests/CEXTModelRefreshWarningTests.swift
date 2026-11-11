import Foundation
import Testing
import PiSwiftAI
@testable import PiSwiftCodingAgent

private enum CatalogWarningTestError: LocalizedError {
    case requestFailed

    var errorDescription: String? { "OpenRouter model list request failed: 500" }
}

private struct SignedOutCatalogClient: ProviderHTTPClient {
    let requests: LockedState<Int>

    func send(_ request: URLRequest) async throws -> ProviderHTTPResponse {
        requests.withLock { $0 += 1 }
        return ProviderHTTPResponse(
            statusCode: 200,
            headers: ["Last-Modified": "Wed, 12 Aug 2037 12:00:00 GMT"],
            body: Data("[]".utf8)
        )
    }
}

// Ports remote-catalog-provider.test.ts: "fetches the pi.dev catalog without
// refreshing a stale OAuth login".
@Test func cextRemoteCatalogIgnoresExpiredOAuth() async {
    let auth = AuthStorage.inMemory(["openai": .oauth(OAuthCredential(
        access: "expired", refresh: "revoked", expires: 0
    ))])
    let requests = LockedState(0)
    let registry = ModelRegistry(
        auth,
        modelsStore: InMemoryModelsStore(),
        catalogBaseURL: "https://catalog.example.invalid",
        remoteHTTPClient: SignedOutCatalogClient(requests: requests),
        now: { 2_200_000_000_000 }
    )

    let result = await registry.refresh(ModelsRefreshOptions(providers: ["openai"], force: true))
    #expect(result.errors.isEmpty)
    #expect(requests.withLock { $0 } == 1)
    if case .oauth(let credential) = auth.get("openai") {
        #expect(credential.access == "expired")
        #expect(credential.refresh == "revoked")
    } else {
        Issue.record("The stale OAuth login was replaced")
    }
}

private func warningRefreshSource(id: String, error: any Error) -> ModelsRefreshSource {
    ModelsRefreshSource(
        id: id,
        readStoredCredential: { nil },
        resolveCredential: { _ in Issue.record("OAuth refresh ran"); return nil },
        refreshAuth: .configured,
        hasConfiguredAuth: { true },
        refresh: { context in
            if context.allowNetwork { throw error }
        }
    )
}

// Ports package-command-paths.test.ts: "warns about a stale provider login during
// update --models and keeps the refresh successful" at the library/host boundary.
@Test func cextStaleLoginProducesCatalogWarning() async {
    let coordinator = ModelCatalogRefreshCoordinator(store: InMemoryModelsStore(), sources: [
        warningRefreshSource(id: "radius", error: OAuthError.refreshFailed("invalid_grant"))
    ])

    let result = await coordinator.refresh()
    #expect(!result.aborted)
    #expect(result.catalogFailures.isEmpty)
    #expect(result.catalogWarnings() == [
        "Warning: skipped model catalog for radius: OAuth token refresh failed: invalid_grant\n" +
        "Log in again with `pi auth login radius` to refresh it."
    ])
    #expect(result.errors["radius"] != nil)
}

// Ports package-command-paths.test.ts: "fails update --models when a catalog refresh
// fails for a reason other than a stale login" at the library/host boundary.
@Test func cextOtherCatalogFailureStillFailsUpdate() async {
    let coordinator = ModelCatalogRefreshCoordinator(store: InMemoryModelsStore(), sources: [
        warningRefreshSource(id: "radius", error: OAuthError.refreshFailed("invalid_grant")),
        warningRefreshSource(id: "openrouter", error: CatalogWarningTestError.requestFailed)
    ])

    let result = await coordinator.refresh()
    #expect(!result.aborted)
    #expect(result.catalogWarnings().count == 1)
    #expect(result.catalogFailures.count == 1)
    #expect(result.catalogFailures["openrouter"]?.localizedDescription ==
            "OpenRouter model list request failed: 500")
}
