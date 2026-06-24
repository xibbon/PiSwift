import Foundation

private let openRouterImagesSessionFactory = LockedState<@Sendable (URL?) -> URLSession>(proxySession(for:))

func setOpenRouterImagesURLSessionFactory(_ factory: @escaping @Sendable (URL?) -> URLSession) {
    openRouterImagesSessionFactory.withLock { $0 = factory }
}

func resetOpenRouterImagesURLSessionFactory() {
    openRouterImagesSessionFactory.withLock { $0 = proxySession(for:) }
}

private enum OpenRouterImagesError: Error, LocalizedError {
    case missingApiKey(String)
    case invalidBaseUrl(String)
    case invalidResponse
    case httpError(Int, String)
    case aborted

    var errorDescription: String? {
        switch self {
        case .missingApiKey(let provider):
            return "No API key for provider: \(provider)"
        case .invalidBaseUrl(let url):
            return "Invalid base URL: \(url)"
        case .invalidResponse:
            return "Invalid response"
        case .httpError(let status, let body):
            return body.isEmpty ? "HTTP \(status)" : "HTTP \(status): \(body)"
        case .aborted:
            return "Request was aborted"
        }
    }
}

public func generateImagesOpenRouter(
    model: ImagesModel,
    context: ImagesContext,
    options: ImagesOptions? = nil
) async -> AssistantImages {
    var output = AssistantImages(
        api: model.api,
        provider: model.provider,
        model: model.id,
        output: [],
        stopReason: .stop
    )

    do {
        let options = options ?? ImagesOptions()
        if options.signal?.isCancelled == true {
            throw OpenRouterImagesError.aborted
        }
        guard let apiKey = options.apiKey, !apiKey.isEmpty else {
            throw OpenRouterImagesError.missingApiKey(model.provider)
        }

        let payload = try buildOpenRouterImagesPayload(model: model, context: context)
        emitPayload(options.onPayload, jsonObject: payload)
        let body = try JSONSerialization.data(withJSONObject: payload)

        let request = try buildOpenRouterImagesRequest(model: model, apiKey: apiKey, options: options, body: body)
        let maxRetries = max(0, options.maxRetries ?? 0)
        let (data, response) = try await performOpenRouterImagesRequest(
            request,
            signal: options.signal,
            maxRetries: maxRetries
        )

        guard let http = response as? HTTPURLResponse else {
            throw OpenRouterImagesError.invalidResponse
        }
        options.onResponse?(ResponseSnapshot(statusCode: http.statusCode, headers: responseHeaders(http)))
        guard (200..<300).contains(http.statusCode) else {
            throw OpenRouterImagesError.httpError(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }

        try parseOpenRouterImagesResponse(data, model: model, output: &output)
        return output
    } catch {
        output.stopReason = options?.signal?.isCancelled == true ? .aborted : .error
        if case OpenRouterImagesError.aborted = error {
            output.stopReason = .aborted
        }
        output.errorMessage = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
        return output
    }
}

private func buildOpenRouterImagesPayload(model: ImagesModel, context: ImagesContext) throws -> [String: Any] {
    let content = context.input.compactMap { item -> [String: Any]? in
        switch item {
        case .text(let text):
            return [
                "type": "text",
                "text": sanitizeSurrogates(text.text),
            ]
        case .image(let image):
            return [
                "type": "image_url",
                "image_url": [
                    "url": "data:\(image.mimeType);base64,\(image.data)",
                ],
            ]
        case .thinking, .toolCall:
            return nil
        }
    }

    return [
        "model": model.id,
        "messages": [
            [
                "role": "user",
                "content": content,
            ],
        ],
        "stream": false,
        "modalities": model.output.contains(.text) ? ["image", "text"] : ["image"],
    ]
}

private func buildOpenRouterImagesRequest(
    model: ImagesModel,
    apiKey: String,
    options: ImagesOptions,
    body: Data
) throws -> URLRequest {
    guard let baseUrl = URL(string: model.baseUrl) else {
        throw OpenRouterImagesError.invalidBaseUrl(model.baseUrl)
    }
    let url = baseUrl.appendingPathComponent("chat/completions")
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.timeoutInterval = Double(options.timeoutMs ?? 600_000) / 1000.0
    request.httpBody = body
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

    var headers = model.headers ?? [:]
    if let optionHeaders = options.headers {
        for (key, value) in optionHeaders {
            headers[key] = value
        }
    }
    for (key, value) in headers {
        request.setValue(value, forHTTPHeaderField: key)
    }
    return request
}

private func performOpenRouterImagesRequest(
    _ request: URLRequest,
    signal: CancellationToken?,
    maxRetries: Int
) async throws -> (Data, URLResponse) {
    var attempt = 0
    var lastError: Error?

    while attempt <= maxRetries {
        if signal?.isCancelled == true {
            throw OpenRouterImagesError.aborted
        }
        do {
            let session = openRouterImagesSessionFactory.withLock { $0 }(request.url)
            let (data, response) = try await session.data(for: request)
            if signal?.isCancelled == true {
                throw OpenRouterImagesError.aborted
            }
            if let http = response as? HTTPURLResponse,
               [408, 409, 429, 500, 502, 503, 504].contains(http.statusCode),
               attempt < maxRetries {
                attempt += 1
                continue
            }
            return (data, response)
        } catch {
            lastError = error
            if attempt >= maxRetries {
                throw error
            }
            attempt += 1
        }
    }

    throw lastError ?? OpenRouterImagesError.invalidResponse
}

private func parseOpenRouterImagesResponse(_ data: Data, model: ImagesModel, output: inout AssistantImages) throws {
    guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw OpenRouterImagesError.invalidResponse
    }
    output.responseId = root["id"] as? String
    if let rawUsage = root["usage"] as? [String: Any] {
        output.usage = parseOpenRouterImagesUsage(rawUsage, model: model)
    }

    guard let choices = root["choices"] as? [[String: Any]],
          let choice = choices.first,
          let message = choice["message"] as? [String: Any] else {
        return
    }

    if let content = message["content"] as? String, !content.isEmpty {
        output.output.append(.text(TextContent(text: content)))
    }

    guard let images = message["images"] as? [[String: Any]] else {
        return
    }
    for image in images {
        let imageUrl: String?
        if let string = image["image_url"] as? String {
            imageUrl = string
        } else if let object = image["image_url"] as? [String: Any] {
            imageUrl = object["url"] as? String
        } else {
            imageUrl = nil
        }
        guard let imageUrl, imageUrl.hasPrefix("data:"),
              let parsed = parseDataImageUrl(imageUrl) else {
            continue
        }
        output.output.append(.image(ImageContent(data: parsed.data, mimeType: parsed.mimeType)))
    }
}

