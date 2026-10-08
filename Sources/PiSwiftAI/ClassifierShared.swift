import Foundation
import CoreFoundation

struct ClassifierError: LocalizedError, Sendable {
    let message: String
    var errorDescription: String? { message }
}

struct ClassifierTimeoutError: LocalizedError, ProviderError, Sendable {
    let timeoutMs: Int
    var providerStatusCode: Int? { nil }
    var providerHeaders: [String: String]? { nil }
    var errorDescription: String? { "Request timed out after \(timeoutMs)ms" }
}

struct ClassifierHTTPError: LocalizedError, ProviderError, Sendable {
    let status: Int
    let headers: [String: String]
    let body: String
    let label: String
    var useStatusMessage = false
    var providerStatusCode: Int? { status }
    var providerHeaders: [String: String]? { headers }
    var errorDescription: String? { useStatusMessage ? "\(label) returned \(status)" : formattedMessage() }

    func formattedMessage(preserveEmbeddedBody: Bool = false) -> String {
        let message = "\(label) returned \(status)"
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        let count = trimmed.utf16.count
        let excerpt = count > 4000
            ? String(decoding: trimmed.utf16.prefix(4000), as: UTF16.self) + "... [truncated \(count - 4000) chars]"
            : trimmed
        // Decisions follows normalizeProviderError. Keep System One's existing body selection.
        let detail = excerpt.isEmpty || (preserveEmbeddedBody && message.contains(excerpt)) ? message : excerpt
        return "\(label) error (\(status)): \(detail)"
    }
}

func requiredNumber(_ value: Any?, label: String, field: String) throws -> Double {
    guard let number = value as? NSNumber,
          CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite else {
        throw ClassifierError(message: "\(label) returned an invalid \(field)")
    }
    return number.doubleValue
}

func parseClassifierUsage(_ value: Any?, model: ClassifierModel) -> Usage? {
    guard let raw = value as? [String: Any],
          raw["input_tokens"] != nil || raw["output_tokens"] != nil else { return nil }
    func count(_ value: Any?) -> Int {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite, number.doubleValue > 0 else { return 0 }
        return Int(clamping: number.int64Value)
    }
    let input = count(raw["input_tokens"])
    let output = count(raw["output_tokens"])
    var usage = Usage(input: input, output: output, cacheRead: 0, cacheWrite: 0,
                      totalTokens: input + output)
    calculateCost(model: model, usage: &usage)
    return usage
}

/// Posts one classifier payload. The hooks run once; each attempt has its own timeout.
/// The defaults preserve System One's JSON serialization and parsing.
func postClassifierRequest(label: String, url: @Sendable () throws -> URL, model: ClassifierModel,
                           payload: OrderedJSON, options: ClassifierOptions,
                           noRetryStatuses: [Int] = [], escapeSlashes: Bool = true,
                           allowFragments: Bool = false, useStatusErrorMessage: Bool = false) async throws -> AnyCodable {
    guard let apiKey = options.apiKey, !apiKey.isEmpty else {
        throw ClassifierError(message: "No API key for provider: \(model.provider)")
    }
    let transformed = try await options.onPayload?(payload, model)
    let body = transformed ?? payload
    var request = URLRequest(url: try url())
    request.httpMethod = "POST"
    request.httpBody = Data(body.serialized(escapeSlashes: escapeSlashes).utf8)
    if let timeoutMs = options.timeoutMs { request.timeoutInterval = Double(timeoutMs) / 1000 }
    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    applyProviderHeaders(mergeProviderHeaders(model.headers, options.headers), to: &request)
    let finalRequest = request
    let client = options.httpClient ?? DefaultProviderHTTPClient(env: options.env)
    let (data, response) = try await retryProviderRequest(maxRetries: options.maxRetries ?? 2,
        maxRetryDelayMs: options.maxRetryDelayMs, signal: options.signal, noRetryStatuses: noRetryStatuses) {
        let operation: @Sendable () async throws -> (Data, ProviderHTTPResponse) = {
            let response = try await client.send(finalRequest)
            let data = try await collectProviderHTTPBody(response.body)
            guard (200..<300).contains(response.statusCode) else {
                throw ClassifierHTTPError(status: response.statusCode, headers: response.headers,
                    body: String(data: data, encoding: .utf8) ?? "", label: label, useStatusMessage: useStatusErrorMessage)
            }
            return (data, response)
        }
        guard let timeoutMs = options.timeoutMs else { return try await operation() }
        return try await withThrowingTaskGroup(of: (Data, ProviderHTTPResponse).self) { group in
            group.addTask(operation: operation)
            group.addTask {
                try await Task.sleep(for: .milliseconds(timeoutMs))
                throw ClassifierTimeoutError(timeoutMs: timeoutMs)
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }
    let json = AnyCodable(try JSONSerialization.jsonObject(with: data, options: allowFragments ? [.fragmentsAllowed] : []))
    try await options.onResponse?(ResponseSnapshot(statusCode: response.statusCode, headers: response.headers), model)
    return json
}
