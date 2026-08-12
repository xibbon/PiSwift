import Foundation

private let base64SignaturePattern = "^[A-Za-z0-9+/]+={0,2}$"

func isThinkingPart(thought: Bool?) -> Bool {
    thought == true
}

func retainThoughtSignature(existing: String?, incoming: String?) -> String? {
    if let incoming, !incoming.isEmpty {
        return incoming
    }
    return existing
}

private func isValidThoughtSignature(_ signature: String?) -> Bool {
    guard let signature, !signature.isEmpty else { return false }
    if signature.count % 4 != 0 {
        return false
    }
    return signature.range(of: base64SignaturePattern, options: .regularExpression) != nil
}

private func resolveThoughtSignature(isSameProviderAndModel: Bool, signature: String?) -> String? {
    guard isSameProviderAndModel, isValidThoughtSignature(signature) else { return nil }
    return signature
}

func requiresToolCallId(_ modelId: String) -> Bool {
    modelId.hasPrefix("claude-") || modelId.hasPrefix("gpt-oss-")
}

func convertGoogleMessages(model: Model, context: Context) -> [[String: Any]] {
    var contents: [[String: Any]] = []

    let normalizeToolCallId: @Sendable (String, Model, AssistantMessage) -> String = { id, model, _ in
        guard requiresToolCallId(model.id) else { return id }
        let sanitized = id.replacingOccurrences(of: "[^a-zA-Z0-9_-]", with: "_", options: .regularExpression)
        return String(sanitized.prefix(64))
    }

    let transformed = transformMessages(context.messages, model: model, normalizeToolCallId: normalizeToolCallId)

    for msg in transformed {
        switch msg {
        case .user(let user):
            switch user.content {
            case .text(let text):
                contents.append([
                    "role": "user",
                    "parts": [
                        ["text": sanitizeSurrogates(text)]
                    ],
                ])
            case .blocks(let blocks):
                let parts: [[String: Any]] = blocks.compactMap { block in
                    switch block {
                    case .text(let textContent):
                        return ["text": sanitizeSurrogates(textContent.text)]
                    case .image(let imageContent):
                        return [
                            "inlineData": [
                                "mimeType": imageContent.mimeType,
                                "data": imageContent.data,
                            ],
                        ]
                    default:
                        return nil
                    }
                }
                let filtered = model.input.contains(.image) ? parts : parts.filter { $0["inlineData"] == nil }
                if !filtered.isEmpty {
                    contents.append([
                        "role": "user",
                        "parts": filtered,
                    ])
                }
            }
        case .assistant(let assistant):
            var parts: [[String: Any]] = []
            let isSameProviderAndModel = assistant.provider == model.provider && assistant.model == model.id

            for block in assistant.content {
                switch block {
                case .text(let textBlock):
                    let text = textBlock.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if text.isEmpty { continue }
                    var part: [String: Any] = ["text": sanitizeSurrogates(textBlock.text)]
                    if let signature = resolveThoughtSignature(isSameProviderAndModel: isSameProviderAndModel, signature: textBlock.textSignature) {
                        part["thoughtSignature"] = signature
                    }
                    parts.append(part)
                case .thinking(let thinking):
                    let text = thinking.thinking.trimmingCharacters(in: .whitespacesAndNewlines)
                    if text.isEmpty { continue }
                    if isSameProviderAndModel {
                        var part: [String: Any] = [
                            "thought": true,
                            "text": sanitizeSurrogates(thinking.thinking),
                        ]
                        if let signature = resolveThoughtSignature(isSameProviderAndModel: isSameProviderAndModel, signature: thinking.thinkingSignature) {
                            part["thoughtSignature"] = signature
                        }
                        parts.append(part)
                    } else {
                        parts.append(["text": sanitizeSurrogates(thinking.thinking)])
                    }
                case .toolCall(let toolCall):
                    let thoughtSignature = resolveThoughtSignature(isSameProviderAndModel: isSameProviderAndModel, signature: toolCall.thoughtSignature)
                    let isGemini3 = model.id.lowercased().contains("gemini-3")
                    // For Gemini 3 unsigned tool calls, use skip_thought_signature_validator sentinel
                    // to tell the API to skip signature validation instead of rejecting the function call
                    let effectiveSignature = thoughtSignature ?? (isGemini3 ? "skip_thought_signature_validator" : nil)
                    if effectiveSignature == nil && isGemini3 {
                        // No signature and not Gemini 3 — shouldn't happen but fallback to text
                        let argsData = (try? JSONSerialization.data(withJSONObject: toolCall.arguments.mapValues { $0.jsonValue }, options: [.prettyPrinted])) ?? Data()
                        let argsStr = String(data: argsData, encoding: .utf8) ?? "{}"
                        parts.append([
                            "text": "[Historical context: a different model called tool \"\(toolCall.name)\" with arguments: \(argsStr). Do not mimic this format - use proper function calling.]",
                        ])
                    } else {
                        var functionCall: [String: Any] = [
                            "name": toolCall.name,
                            "args": toolCall.arguments.mapValues { $0.jsonValue },
                        ]
                        if requiresToolCallId(model.id) {
                            functionCall["id"] = toolCall.id
                        }
                        var part: [String: Any] = ["functionCall": functionCall]
                        if let effectiveSignature {
                            part["thoughtSignature"] = effectiveSignature
                        }
                        parts.append(part)
                    }
                default:
                    break
                }
            }

            if !parts.isEmpty {
                contents.append([
                    "role": "model",
                    "parts": parts,
                ])
            }
        case .toolResult(let toolResult):
            let textResult = toolResult.content.compactMap { block -> String? in
                if case .text(let textBlock) = block { return textBlock.text }
                return nil
            }.joined(separator: "\n")

            let imageContent: [ImageContent] = model.input.contains(.image) ? toolResult.content.compactMap {
                if case .image(let image) = $0 { return image }
                return nil
            } : []

            let hasText = !textResult.isEmpty
            let hasImages = !imageContent.isEmpty
            // Gemini 3+ and Antigravity (Claude behind Gemini) support multimodal function responses
            let supportsMultimodalFunctionResponse = model.id.contains("gemini-3") || model.provider == KnownProvider.googleAntigravity.rawValue

            let responseValue: String
            if hasText {
                responseValue = sanitizeSurrogates(textResult)
            } else if hasImages {
                responseValue = "(see attached image)"
            } else {
                responseValue = ""
            }

            let imageParts: [[String: Any]] = imageContent.map { image in
                [
                    "inlineData": [
                        "mimeType": image.mimeType,
                        "data": image.data,
                    ],
                ]
            }

            var functionResponse: [String: Any] = [
                "name": toolResult.toolName,
                "response": toolResult.isError ? ["error": responseValue] : ["output": responseValue],
            ]
            if hasImages && supportsMultimodalFunctionResponse {
                functionResponse["parts"] = imageParts
            }
            if requiresToolCallId(model.id) {
                functionResponse["id"] = toolResult.toolCallId
            }

            let functionResponsePart: [String: Any] = ["functionResponse": functionResponse]

            if var last = contents.last, (last["role"] as? String) == "user",
               var lastParts = last["parts"] as? [[String: Any]],
               lastParts.contains(where: { $0["functionResponse"] != nil }) {
                lastParts.append(functionResponsePart)
                last["parts"] = lastParts
                contents[contents.count - 1] = last
            } else {
                contents.append([
                    "role": "user",
                    "parts": [functionResponsePart],
                ])
            }

            if hasImages && !supportsMultimodalFunctionResponse {
                contents.append([
                    "role": "user",
                    "parts": [["text": "Tool result image:"]] + imageParts,
                ])
            }
        }
    }

    return contents
}

