import CryptoKit
import Foundation
import PiSwiftAI
import PiSwiftAgent
import PiSwiftCodingAgent

// Swift port of pi-extras `pi-codex-image-gen` (extensions/index.ts).
//
// The extension registers its image tools only while the session model uses
// the ChatGPT subscription provider (`openai-codex`). It then uses the
// session's own OAuth credentials and model to call the Codex Responses
// backend with the native `image_generation` tool. The backend selects the
// image model.

let codexMaxPromptChars = 32_000
private let generationTimeout: TimeInterval = 300

public enum CodexImageGen {
    public static let inlineToolName = "codex_generate_image"
    public static let artifactToolName = "codex_generate_image_artifact"
    public static let listToolName = "codex_list_image_artifacts"
    public static var toolNames: [String] { [inlineToolName, artifactToolName, listToolName] }

    /// In-process extension descriptor for `inlineExtensions`.
    public static var inlineExtension: InlineExtension {
        InlineExtension(name: "codex-image-gen", factory: { register($0) })
    }

    public static func register(_ pi: HookAPI) {
        registerCodexImageGen(pi, environment: CodexImageGenEnvironment())
    }
}

/// Test seams for the network and the admission queue.
struct CodexImageGenEnvironment: Sendable {
    var httpClient: any ProviderHTTPClient = NoRedirectHTTPClient()
    var admission: ImageAdmission = .shared
    var agentDir: @Sendable () -> String = { getAgentDir() }
    var artifactRoot: @Sendable () -> String = { NSTemporaryDirectory() }
    var random: @Sendable () -> Double = { Double.random(in: 0..<1) }
}

// MARK: - Registration

private final class ExtensionState: Sendable {
    let lifetime = LockedState(CancellationToken())
    let registered = LockedState(false)
}

func registerCodexImageGen(_ pi: HookAPI, environment: CodexImageGenEnvironment) {
    let state = ExtensionState()
    let tools = makeCodexImageTools(pi: pi, state: state, environment: environment)

    // Register the tools only for a ChatGPT session; remove them after a switch
    // to another provider. Codemode tools stay callable while registered, so
    // registration, not the active-tool list, is the gate.
    @Sendable func sync(_ model: Model?) {
        let enable = isChatGPTModel(model)
        let change = state.registered.withLock { registered -> Bool in
            guard registered != enable else { return false }
            registered = enable
            return true
        }
        guard change else { return }
        if enable {
            for tool in tools { pi.registerTool(tool) }
        } else {
            for tool in tools { pi.unregisterTool(tool.name) }
        }
    }

    pi.on("session_start") { (_: SessionStartEvent, ctx: HookContext) -> Any? in
        state.lifetime.withLock { $0 = CancellationToken() }
        sync(ctx.model)
        return nil
    }
    pi.on("model_select") { (event: ModelSelectEvent, _: HookContext) -> Any? in
        sync(event.model)
        return nil
    }
    pi.on("session_shutdown") { (_: SessionShutdownEvent, _: HookContext) -> Any? in
        state.lifetime.withLock { $0 }.cancel()
        return nil
    }

    pi.registerCommand("image-artifacts",
                       description: "List the last 20 generated original artifact paths on the current branch (no generation).") { _, ctx in
        let records = branchArtifacts(ctx.sessionManager.getBranch()).suffix(20)
        let text = records.isEmpty ? "No image artifacts recorded on this branch."
            : records.map { "\($0.artifact.path) (\($0.artifact.mimeType), \($0.artifact.byteCount) bytes)" }.joined(separator: "\n")
            + "\nTemporary originals may be removed by user/OS cleanup. Copy needed assets to persistent storage."
        pi.sendMessage(HookMessageInput(customType: "codex-image-artifact-list", content: .text(text), display: true))
    }
}

// MARK: - Schemas and guidelines

private let outputFormats = OutputFormat.allCases.map(\.rawValue)
private let backgrounds = ["auto", "opaque", "transparent"]

private func stringEnum(_ values: [String], description: String? = nil) -> [String: Any] {
    var schema: [String: Any] = ["type": "string", "enum": values]
    if let description { schema["description"] = description }
    return schema
}

