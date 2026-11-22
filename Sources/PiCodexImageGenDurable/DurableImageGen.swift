import Foundation
import PiCodexImageGen
import PiSwiftAI
import PiSwiftAgent
import PiSwiftChord
import PiSwiftCodingAgent
import PiSwiftDurable

// The image tool for a durable harness (PiSwiftDurable). It runs the same
// generation code as the HookAPI extension. The harness gets only the direct
// model tool, `codex_generate_image`, which returns the image inline. The
// tool permits only model calls (`callers: [.model]`), so codemode scripts
// cannot call it. This is the same rule as `exposure: .modelOnly` in the
// HookAPI version. The artifact and list tools for scripts are not included.

extension CodexImageGen {
    /// The names of the tools in `durableExtension`.
    public static var durableToolNames: [String] { [inlineToolName] }

    /// The image tool as a durable harness extension.
    ///
    /// - Parameters:
    ///   - agentDir: The agent directory of the harness. Global saves go in
    ///     `<agentDir>/generated-images/<conversation key>/`.
    ///   - modelRegistry: Supplies the ChatGPT login of the conversation model.
    ///   - defaultCwd: The working directory when the conversation has no
    ///     execution environment and the agent has no `cwd`.
    ///
    /// The tool works only while the conversation model is an `openai-codex`
    /// model. Use `durableExtensionChange(for:in:base:)` when the model
    /// changes, so that the model sees the tool only for a ChatGPT model.
    public static func durableExtension(agentDir: String, modelRegistry: ModelRegistry,
                                        defaultCwd: String) throws -> PiSwiftDurable.Extension {
        try makeDurableExtension(agentDir: agentDir, modelRegistry: modelRegistry, defaultCwd: defaultCwd,
                                 environment: CodexImageGenEnvironment())
    }

    /// The extension selection for `model`. Apply it in the same
    /// `AgentChange` as the model.
    ///
    /// - Parameters:
    ///   - base: The extension selection of the host without the image tool.
    ///     Nil means the host defaults. The result keeps the other edits in
    ///     `base`, and adds or removes only `imageExtension`.
    ///
    /// A `modelTools` edit is not used: it would also replace the deferred
    /// tools that tool search loaded.
    public static func durableExtensionChange(for model: PiSwiftDurable.ModelRef?,
                                              in imageExtension: PiSwiftDurable.Extension,
                                              base: ExtensionChange? = nil) -> AgentFieldChange<ExtensionChange> {
        let enable = model?.provider == codexImageChatGPTProvider
        let name = imageExtension.name
        func without(_ list: [PiSwiftDurable.Extension]?) -> [PiSwiftDurable.Extension] {
            (list ?? []).filter { $0.name != name }
        }
        switch base {
        case .exact(let list):
            return .set(.exact(without(list) + (enable ? [imageExtension] : [])))
        case .edit(let add, let remove):
            let add = without(add)
            let remove = without(remove) + (enable ? [] : [imageExtension])
            if add.isEmpty && remove.isEmpty { return .clear }
            return .set(.edit(add: add.isEmpty ? nil : add, remove: remove.isEmpty ? nil : remove))
        case nil:
            return enable ? .clear : .set(.edit(remove: [imageExtension]))
        }
    }
}

/// A random key for each durable conversation. Conversation IDs are small
/// sequential numbers and repeat in each store, so they cannot be the prompt
/// cache key or the name of a save folder. A forked conversation gets a new key.
private struct ConversationKey: Codable, Sendable {
    var key: String
}