/// v0.68.0: strip JSON Schema meta-declaration keys before passing OpenAPI parameters to Cloud
/// Code Assist / Gemini. Provider rejects `$schema`, `$defs`, `definitions` etc. with validation
/// errors for tool-enabled requests.
private let jsonSchemaMetaKeys: Set<String> = [
    "$schema", "$defs", "definitions", "$id", "$ref", "$comment"
]

private func stripJsonSchemaMeta(_ value: Any) -> Any {
    if let dict = value as? [String: Any] {
        var cleaned: [String: Any] = [:]
        for (k, v) in dict where !jsonSchemaMetaKeys.contains(k) {
            cleaned[k] = stripJsonSchemaMeta(v)
        }
        return cleaned
    }
    if let array = value as? [Any] {
        return array.map { stripJsonSchemaMeta($0) }
    }
    return value
}

func convertGoogleTools(_ tools: [AITool], useParameters: Bool = false) -> [[String: Any]]? {
    guard !tools.isEmpty else { return nil }
    let declarations: [[String: Any]] = tools.map { tool in
        var declaration: [String: Any] = [
            "name": tool.name,
            "description": tool.description,
        ]
        let rawParameters = tool.parameters.mapValues { $0.jsonValue }
        let cleanedParameters = stripJsonSchemaMeta(rawParameters) as? [String: Any] ?? rawParameters
        if useParameters {
            declaration["parameters"] = cleanedParameters
        } else {
            declaration["parametersJsonSchema"] = cleanedParameters
        }
        return declaration
    }
    return [["functionDeclarations": declarations]]
}

func googleDisabledThinkingConfig(model: Model) -> [String: Any] {
    let id = model.id.lowercased()
    if id.range(of: #"gemini-3(?:\.\d+)?-pro"#, options: .regularExpression) != nil {
        return ["thinkingLevel": GoogleThinkingLevel.low.rawValue]
    }
    if id.range(of: #"gemini-3(?:\.\d+)?-flash"#, options: .regularExpression) != nil || id.range(of: #"gemma-?4"#, options: .regularExpression) != nil {
        return ["thinkingLevel": GoogleThinkingLevel.minimal.rawValue]
    }
    return ["thinkingBudget": 0]
}