private func toolParameters() -> [String: AnyCodable] {
    [
        "type": AnyCodable("object"),
        "properties": AnyCodable([
            "prompt": ["type": "string", "minLength": 1, "maxLength": codexMaxPromptChars,
                       "description": "The image prompt. Be specific about subject, composition, style, text, and constraints."],
            "outputFormat": stringEnum(outputFormats),
            "background": stringEnum(backgrounds, description: "Native background control. Use transparent for cutouts and preserve existing transparency during edits. Transparent output requires PNG or WebP."),
            "save": stringEnum(SaveMode.allCases.map(\.rawValue), description: "Persistent copy location. Defaults to global (<agentDir>/generated-images/<session>/)."),
            "saveDir": ["type": "string", "description": "Directory to save the image when save=custom. Relative paths resolve under the current workspace."],
            "referencedImagePaths": ["type": "array", "items": ["type": "string"], "maxItems": codexMaxEditImages,
                                     "description": "Up to five local image paths to edit. Relative paths resolve under the current workspace."],
            "numLastImagesToInclude": ["type": "integer", "minimum": 1, "maximum": codexMaxEditImages,
                                       "description": "Use the most recent one to five images from the current conversation as edit inputs."],
        ] as [String: Any]),
        "required": AnyCodable(["prompt"]),
    ]
}

private func artifactSchema() -> [String: Any] {
    ["type": "object", "properties": [
        "path": ["type": "string"],
        "mimeType": stringEnum(artifactMimeTypeList),
        "byteCount": ["type": "integer", "minimum": 1, "maximum": codexMaxImageBytes],
    ] as [String: Any], "required": ["path", "mimeType", "byteCount"]]
}

private let artifactMimeTypeList = ["image/png", "image/jpeg", "image/webp"]

private func artifactOutputSchema() -> [String: AnyCodable] {
    let optionalString: [String: Any] = ["type": "string"]
    return [
        "type": AnyCodable("object"),
        "properties": AnyCodable([
            "summary": optionalString,
            "artifact": artifactSchema(),
            "savedPath": optionalString,
            "saveWarning": optionalString,
            "generationDurationMs": ["type": "integer"],
            "routingProvider": optionalString,
            "routingModel": optionalString,
            "responseId": optionalString,
            "imageGenerationId": optionalString,
            "reportedImage": ["type": "object", "properties": [
                "model": optionalString, "size": optionalString, "quality": optionalString,
                "background": optionalString, "outputFormat": optionalString,
            ] as [String: Any]],
            "requestedImage": ["type": "object", "properties": [
                "outputFormat": stringEnum(outputFormats), "background": stringEnum(backgrounds),
            ] as [String: Any], "required": ["outputFormat"]],
            "imageWarning": optionalString,
            "requestId": optionalString,
            "imagegenRequestId": optionalString,
        ] as [String: Any]),
        "required": AnyCodable(["summary", "artifact"]),
    ]
}

private func listOutputSchema() -> [String: AnyCodable] {
    [
        "type": AnyCodable("object"),
        "properties": AnyCodable([
            "artifacts": ["type": "array", "items": ["type": "object", "properties": [
                "artifact": artifactSchema(), "toolCallId": ["type": "string"],
                "availability": stringEnum(["present", "missing", "unavailable"]),
            ] as [String: Any]]] as [String: Any],
            "total": ["type": "integer"],
            "revision": ["type": "string"],
            "nextOffset": ["type": "integer"],
        ] as [String: Any]),
        "required": AnyCodable(["artifacts", "total", "revision"]),
    ]
}

let codexImageGuidelines = [
    "Generate or edit images only on a clear user request; each call consumes ChatGPT subscription image quota.",
    "The backend selects the image model; the current ChatGPT session model only routes the request. Do not claim a specific served image model.",
    "Output metadata is backend-reported. Inspect the image for dimensions and transparency; prompt requests are not guarantees.",
    "Use background=transparent for cutouts (PNG or WebP only); preserve existing transparency when editing. Inspect unseen local references with read before editing.",
    "No GIF, SVG, mask, exact size or quality, or image-model selector is available.",
    "Preserve completed originals on warnings; never regenerate automatically.",
    "Do not automatically repeat quota, connection, deadline, incomplete-stream, or artifact-storage failures. Quota may already have been consumed.",
    "For several assets, issue one call per asset.",
]