func makeDurableExtension(agentDir: String, modelRegistry: ModelRegistry, defaultCwd: String,
                          environment base: CodexImageGenEnvironment) throws -> PiSwiftDurable.Extension {
    var configured = base
    configured.agentDir = { agentDir }
    let environment = configured
    let keyToken = try ConversationDocToken<ConversationKey>(
        kind: "codex-image-gen.conversation-key", version: 1, fork: .initial,
        initial: { ConversationKey(key: UUID().uuidString) }, checkpointWhen: { _, _, _ in false })
    // Used only when the tool runs without a task runtime.
    let fallbackKey = UUID().uuidString
    let parameters = try durableJSON(fromFoundation: toolParameters().mapValues(\.value))
    guard let parameters = parameters.objectValue else {
        throw CodexImageError("The image tool parameters are not an object.")
    }
    let tool = try ToolRegistration(
        name: CodexImageGen.inlineToolName,
        description: "\(toolDescription) Returns an inline image. " + codexImageGuidelines.joined(separator: " "),
        parameters: parameters,
        callers: [.model],
        executionMode: .parallel
    ) { arguments, api, context -> ToolExecutionOutcome in
        let context = api.runtime.map { context.withAbortSignal($0.signal) } ?? context
        return try await withContextCancellation(context) { token in
            guard let object = try foundationJSON(from: arguments) as? [String: Any] else {
                throw CodexImageError("The image tool arguments are not an object.")
            }
            let agent = try await api.agent(context)
            let model = agent.model.flatMap { api.models.getModel(provider: $0.provider, modelId: $0.modelId) }
            let runtime = api.runtime
            let conversationId = api.conversationId
            let sessionId = runtime == nil ? "\(fallbackKey)-\(conversationId.rawValue)"
                : try await conversationKey(api: api, token: keyToken, context: context)
            let files = api.env.map { environmentFiles($0, context: context) }
            let host = ImageCallHost(
                model: model,
                modelRegistry: modelRegistry,
                cwd: api.env?.cwd ?? agent.cwd ?? defaultCwd,
                sessionId: sessionId,
                lifetime: nil,
                files: files ?? .host(cwd: agent.cwd ?? defaultCwd),
                recentSources: {
                    guard let runtime else { return [] }
                    let view = try await runtime.context(conversationId, context: context)
                    return durableImageSources(view.messages)
                },
                // Inline calls make no reservation and attach no artifact record.
                reserve: { _ in nil },
                attach: { _, _ in false }
            )
            let result = try await executeImage(
                artifactMode: false, toolCallId: api.callId, params: object.mapValues(AnyCodable.init),
                onUpdate: { update in
                    let text = update.content.compactMap { block -> String? in
                        if case .text(let text) = block { return text.text }
                        return nil
                    }.joined(separator: "\n")
                    if !text.isEmpty { try? api.output(.text(text + "\n"), nil) }
                },
                host: host, signal: token, environment: environment)
            return .result(ToolExecutionResult(
                output: result.content,
                structuredOutput: try result.structuredContent.map { try durableJSON(fromFoundation: $0.value) },
                isError: result.isError,
                details: try result.details.map { try durableJSON(fromFoundation: $0.value) }
            ))
        }
    }
    return PiSwiftDurable.Extension(name: "codex-image-gen", tools: [tool])
}

/// Reads the key of the conversation. The first call stores a new key.
private func conversationKey(api: ToolExecutionApi, token: ConversationDocToken<ConversationKey>,
                             context: ChordContext) async throws -> String {
    if let stored = try await api.snapshot(token, conversationId: api.conversationId, context: context) {
        return stored.key
    }
    return try await api.commit({ tx in
        let draft = try await tx.doc(token, conversationId: api.conversationId)
        guard case .string(let key)? = try draft.get("key") else {
            throw CodexImageError("The image conversation key is not valid.")
        }
        // Write the key, so that a new document is stored.
        try draft.set("key", .string(key))
        return key
    }, context: context)
}

/// The image sources in the messages that the model sees, oldest first.
/// `ContextView.messages` applies the context head, the context edits, and
/// the tool-result order.
func durableImageSources(_ messages: [Message]) -> [ConversationImageSource] {
    messages.map { .blocks(conversationBlocks($0)) }
}

/// File access through the execution environment of the conversation, as
/// the durable read and write tools do.
private func environmentFiles(_ env: any ExecutionEnv, context: ChordContext) -> ImageFileAccess {
    ImageFileAccess(
        resolve: { path, _ in try await env.absolutePath(path, context: context).get() },
        read: { path in
            let info = try await env.fileInfo(path, context: context).get()
            guard info.kind != .directory else { throw CodexImageError("Referenced images must be regular files.") }
            guard info.size <= Int64(codexMaxInputImageBytes) else { throw CodexImageError("Referenced image exceeds 20 MiB.") }
            let bytes = try await env.readBinaryFile(path, context: context).get()
            guard bytes.count <= codexMaxInputImageBytes else { throw CodexImageError("Referenced image exceeds 20 MiB.") }
            return Data(bytes)
        },
        writeNew: { bytes, path, directory in
            try await env.createDir(directory, options: CreateDirOptions(recursive: true), context: context).get()
            if try await env.exists(path, context: context).get() {
                throw CodexImageError("File exists: \(path)")
            }
            try await env.writeFile(path, content: .bytes([UInt8](bytes)), context: context).get()
        }
    )
}
