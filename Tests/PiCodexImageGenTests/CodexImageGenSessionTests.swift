import Foundation
import Testing
@testable import PiCodexImageGen
import PiSwiftAI
import PiSwiftCodingAgent

/// The live path: tools register on `session_start` and `model_select` inside a
/// real `AgentSession`, and leave the session after a switch to another provider.
@Suite("PiCodexImageGen session")
struct CodexImageGenSessionTests {
    @Test(.timeLimit(.minutes(1))) func toolsFollowTheSessionModel() async throws {
        let auth = AuthStorage(":memory:")
        auth.set(codexImageChatGPTProvider, credential: .oauth(OAuthCredential(
            access: makeJWT(), refresh: "r", expires: Date().addingTimeInterval(3600).timeIntervalSince1970 * 1000)))
        auth.setRuntimeApiKey(anthropicModel.provider, "test")
        let dir = makeTempDir()
        let created = try await createAgentSession(CreateAgentSessionOptions(
            cwd: dir, agentDir: dir, authStorage: auth, model: chatGPTModel, offline: true,
            inlineExtensions: [CodexImageGen.inlineExtension],
            sessionManager: .inMemory(dir), settingsManager: .inMemory()))
        let session = created.session
        defer { session.dispose() }
        #expect(created.diagnostics.filter { $0.type == "error" }.isEmpty)

        func names() -> Set<String> { Set(session.getAllTools().map(\.name)) }
        #expect(names().isDisjoint(with: CodexImageGen.toolNames))

        _ = await session.hookRunner?.emit(SessionStartEvent())
        #expect(names().isSuperset(of: CodexImageGen.toolNames))
        let active = Set(session.getActiveToolNames())
        #expect(active.contains(CodexImageGen.inlineToolName))
        #expect(active.contains(CodexImageGen.listToolName))

        try await session.setModel(anthropicModel)
        #expect(names().isDisjoint(with: CodexImageGen.toolNames))
        #expect(Set(session.getActiveToolNames()).isDisjoint(with: CodexImageGen.toolNames))

        try await session.setModel(chatGPTModel)
        #expect(names().isSuperset(of: CodexImageGen.toolNames))
        #expect(session.getActiveToolNames().contains(CodexImageGen.inlineToolName))
    }
}