private let toolDescription = "Generate or edit an image through the ChatGPT subscription (Codex backend), with native background control. Available only in a ChatGPT (openai-codex) session; it uses that session's login and model. The backend selects the image model. Accepts up to five local or recent conversation images (20 MiB each, 50 MiB total). Deadline: 5 minutes; output image limit: 32 MiB; backend text is limited to 4,000 characters."

private let imagesNamespace = ToolNamespace(
    name: "codex_images",
    description: "Quota-consuming image generation and private original artifacts.",
    instructions: "Generate only on an explicit image request. codex_generate_image is model-only and returns an inline image. Scripts use codex_generate_image_artifact and receive metadata with artifact.path, never base64; read that path and use image(block) only for requested display. After later script failure use codex_list_image_artifacts({}) to recover current-branch metadata without quota use, then read only a selected returned path. Inspect availability; present is not proof of original contents. Continue with revision/nextOffset. Completed originals survive script failures/reload; save=none still creates temporary originals. Two active/eight queued operations per account share a five-minute total deadline. Calls consume quota and may write files, so do not automatically retry failures. Await each artifact before using it for an edit. Reported image metadata is not measured pixel properties or verified charges; backend usage counters are informational."
)

private func makeCodexImageTools(pi: HookAPI, state: ExtensionState, environment: CodexImageGenEnvironment) -> [CustomTool] {
    let annotations = ToolAnnotations(readOnlyHint: false, destructiveHint: false, idempotentHint: false, openWorldHint: true)
    let inline = CustomTool(
        name: CodexImageGen.inlineToolName,
        label: "Codex Image",
        description: "\(toolDescription) Direct model calls only; returns an inline image. For codemode workflows use codex_generate_image_artifact.",
        parameters: toolParameters(),
        execute: { id, params, onUpdate, ctx, signal in
            try await executeImage(artifactMode: false, toolCallId: id, params: params, onUpdate: onUpdate, ctx: ctx,
                                   signal: signal, pi: pi, state: state, environment: environment)
        },
        promptGuidelines: codexImageGuidelines,
        promptSnippet: "Generate or edit bitmap images via the ChatGPT subscription image_generation tool.",
        exposure: .modelOnly, namespace: imagesNamespace, annotations: annotations, executionMode: .parallel
    )
    let artifact = CustomTool(
        name: CodexImageGen.artifactToolName,
        label: "Codex Image Artifact",
        description: "\(toolDescription) Returns structured metadata and a private temporary original path, never image bytes. save=none disables persistent copies, not temporary storage. Completed artifacts survive script errors and reload until user/OS cleanup. Read artifact.path and call image(block) only for explicit display. Recover current-branch paths with /image-artifacts.",
        parameters: toolParameters(),
        execute: { id, params, onUpdate, ctx, signal in
            try await executeImage(artifactMode: true, toolCallId: id, params: params, onUpdate: onUpdate, ctx: ctx,
                                   signal: signal, pi: pi, state: state, environment: environment)
        },
        promptGuidelines: codexImageGuidelines + [
            "For display read result.artifact.path and call image(block) only if read returns an image block; otherwise report its text note. Do not print image bytes.",
            "For chained edits pass result.artifact.path through referencedImagePaths; each edit consumes quota.",
        ],
        outputSchema: artifactOutputSchema(),
        exposure: .codemode, namespace: imagesNamespace, annotations: annotations, executionMode: .parallel
    )
    let list = CustomTool(
        name: CodexImageGen.listToolName,
        label: "List image artifacts",
        description: "Recover bounded current-branch image artifact metadata without generation or quota use. No bytes. File availability is not proof of original contents.",
        parameters: [
            "type": AnyCodable("object"),
            "properties": AnyCodable([
                "offset": ["type": "integer", "minimum": 0],
                "limit": ["type": "integer", "minimum": 1, "maximum": 20],
                "revision": ["type": "string", "maxLength": 64],
            ] as [String: Any]),
            "additionalProperties": AnyCodable(false),
        ],
        execute: { _, params, _, ctx, signal in
            try listArtifacts(params: params, entries: ctx.sessionManager.getBranch(), signal: signal)
        },
        outputSchema: listOutputSchema(),
        namespace: imagesNamespace,
        annotations: ToolAnnotations(readOnlyHint: true, destructiveHint: false, openWorldHint: false),
        executionMode: .parallel
    )
    return [inline, artifact, list]
}