private func parseOpenRouterImagesUsage(_ rawUsage: [String: Any], model: ImagesModel) -> Usage {
    let promptTokens = intValue(rawUsage["prompt_tokens"])
    let outputTokens = intValue(rawUsage["completion_tokens"])
    let details = rawUsage["prompt_tokens_details"] as? [String: Any]
    let reportedCachedTokens = intValue(details?["cached_tokens"])
    let cacheWriteTokens = intValue(details?["cache_write_tokens"])
    let cacheReadTokens = cacheWriteTokens > 0 ? max(0, reportedCachedTokens - cacheWriteTokens) : reportedCachedTokens
    let input = max(0, promptTokens - cacheReadTokens - cacheWriteTokens)
    var usage = Usage(
        input: input,
        output: outputTokens,
        cacheRead: cacheReadTokens,
        cacheWrite: cacheWriteTokens,
        totalTokens: input + outputTokens + cacheReadTokens + cacheWriteTokens
    )
    usage.cost.input = (model.cost.input / 1_000_000) * Double(input)
    usage.cost.output = (model.cost.output / 1_000_000) * Double(outputTokens)
    usage.cost.cacheRead = (model.cost.cacheRead / 1_000_000) * Double(cacheReadTokens)
    usage.cost.cacheWrite = (model.cost.cacheWrite / 1_000_000) * Double(cacheWriteTokens)
    usage.cost.total = usage.cost.input + usage.cost.output + usage.cost.cacheRead + usage.cost.cacheWrite
    return usage
}

private func parseDataImageUrl(_ value: String) -> (mimeType: String, data: String)? {
    guard value.hasPrefix("data:"),
          let comma = value.firstIndex(of: ",") else {
        return nil
    }
    let metadata = value[value.index(value.startIndex, offsetBy: 5)..<comma]
    let parts = metadata.split(separator: ";")
    guard let mimeType = parts.first,
          parts.contains("base64") else {
        return nil
    }
    let data = value[value.index(after: comma)...]
    return (String(mimeType), String(data))
}

private func intValue(_ value: Any?) -> Int {
    switch value {
    case let int as Int:
        return int
    case let double as Double:
        return Int(double)
    case let number as NSNumber:
        return number.intValue
    default:
        return 0
    }
}

private func responseHeaders(_ response: HTTPURLResponse) -> [String: String] {
    var headers: [String: String] = [:]
    for (key, value) in response.allHeaderFields {
        headers[String(describing: key)] = String(describing: value)
    }
    return headers
}
