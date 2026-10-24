import Foundation
import PiSwiftAI
import PiSwiftChord
import PiSwiftDurable
import PiSwiftDurableTesting
import Testing

let e10PNG = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=="

func e10Call(_ code: String = "return 1", id: String = "s1") -> AssistantMessage {
    var message = chatAssistant("")
    message.content = [.toolCall(ToolCall(id: id, name: "codemode", arguments: ["code": AnyCodable(code)]))]
    message.stopReason = .toolUse
    return message
}
func e10Tool(_ name: String, description: String? = nil, deferred: Bool? = nil,
             callers: [ToolCaller]? = nil, schema: JSONObject? = nil,
             execute: @escaping @Sendable (JSONValue, ToolExecutionApi, ChordContext) async throws -> ToolExecutionResult = { _, _, _ in .init(output: []) }) throws -> ToolRegistration {
    try ToolRegistration(name: name, description: description ?? name, parameters: ["type": "object", "properties": ["path": ["type": "string", "description": "File path"]]],
                         callers: callers, deferred: deferred, structuredOutputSchema: schema, execute: execute)
}
func e10Open(setup: HarnessChatSetup, models: (any DurableModels)? = nil, env: (any ExecutionEnv)? = nil,
             storage: any DurableStorage = MemoryStorage()) async throws -> OpenChatResult {
    let harness = try await Harness.open(storage: storage, options: .init(models: models ?? setup.models, registry: setup.registry,
        settings: setup.settingsProvider, env: { _, _ in env }, onReport: { setup.reports.append($0) }), context: .background)
    let root = try await harness.root(options: .init(agent: .init(model: .set(.init(provider: "faux", modelId: "faux-1")))), context: .background)
    return OpenChatResult(harness: harness, root: root)
}
func e10Submit(_ opened: OpenChatResult) async throws {
    let submission = try await opened.root.submit(.input(content: .text("go")), context: .background)
    let settled = try await submission.wait(context: .background)
    #expect(settled.status == "done", "Submission: \(settled)")
}
func e10Message(_ root: Conversation) async throws -> JSONValue {
    try #require(await allEntries(root).first { $0.kind == "pi.tool-result" }?.model?.first)
}
func e10Text(_ message: JSONValue) -> String {
    message["content"]?.arrayValue?.map { $0["text"]?.stringValue ?? "<\($0["type"]?.stringValue ?? "unknown")>" }.joined() ?? ""
}
func e10Value(_ outcome: CodemodeOutcome) -> JSONValue? {
    if case .success(let value) = outcome { value } else { nil }
}

func e10Run(_ sandbox: any CodemodeSandbox, code: String = "return 1", tools: [ToolRegistration] = [],
            namespaces: [CodemodeNamespace] = [], env: (any ExecutionEnv)? = nil) async throws -> JSONValue {
    let setup = HarnessChatSetup(options: .init(models: [.init(id: "faux-1", contextWindow: 2_000_000)]))
    try setup.registry.install(createCodemodeExtension(options: .init(sandbox: sandbox, namespaces: namespaces, models: false)))
    try setup.registry.install(Extension(name: "e10-tools", tools: tools))
    setup.models.setResponses([.message(e10Call(code)), .message(chatAssistant("done"))])
    let opened = try await e10Open(setup: setup, env: env)
    try await e10Submit(opened)
    try await opened.harness.waitForIdle(context: .background)
    let message = try await e10Message(opened.root)
    #expect(setup.reports.values.isEmpty)
    try await opened.harness.close(context: .background)
    return message
}