// MARK: - Parameters

struct ImageToolParams: Sendable {
    var prompt: String
    var outputFormat: OutputFormat
    var background: String?
    var save: String?
    var saveDir: String?
    var referencedImagePaths: [String]
    var numLastImagesToInclude: Int?

    /// Validate and snapshot the arguments before any wait.
    init(_ params: [String: AnyCodable]) throws {
        guard let prompt = params["prompt"]?.value as? String,
              !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, prompt.count <= codexMaxPromptChars else {
            throw CodexImageError("Image prompt must contain 1 to 32,000 characters.")
        }
        self.prompt = prompt
        let format = optionalString(params["outputFormat"]) ?? OutputFormat.png.rawValue
        guard let outputFormat = OutputFormat(rawValue: format) else { throw CodexImageError("Unsupported image output format.") }
        self.outputFormat = outputFormat
        background = optionalString(params["background"])
        if let background, !backgrounds.contains(background) { throw CodexImageError("Unsupported image background.") }
        if background == "transparent" && outputFormat == .jpeg {
            throw CodexImageError("Transparent output requires PNG or WebP. No generation request was made.")
        }
        save = optionalString(params["save"])
        saveDir = optionalString(params["saveDir"])
        if let raw = params["referencedImagePaths"]?.value, !(raw is NSNull) {
            guard let paths = raw as? [Any], paths.allSatisfy({ $0 is String }) else {
                throw CodexImageError("referencedImagePaths must be an array of strings.")
            }
            referencedImagePaths = paths.compactMap { $0 as? String }
        } else {
            referencedImagePaths = []
        }
        if let raw = params["numLastImagesToInclude"]?.value, !(raw is NSNull) {
            guard let count = integer(raw) else { throw CodexImageError("numLastImagesToInclude must be an integer.") }
            numLastImagesToInclude = count
        }
    }
}

private func optionalString(_ value: AnyCodable?) -> String? {
    guard let value = value?.value, !(value is NSNull) else { return nil }
    return value as? String
}

// MARK: - Generation

private func conversationSources(_ entries: [SessionEntry]) -> [ConversationImageSource] {
    let completed = Set(entries.compactMap { entry -> String? in
        guard case .custom(let custom) = entry, custom.customType == artifactEntryType else { return nil }
        return artifactRecord(custom.data?.value)?.artifact.path
    })
    var sources: [ConversationImageSource] = []
    for entry in entries {
        switch entry {
        case .message(let message):
            sources.append(.blocks(conversationBlocks(message.message)))
        case .customMessage(let message):
            if case .blocks(let blocks) = message.content { sources.append(.blocks(blocks)) }
        case .custom(let custom) where custom.customType == artifactEntryType:
            if let record = artifactRecord(custom.data?.value) {
                sources.append(.artifact(path: record.artifact.path, mimeType: record.artifact.mimeType))
            }
        case .custom(let custom) where custom.customType == reservationEntryType:
            // Normal completions also have a session entry. Prefer that later
            // entry and avoid counting the same original twice.
            if let record = artifactReservation(custom.data?.value).flatMap(readArtifactManifest),
               !completed.contains(record.artifact.path) {
                sources.append(.artifact(path: record.artifact.path, mimeType: record.artifact.mimeType))
            }
        default:
            break
        }
    }
    return sources
}

private func textResult(_ text: String, details: [String: Any]) -> AgentToolResult {
    AgentToolResult(content: [.text(TextContent(text: text))], details: AnyCodable(details))
}

/// Publish the recovery manifest, then attach the record to the branch that
/// started the call. A late result never attaches to another branch or session.
private func recordOriginal(_ artifact: ImageArtifact, toolCallId: String, reservation: ArtifactReservation,
                            ctx: CustomToolContext, sessionId: String, originEntryId: String?, pi: HookAPI) -> String? {
    let record = ArtifactRecord(artifact: artifact, toolCallId: String(toolCallId.prefix(256)))
    var manifestPublished = false
    do {
        try reservation.publish(record)
        manifestPublished = true
    } catch {
        // A completed original must survive a metadata-storage failure.
    }
    if ctx.sessionManager.getSessionId() == sessionId, let originEntryId,
       ctx.sessionManager.getBranch().contains(where: { $0.id == originEntryId }) {
        pi.appendEntry(artifactEntryType, record.dictionary)
        return nil
    }
    if manifestPublished { return nil }
    return "Artifact recovery metadata could not be persisted. Recover the image from \(artifact.path). No generation retry was made."
}

