import Foundation
import Testing
import PiSwiftAI
@testable import PiSwiftCodingAgent

@Test func metaOAuthStorageRefreshesMintedKeyAndModelRegistryUsesIt() async {
    let now = Date().timeIntervalSince1970 * 1_000
    let storage = AuthStorage.inMemory([
        "meta": .oauth(OAuthCredential(
            access: "old-minted-key",
            refresh: "identity-token",
            expires: now - 1
        )),
    ])
    let refreshCount = LockedState(0)
    storage.setOAuthOverridesForTesting(OAuthOverrides(
        getOAuthApiKey: { provider, credentials in
            #expect(provider == .meta)
            #expect(credentials["meta"]?.refresh == "identity-token")
            refreshCount.withLock { $0 += 1 }
            let updated = OAuthCredentials(
                refresh: "identity-token",
                access: "new-minted-key",
                expires: now + 86_400_000
            )
            return (newCredentials: updated, apiKey: updated.access)
        },
        oauthApiKey: nil
    ))
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let registry = ModelRegistry(
        storage, directory.path,
        modelsStore: FileModelsStore(directory.appendingPathComponent("models-store.json").path),
        networkEnabled: false
    )
    let model = getModel(provider: .meta, modelId: "muse-spark-1.1")
    let auth = await registry.getApiKeyAndHeaders(model)
    #expect(auth.ok)
    #expect(auth.apiKey == "new-minted-key")
    #expect(refreshCount.withLock { $0 } == 1)
    if case .oauth(let stored) = storage.get("meta") {
        #expect(stored.refresh == "identity-token")
        #expect(stored.access == "new-minted-key")
    } else {
        Issue.record("Meta OAuth credentials must remain stored")
    }
}

@Test func metaExpiredIdentityRequiresReloginInAuthStorage() async {
    let storage = AuthStorage.inMemory([
        "meta": .oauth(OAuthCredential(
            access: "expired-minted-key",
            refresh: "expired-identity",
            expires: Date().timeIntervalSince1970 * 1_000 - 1
        )),
    ])
    storage.setOAuthOverridesForTesting(OAuthOverrides(
        getOAuthApiKey: { provider, _ in
            #expect(provider == .meta)
            throw OAuthError.refreshFailed("Meta session expired. Run `/login meta` to sign in again.")
        },
        oauthApiKey: nil
    ))
    #expect(await storage.getApiKey("meta") == nil)
}
