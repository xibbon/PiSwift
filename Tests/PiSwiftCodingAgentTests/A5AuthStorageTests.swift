import Foundation
import Testing
import PiSwiftAI
@testable import PiSwiftCodingAgent

@Test func a5ChatGPTCredentialFieldsPersistAndResolveAsOpenAIKey() async throws {
    let backend = InMemoryAuthStorageBackend()
    let first = AuthStorage(storage: backend)
    first.set("openai", credential: .oauth(OAuthCredential(
        access: "chatgpt-access", refresh: "refresh", expires: Date().timeIntervalSince1970 * 1000 + 3_600_000,
        clientId: "oaiapp_issued", scopes: ["openid", "chatgpt.tokens.use.direct"]
    )))
    let restored = AuthStorage(storage: backend)
    guard case .oauth(let credential) = restored.get("openai") else {
        Issue.record("Expected persisted OAuth credential")
        return
    }
    #expect(credential.clientId == "oaiapp_issued")
    #expect(credential.scopes == ["openid", "chatgpt.tokens.use.direct"])
    #expect(await restored.getApiKey("openai") == "chatgpt-access")
}
