import Foundation
import PiSwiftAI
import PiSwiftAgent
import PiSwiftChord
import PiSwiftCodingAgent
import PiSwiftDurable

// The image tool for a durable harness (PiSwiftDurable). It runs the same
// generation code as the HookAPI extension. A durable harness has no codemode
// scripts here, so it gets only the direct model tool, `codex_generate_image`,
// which returns the image inline. The artifact and list tools are not included.

extension CodexImageGen {
    /// The names of the tools in `durableExtension`.
    public static var durableToolNames: [String] { [inlineToolName] }

    /// The image tool as a durable harness extension.
    ///
    /// - Parameters:
    ///   - agentDir: The agent directory of the harness. Global saves go in
    ///     `<agentDir>/generated-images/<conversation id>/`.
    ///   - modelRegistry: Resolves the conversation model and its ChatGPT login.
    ///   - defaultCwd: The working directory when the agent has none.
    ///
    /// The tool works only while the conversation model is an `openai-codex`
    /// model. Use `durableExtensionChange(for:in:)` when the model changes,
    /// so that the model sees the tool only for a ChatGPT model.
    public static func durableExtension(agentDir: String, modelRegistry: ModelRegistry,
                                        defaultCwd: String) throws -> PiSwiftDurable.Extension {
        try makeDurableExtension(agentDir: agentDir, modelRegistry: modelRegistry, defaultCwd: defaultCwd,
                                 environment: CodexImageGenEnvironment())
    }

    /// The extension selection for `model`: the default selection for a
    /// ChatGPT model, and the default without `imageExtension` for others.
    /// Apply it in the same `AgentChange` as the model. It replaces the whole
    /// extension selection, so use it only when the host selects no other
    /// extensions. (A `modelTools` edit is not used: it would also replace the
    /// deferred tools that tool search loaded.)
    public static func durableExtensionChange(for model: PiSwiftDurable.ModelRef?,
                                              in imageExtension: PiSwiftDurable.Extension) -> AgentFieldChange<ExtensionChange> {
        if model?.provider == codexImageChatGPTProvider {
            return .clear
        }
        return .set(.edit(remove: [imageExtension]))
    }
}

func makeDurableExtension(agentDir: String, modelRegistry: ModelRegistry, defaultCwd: String,
                          environment base: CodexImageGenEnvironment) throws -> PiSwiftDurable.Extension {
    var configured = base
    configured.agentDir = { agentDir }
    let environment = configured
    let parameters = try durableJSON(fromFoundation: toolParameters().mapValues(\.value))
    guard let parameters = parameters.objectValue else {
        throw CodexImageError("The image tool parameters are not an object.")
    }
    let tool = try ToolRegistration(
        name: CodexImageGen.inlineToolName,
        description: "\(toolDescription) Returns an inline image. " + codexImageGuidelines.joined(separator: " "),
        parameters: parameters,
        executionMode: .parallel
    ) { arguments, api, context in
        let cancellation = DurableCancellation(context: context, runtimeSignal: api.runtime?.signal)
        defer { cancellation.remove() }
        let params = try JSONDecoder().decode([String: AnyCodable].self, from: JSONEncoder().encode(arguments))
        let agent = try await api.agent(context)
        let model = agent.model.flatMap { modelRegistry.find($0.provider, $0.modelId) }
        let runtime = api.runtime
        let host = ImageCallHost(
            model: model,
            modelRegistry: modelRegistry,
            cwd: agent.cwd ?? defaultCwd,
            sessionId: String(api.conversationId.rawValue),
            lifetime: nil,
            recentSources: {
                guard let runtime else { return [] }
                return try await durableImageSources(runtime: runtime, context: context)
            },
            // Inline calls make no reservation and attach no artifact record.
            reserve: { _ in nil },
            attach: { _, _ in false }
        )
        let result = try await executeImage(artifactMode: false, toolCallId: api.callId, params: params, onUpdate: nil,
                                            host: host, signal: cancellation.token, environment: environment)
        return ToolExecutionResult(
            output: result.content,
            structuredOutput: try result.structuredContent.map { try durableJSON(fromFoundation: $0.value) },
            isError: result.isError,
            details: try result.details.map { try durableJSON(fromFoundation: $0.value) }
        )
    }
    return PiSwiftDurable.Extension(name: "codex-image-gen", tools: [tool])
}

/// The most recent image sources of the conversation, oldest first. It reads
/// pages from the newest entry back, and stops when it has enough images.
private func durableImageSources(runtime: TaskRuntime, context: ChordContext) async throws -> [ConversationImageSource] {
    var sources: [ConversationImageSource] = []
    var imageCount = 0
    var cursor: Cursor?
    var pages = 0
    repeat {
        let page = try await runtime.entries(ConversationEntryQuery(order: .descending), limit: 50, cursor: cursor,
                                             context: context)
        for entry in page.items {
            for blocks in durableEntryBlocks(entry).reversed() {
                sources.append(.blocks(blocks))
                imageCount += blocks.filter { if case .image = $0 { return true } else { return false } }.count
            }
        }
        cursor = page.next
        pages += 1
    } while cursor != nil && imageCount < codexMaxEditImages && pages < 20
    return sources.reversed()
}

/// The content blocks of the user and tool-result messages in one entry.
func durableEntryBlocks(_ entry: EntryRecord) -> [[ContentBlock]] {
    (entry.model ?? []).compactMap { value -> [ContentBlock]? in
        guard let object = value.objectValue,
              let dictionary = try? foundationJSON(from: .object(object)) as? [String: Any],
              let message = messageFromJSONObject(dictionary) else { return nil }
        switch message {
        case .user(let user):
            if case .blocks(let blocks) = user.content { return blocks }
            return nil
        case .toolResult(let result):
            return result.content
        default:
            return nil
        }
    }
}

/// A cancellation token that follows the durable abort signals.
private struct DurableCancellation {
    let token = CancellationToken()
    private let signals: [AbortSignal]
    private let registrations: [AbortListenerRegistration]

    init(context: ChordContext, runtimeSignal: AbortSignal?) {
        let token = self.token
        signals = [context.abortSignal, runtimeSignal].compactMap { $0 }
        registrations = signals.map { signal in
            signal.addAbortListener { _ in token.cancel() }
        }
        if signals.contains(where: { $0.aborted }) {
            token.cancel()
        }
    }

    func remove() {
        for (signal, registration) in zip(signals, registrations) {
            signal.removeAbortListener(registration)
        }
    }
}
