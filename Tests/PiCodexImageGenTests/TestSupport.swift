import Foundation
@testable import PiCodexImageGen
import PiSwiftAI
import PiSwiftAgent
import PiSwiftCodingAgent

/// Records requests and returns queued responses in order.
final class FakeHTTPClient: ProviderHTTPClient, Sendable {
    struct Reply: Sendable {
        var status: Int
        var headers: [String: String] = [:]
        var body: Data
    }

    private let replies: LockedState<[Reply]>
    let requests = LockedState<[URLRequest]>([])

    init(_ replies: [Reply]) {
        self.replies = LockedState(replies)
    }

    func send(_ request: URLRequest) async throws -> ProviderHTTPResponse {
        requests.withLock { $0.append(request) }
        let reply = replies.withLock { $0.isEmpty ? nil : $0.removeFirst() }
        guard let reply else { throw URLError(.notConnectedToInternet) }
        return ProviderHTTPResponse(statusCode: reply.status, headers: reply.headers, body: reply.body)
    }

    var requestCount: Int { requests.withLock { $0.count } }
}

let testAccountId = "acct_test-123"

func makeJWT(accountId: String? = testAccountId) -> String {
    func encode(_ object: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: object)
        return data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    var payload: [String: Any] = ["sub": "user"]
    if let accountId { payload["https://api.openai.com/auth"] = ["chatgpt_account_id": accountId] }
    return "\(encode(["alg": "none"])).\(encode(payload)).signature"
}

/// A tiny byte sequence with a valid PNG signature.
let pngBytes = Data([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0, 0, 0, 13, 0x49, 0x48, 0x44, 0x52])
let jpegBytes = Data([0xff, 0xd8, 0xff, 0xe0, 0, 16, 0x4a, 0x46])

func sse(_ events: [[String: Any]]) -> Data {
    var text = ""
    for event in events {
        let json = String(data: try! JSONSerialization.data(withJSONObject: event), encoding: .utf8)!
        text += "event: \(event["type"] as? String ?? "message")\ndata: \(json)\n\n"
    }
    return Data(text.utf8)
}

func imageItem(_ bytes: Data = pngBytes, id: String = "ig_1", extra: [String: Any] = [:]) -> [String: Any] {
    var item: [String: Any] = ["type": "image_generation_call", "id": id, "status": "completed",
                               "result": bytes.base64EncodedString()]
    item.merge(extra) { _, new in new }
    return item
}

func completedStream(_ bytes: Data = pngBytes, extra: [String: Any] = [:]) -> Data {
    sse([
        ["type": "response.created", "response": ["id": "resp_1"]],
        ["type": "response.image_generation_call.in_progress"],
        ["type": "response.image_generation_call.generating"],
        ["type": "response.output_item.done", "item": imageItem(bytes, extra: extra)],
        ["type": "response.completed", "response": ["id": "resp_1", "usage": ["input_tokens": 5, "output_tokens": 7, "secret": "x"]]],
    ])
}

func makeTempDir() -> String {
    let path = (NSTemporaryDirectory() as NSString).appendingPathComponent("piswift-codex-image-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    return URL(fileURLWithPath: path).resolvingSymlinksInPath().path
}

let chatGPTModel = getModels(provider: .openaiCodex).first!
let anthropicModel = getModels(provider: .anthropic).first!

func makeRegistry(token: String = makeJWT()) -> ModelRegistry {
    let storage = AuthStorage(":memory:")
    storage.set(codexImageChatGPTProvider, credential: .oauth(OAuthCredential(
        access: token, refresh: "refresh", expires: Date().addingTimeInterval(3600).timeIntervalSince1970 * 1000)))
    return ModelRegistry(storage)
}

struct Harness {
    let api: HookAPI
    let client: FakeHTTPClient
    let session: SessionManager
    let registry: ModelRegistry
    let agentDir: String
    let artifactRoot: String
    let token: String
    let entries: LockedState<[(String, AnyCodable)]>

    init(replies: [FakeHTTPClient.Reply], token: String = makeJWT(), admission: ImageAdmission = ImageAdmission()) {
        api = HookAPI(events: createEventBus(), hookPath: "<test:codex-image-gen>")
        client = FakeHTTPClient(replies)
        self.token = token
        let cwd = makeTempDir()
        session = SessionManager.inMemory(cwd)
        registry = makeRegistry(token: token)
        agentDir = makeTempDir()
        artifactRoot = makeTempDir()
        let entries = LockedState<[(String, AnyCodable)]>([])
        self.entries = entries
        let session = session
        api.setAppendEntryHandler { type, data in
            entries.withLock { $0.append((type, AnyCodable(data))) }
            _ = session.appendCustomEntry(type, data)
        }
        let agentDir = agentDir
        let artifactRoot = artifactRoot
        registerCodexImageGen(api, environment: CodexImageGenEnvironment(
            httpClient: client, admission: admission, agentDir: { agentDir }, artifactRoot: { artifactRoot },
            random: { 0 }))
    }

    func hookContext(_ model: Model?) -> HookContext {
        HookContext(sessionManager: session, modelRegistry: registry, model: model, hasUI: false)
    }

    func emitSessionStart(_ model: Model?) async throws {
        for handler in api.handlers["session_start"] ?? [] {
            _ = try await handler(SessionStartEvent(reason: .startup), hookContext(model))
        }
    }

    func emitModelSelect(_ model: Model, previous: Model? = nil) async throws {
        for handler in api.handlers["model_select"] ?? [] {
            _ = try await handler(ModelSelectEvent(model: model, previousModel: previous, source: .set), hookContext(model))
        }
    }

    func toolContext(_ model: Model?) -> CustomToolContext {
        CustomToolContext(sessionManager: session, modelRegistry: registry, model: model, isIdle: { true },
                          hasPendingMessages: { false }, abort: {}, events: createEventBus(), sendMessage: { _, _ in })
    }

    func run(_ name: String, _ params: [String: Any], model: Model? = chatGPTModel,
             signal: CancellationToken? = nil, updates: LockedState<[String]>? = nil) async throws -> AgentToolResult {
        let tool = try require_tool(api, name)
        let update: AgentToolUpdateCallback = { result in
            if case .text(let text)? = result.content.first { updates?.withLock { $0.append(text.text) } }
        }
        return try await tool.execute("call_1", params.mapValues { AnyCodable($0) }, update, toolContext(model), signal)
    }
}

struct MissingTool: Error { let name: String }

func require_tool(_ api: HookAPI, _ name: String) throws -> CustomTool {
    guard let tool = api.tools[name] else { throw MissingTool(name: name) }
    return tool
}

extension LockedState where Value == [(String, AnyCodable)] {
    var types: [String] { withLock { $0.map(\.0) } }
}

func structured(_ result: AgentToolResult) -> [String: Any] {
    result.structuredContent?.value as? [String: Any] ?? [:]
}

func details(_ result: AgentToolResult) -> [String: Any] {
    result.details?.value as? [String: Any] ?? [:]
}

func text(_ result: AgentToolResult) -> String {
    result.content.compactMap { block -> String? in
        if case .text(let text) = block { return text.text }
        return nil
    }.joined(separator: "\n")
}