func mapGoogleToolChoice(_ choice: String) -> String {
    switch choice {
    case "none":
        return "NONE"
    case "any":
        return "ANY"
    default:
        return "AUTO"
    }
}

func mapGoogleStopReason(_ reason: String) -> StopReasonResult {
    switch reason {
    case "STOP":
        return StopReasonResult(stopReason: .stop)
    case "MAX_TOKENS":
        return StopReasonResult(stopReason: .length)
    default:
        return StopReasonResult(stopReason: .error, errorMessage: "Provider stopped with: \(reason)")
    }
}

func googleThinkingLevel(for effort: ThinkingLevel, modelId: String) -> GoogleThinkingLevel {
    let clamped: ThinkingLevel
    if effort == .xhigh || effort == .max {
        clamped = .high
    } else {
        clamped = effort
    }
    if modelId.contains("3-pro") || modelId.contains("3.1-pro") {
        switch clamped {
        case .minimal, .low:
            return .low
        case .medium, .high, .xhigh, .max:
            return .high
        }
    }
    switch clamped {
    case .minimal:
        return .minimal
    case .low:
        return .low
    case .medium:
        return .medium
    case .high, .xhigh, .max:
        return .high
    }
}

struct GoogleStreamChunk: Decodable {
    struct Candidate: Decodable {
        struct Content: Decodable {
            var parts: [Part]?
        }
        var content: Content?
        var finishReason: String?
    }

    struct Part: Decodable {
        struct FunctionCall: Decodable {
            var name: String?
            var args: [String: AnyCodable]?
            var id: String?
        }

        var text: String?
        var thought: Bool?
        var thoughtSignature: String?
        var functionCall: FunctionCall?
    }

    struct UsageMetadata: Decodable {
        var promptTokenCount: Int?
        var candidatesTokenCount: Int?
        var thoughtsTokenCount: Int?
        var totalTokenCount: Int?
        var cachedContentTokenCount: Int?
    }

    var candidates: [Candidate]?
    var usageMetadata: UsageMetadata?
    var responseId: String?
}

struct GeminiCliStreamChunk: Decodable {
    var response: GoogleStreamChunk?
    var traceId: String?
}

func streamSsePayloads(
    bytes: URLSession.AsyncBytes,
    signal: CancellationToken?
) -> AsyncThrowingStream<String, Error> {
    AsyncThrowingStream { continuation in
        Task {
            var buffer = Data()
            let delimiterCrlf = Data([13, 10, 13, 10])
            let delimiterLf = Data([10, 10])

            do {
                for try await byte in bytes {
                    if signal?.isCancelled == true {
                        throw GoogleStreamError.aborted
                    }
                    buffer.append(byte)
                    while let range = findStreamDelimiter(in: buffer, crlf: delimiterCrlf, lf: delimiterLf) {
                        let chunk = buffer.subdata(in: 0..<range.lowerBound)
                        buffer.removeSubrange(0..<range.upperBound)
                        if let payload = parseSsePayload(from: chunk) {
                            continuation.yield(payload)
                        }
                    }
                }
                if !buffer.isEmpty, let payload = parseSsePayload(from: buffer) {
                    continuation.yield(payload)
                }
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
    }
}

func collectSseStreamData(from bytes: URLSession.AsyncBytes) async throws -> Data {
    var data = Data()
    for try await byte in bytes {
        data.append(byte)
    }
    return data
}

private func parseSsePayload(from chunk: Data) -> String? {
    guard !chunk.isEmpty, let raw = String(data: chunk, encoding: .utf8) else { return nil }
    let normalized = raw.replacingOccurrences(of: "\r\n", with: "\n")
    let lines = normalized.split(separator: "\n", omittingEmptySubsequences: false)
    var dataLines: [String] = []
    for line in lines {
        if line.hasPrefix("data:") {
            let data = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            dataLines.append(data)
        }
    }
    guard !dataLines.isEmpty else { return nil }
    let payload = dataLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    guard !payload.isEmpty, payload != "[DONE]" else { return nil }
    return payload
}

private func findStreamDelimiter(in buffer: Data, crlf: Data, lf: Data) -> Range<Data.Index>? {
    let crlfRange = buffer.range(of: crlf)
    let lfRange = buffer.range(of: lf)

    switch (crlfRange, lfRange) {
    case (nil, nil):
        return nil
    case (let range?, nil):
        return range
    case (nil, let range?):
        return range
    case (let range1?, let range2?):
        return range1.lowerBound <= range2.lowerBound ? range1 : range2
    }
}

enum GoogleStreamError: Error {
    case aborted
}