private func executeImage(
    artifactMode: Bool, toolCallId: String, params rawParams: [String: AnyCodable], onUpdate: AgentToolUpdateCallback?,
    ctx: CustomToolContext, signal: CancellationToken?, pi: HookAPI, state: ExtensionState,
    environment: CodexImageGenEnvironment
) async throws -> AgentToolResult {
    let scope = AbortScope(parents: [signal, state.lifetime.withLock { $0 }], timeout: generationTimeout)
    var reservation: ArtifactReservation?
    var ticket: AdmissionTicket?
    var dispatched = false
    var originEntryId: String?

    func cleanUp() async {
        // Clean only reservations made by this call, never completed originals.
        reservation?.dispose()
        await ticket?.release()
        scope.dispose()
    }

    do {
        let params = try ImageToolParams(rawParams)
        guard isChatGPTModel(ctx.model) else {
            throw CodexImageError("Image generation needs a ChatGPT (\(codexImageChatGPTProvider)) session. No generation request was made.")
        }
        let cwd = ctx.sessionManager.getCwd()
        let sessionId = ctx.sessionManager.getSessionId()
        let saveConfig = try resolveSaveConfig(save: params.save, saveDir: params.saveDir, cwd: cwd,
                                               sessionId: sessionId, agentDir: environment.agentDir())
        let recent = params.numLastImagesToInclude.map {
            selectRecentImages(conversationSources(ctx.sessionManager.getBranch()), count: $0)
        } ?? []
        try scope.throwIfAborted()

        let model = ctx.model
        let registry = ctx.modelRegistry
        let token = scope.token
        let auth = try await scope.run { try await resolveCodexImageAuth(model: model, registry: registry, signal: token) }
        ticket = try await environment.admission.admit(account: auth.accountId, token: scope.token)
        try scope.throwIfAborted()
        // Queued calls retain approved selectors, not decoded references.
        // Load bytes only while holding an admission slot.
        let inputImages = try resolveInputImages(paths: params.referencedImagePaths, count: params.numLastImagesToInclude,
                                                 cwd: cwd, recent: recent)
        try scope.throwIfAborted()

        if artifactMode {
            do {
                reservation = try ArtifactReservation.reserve(fileExtension: params.outputFormat.fileExtension,
                                                              root: environment.artifactRoot())
            } catch {
                throw CodexImageError("Image artifact storage is unavailable. No generation request was made.")
            }
            try scope.throwIfAborted()
            // Attach the recovery anchor before quota or network work.
            pi.appendEntry(reservationEntryType, ArtifactReservationRecord(
                path: reservation!.path, mimeType: params.outputFormat.mimeType,
                toolCallId: String(toolCallId.prefix(256))).dictionary)
            originEntryId = ctx.sessionManager.getLeafId()
        }

        let provider = codexImageChatGPTProvider
        let routing = "\(provider)/\(auth.routingModel)"
        onUpdate?(textResult("Requesting image \(inputImages.isEmpty ? "generation" : "edit") through \(routing)...", details: [
            "provider": provider, "model": auth.routingModel, "outputFormat": params.outputFormat.rawValue,
            "inputImageCount": inputImages.count,
        ]))

        let started = Date()
        try scope.throwIfAborted()
        dispatched = true
        let body = buildCodexRequestBody(prompt: params.prompt, background: params.background, model: auth.routingModel,
                                         outputFormat: params.outputFormat, sessionId: sessionId, inputImages: inputImages)
        let payload = try JSONSerialization.data(withJSONObject: body)
        let parsed = try await requestCodexImage(payload: payload, auth: auth, client: environment.httpClient, scope: scope,
                                                 random: environment.random) { stage in
            onUpdate?(textResult("Codex image stage: \(stage).", details: ["provider": provider, "model": auth.routingModel, "stage": stage]))
        }
        guard let image = parsed.image else {
            throw CodexImageError(parsed.text.isEmpty ? "Codex did not return an image."
                                  : "Codex did not return an image. Response text: \(parsed.text)")
        }

        let imageBytes = try decodeImageData(image.result)
        let actualFormat = try detectOutputFormat(imageBytes)
        let reported = image.reported
        var requestedImage: [String: Any] = ["outputFormat": params.outputFormat.rawValue]
        if let background = params.background { requestedImage["background"] = background }
        var savedPath: String?
        var attemptedPath: String?
        var saveWarning: String?
        var artifact: ImageArtifact?
        var recoveryWarning: String?

        if let reservation {
            // Attempt the requested persistent copy below, never generation again.
            artifact = try? reservation.commit(imageBytes, mimeType: actualFormat.mimeType)
            // Persist before callbacks, persistent saves, or parent script output.
            if let artifact {
                recoveryWarning = recordOriginal(artifact, toolCallId: toolCallId, reservation: reservation, ctx: ctx,
                                                 sessionId: sessionId, originEntryId: originEntryId, pi: pi)
            }
        }
        if saveConfig.mode != .none, let outputDir = saveConfig.outputDir {
            attemptedPath = imagePath(format: actualFormat, outputDir: outputDir, imageCallId: image.id)
            do {
                savedPath = try await saveImage(imageBytes, format: actualFormat, outputDir: outputDir, imageCallId: image.id)
            } catch {
                let reason = sanitizeText(error.localizedDescription).prefix(500)
                saveWarning = "Image generation succeeded, but the image could not be saved to disk: \(reason)"
            }
        }
        if artifactMode && artifact == nil {
            guard let savedPath, let reservation else {
                throw CodexImageError("Image generation succeeded, but artifact storage failed and no usable file could be saved. Image quota may have been consumed. No automatic retry was made.")
            }
            let fallback = ImageArtifact(path: savedPath, mimeType: actualFormat.mimeType, byteCount: imageBytes.count)
            artifact = fallback
            recoveryWarning = recordOriginal(fallback, toolCallId: toolCallId, reservation: reservation, ctx: ctx,
                                             sessionId: sessionId, originEntryId: originEntryId, pi: pi)
            saveWarning = "Temporary artifact storage failed; recover the original from the persistent saved path. No generation retry was made."
        }
        let combinedSaveWarning = [saveWarning, recoveryWarning].compactMap { $0 }.joined(separator: " ")
        saveWarning = combinedSaveWarning.isEmpty ? nil : combinedSaveWarning

        let imageWarnings = [
            actualFormat != params.outputFormat
                ? "Requested \(params.outputFormat.rawValue), but Codex returned \(actualFormat.rawValue). The original was preserved without conversion." : nil,
            reported.outputFormat.map { $0 != actualFormat.rawValue } == true
                ? "Backend-reported format differs from the returned file signature." : nil,
        ].compactMap { $0 }
        let imageWarning = imageWarnings.isEmpty ? nil : imageWarnings.joined(separator: " ")

        let summary = [
            "Generated image via \(routing) using the backend-selected image model.",
            "Status: \(image.status).",
            reported.size.map { "Backend-reported size: \($0)." },
            reported.quality.map { "Backend-reported quality: \($0)." },
            reported.background.map { "Backend-reported background: \($0)." },
            image.revisedPrompt.map { "Revised prompt: \($0)" },
            artifact.map { "Original image artifact: \($0.path)." },
            savedPath.map { "Saved image to: \($0)" } ?? (artifactMode ? "No persistent image copy was saved." : "Image was not saved to disk."),
            saveWarning.map { "Warning: \($0)" },
            imageWarning.map { "Warning: \($0)" },
        ].compactMap { $0 }.joined(separator: " ")

        if savedPath != nil || artifact != nil {
            var details: [String: Any] = ["provider": provider, "model": auth.routingModel, "byteCount": imageBytes.count]
            if let savedPath { details["savedPath"] = savedPath }
            if let artifact { details["artifact"] = artifact.dictionary }
            onUpdate?(textResult(artifact.map { "Original image artifact: \($0.path)." } ?? "Image saved to \(savedPath ?? "").",
                                 details: details))
        }

        let durationMs = Int(Date().timeIntervalSince(started) * 1000)
        var details: [String: Any] = [
            "provider": provider, "model": auth.routingModel,
            "backendImageModel": reported.model ?? "unknown",
            "reportedImage": reported.dictionary,
            "transport": "codex-responses",
            "requestedImage": requestedImage,
            "generationDurationMs": durationMs,
            "byteCount": imageBytes.count,
            "outputFormat": actualFormat.rawValue,
            "saveMode": saveConfig.mode.rawValue,
            "inputImageCount": inputImages.count,
        ]
        let optionalDetails: [String: Any?] = [
            "imageWarning": imageWarning, "requestId": parsed.requestId, "imagegenRequestId": parsed.imagegenRequestId,
            "savedPath": savedPath, "artifact": artifact?.dictionary, "attemptedPath": attemptedPath,
            "saveWarning": saveWarning, "responseId": parsed.responseId, "imageGenerationId": image.id,
            "revisedPrompt": image.revisedPrompt, "usage": parsed.usage?.value,
        ]
        for case let (key, value?) in optionalDetails { details[key] = value }

        var structured: AnyCodable?
        if let artifact {
            var output: [String: Any] = [
                "summary": summary, "artifact": artifact.dictionary, "generationDurationMs": durationMs,
                "routingProvider": provider, "routingModel": auth.routingModel, "requestedImage": requestedImage,
                "reportedImage": reported.dictionary,
            ]
            let optionalOutput: [String: Any?] = [
                "imageWarning": imageWarning, "requestId": parsed.requestId, "imagegenRequestId": parsed.imagegenRequestId,
                "responseId": parsed.responseId, "imageGenerationId": image.id, "savedPath": savedPath, "saveWarning": saveWarning,
            ]
            for case let (key, value?) in optionalOutput { output[key] = value }
            structured = AnyCodable(output)
        }

        var content: [ContentBlock] = [.text(TextContent(text: summary))]
        if !artifactMode { content.append(.image(ImageContent(data: image.result, mimeType: actualFormat.mimeType))) }
        await cleanUp()
        return AgentToolResult(content: content, details: AnyCodable(details), structuredContent: structured)
    } catch {
        let reason = scope.abortReason
        await cleanUp()
        if let reason {
            let text = reason == .timedOut ? "timed out" : "was aborted"
            throw CodexImageError(dispatched
                ? "Image generation \(text) after dispatch. Image quota may have been consumed. No automatic retry was made."
                : "Image generation \(text) before dispatch. No generation request was made.")
        }
        throw error
    }
}

// MARK: - Listing

func listArtifacts(params: [String: AnyCodable], entries: [SessionEntry], signal: CancellationToken?) throws -> AgentToolResult {
    let offset = params["offset"].flatMap { integer($0.value) } ?? 0
    let limit = params["limit"].flatMap { integer($0.value) } ?? 8
    let revision = optionalString(params["revision"])
    guard offset >= 0, (1...20).contains(limit) else { throw CodexImageError("Invalid artifact list range.") }
    let records = branchArtifacts(entries)
    if signal?.isCancelled == true { throw CancellationError() }
    let digestInput = try JSONSerialization.data(withJSONObject: records.map(\.dictionary), options: [.sortedKeys])
    let current = SHA256.hash(data: digestInput).map { String(format: "%02x", $0) }.joined()
    if (offset > 0 && revision == nil) || (revision != nil && revision != current) {
        throw CodexImageError("Artifact list changed or revision missing; restart at offset 0.")
    }
    var artifacts: [[String: Any]] = []
    var bytes = 512
    for record in records.dropFirst(offset).prefix(limit) {
        if signal?.isCancelled == true { throw CancellationError() }
        var info = stat()
        let availability: String
        if lstat(record.artifact.path, &info) == 0 {
            availability = (info.st_mode & S_IFMT) == S_IFREG ? "present" : "unavailable"
        } else {
            availability = errno == ENOENT ? "missing" : "unavailable"
        }
        let item: [String: Any] = ["artifact": record.artifact.dictionary, "toolCallId": record.toolCallId, "availability": availability]
        let size = (try? JSONSerialization.data(withJSONObject: item).count) ?? 0
        if bytes + size > 50_000 { break }
        bytes += size
        artifacts.append(item)
    }
    let next = offset + artifacts.count
    var data: [String: Any] = ["artifacts": artifacts, "total": records.count, "revision": current]
    if next < records.count { data["nextOffset"] = next }
    let json = (try? JSONSerialization.data(withJSONObject: data, options: [.sortedKeys])).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    return AgentToolResult(content: [.text(TextContent(text: json))], details: AnyCodable(data), structuredContent: AnyCodable(data))
}
