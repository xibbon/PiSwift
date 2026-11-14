import Foundation
import PiSwiftAI

// Port of pi-codex-image-gen `src/codex-response.ts` (Responses part only).
// The subscription Responses contract is private. Keep its parser and safety
// boundaries separate from tool registration and file handling.

let codexRequestTimeout: TimeInterval = 5 * 60
let codexMaxResponseBytes = 100 * 1024 * 1024
let codexMaxImageBytes = 32 * 1024 * 1024
let codexMaxBase64ImageChars = (codexMaxImageBytes + 2) / 3 * 4
private let maxErrorBytes = 16 * 1024
let codexMaxTextChars = 4000

// MARK: - Parsed response

struct ReportedImage: Sendable, Equatable {
    var model: String?
    var size: String?
    var quality: String?
    var background: String?
    var outputFormat: String?

    var dictionary: [String: Any] {
        var result: [String: Any] = [:]
        if let model { result["model"] = model }
        if let size { result["size"] = size }
        if let quality { result["quality"] = quality }
        if let background { result["background"] = background }
        if let outputFormat { result["outputFormat"] = outputFormat }
        return result
    }
}

struct CodexImageItem: Sendable {
    var id: String
    var status: String = "completed"
    /// Base64 image bytes.
    var result: String
    var revisedPrompt: String?
    var reported: ReportedImage
}

struct ParsedCodexResponse: Sendable {
    var image: CodexImageItem?
    var text: String = ""
    var responseId: String?
    var requestId: String?
    var imagegenRequestId: String?
    var usage: AnyCodable?
}

// MARK: - Errors

enum FailureCategory: String, Sendable {
    case authentication, quota, moderation, unsupportedFeature = "unsupported-feature"
    case invalidRequest = "invalid-request", backend
}

struct FailureDiagnostics: Sendable {
    var category: FailureCategory
    var status: Int?
    var code: String?
    var requestId: String?
    var imagegenRequestId: String?
    var responseId: String?
}

struct CodexRequestError: Error, LocalizedError, Sendable {
    let message: String
    let diagnostics: FailureDiagnostics

    init(_ message: String, _ diagnostics: FailureDiagnostics) {
        let ids = [
            diagnostics.code.map { "Code: \($0)." },
            diagnostics.requestId.map { "Request ID: \($0)." },
            diagnostics.imagegenRequestId.map { "Image request ID: \($0)." },
            diagnostics.responseId.map { "Response ID: \($0)." },
        ].compactMap { $0 }.joined(separator: " ")
        self.message = ids.isEmpty ? message : "\(message) \(ids)"
        self.diagnostics = diagnostics
    }

    var errorDescription: String? { message }
}

// MARK: - Sanitizing

private let jwtPattern = try! NSRegularExpression(pattern: "\\beyJ[A-Za-z0-9_.-]*")

/// Remove secrets, JWT-like strings and control characters, then bound the length.
func sanitizeText(_ value: Any?, secrets: [String] = []) -> String {
    guard var result = value as? String else { return "" }
    for secret in secrets where !secret.isEmpty {
        result = result.replacingOccurrences(of: secret, with: "[redacted]")
    }
    // Also hide a JWT cut short by the text bound; exact-token matching alone
    // cannot redact a credential that arrives across the truncation boundary.
    let range = NSRange(result.startIndex..., in: result)
    result = jwtPattern.stringByReplacingMatches(in: result, range: range, withTemplate: "[redacted]")
    result = String(String.UnicodeScalarView(result.unicodeScalars.map { scalar in
        (scalar.value <= 0x1f || (0x7f...0x9f).contains(scalar.value)) ? " " : scalar
    }))
    return String(result.prefix(codexMaxTextChars))
}

func sanitizedIdentifier(_ value: Any?, secrets: [String]) -> String? {
    guard let value = value as? String, isIdentifier(value, maxLength: 128), !value.hasPrefix("eyJ"),
          !secrets.contains(where: { !$0.isEmpty && value.contains($0) }) else { return nil }
    return value
}

private func object(_ value: Any?) -> [String: Any] {
    value as? [String: Any] ?? [:]
}

private func requestIds(_ headers: [String: String], secrets: [String]) -> (requestId: String?, imagegenRequestId: String?) {
    (sanitizedIdentifier(headers["x-request-id"], secrets: secrets),
     sanitizedIdentifier(headers["x-codex-imagegen-request-id"], secrets: secrets))
}

func lowercasedHeaders(_ headers: [String: String]) -> [String: String] {
    var result: [String: String] = [:]
    for (key, value) in headers { result[key.lowercased()] = value }
    return result
}

// MARK: - Classification

private let quotaCodes: Set<String> = [
    "insufficient_quota", "quota_exceeded", "usage_limit_reached", "usage_limit_exceeded",
    "billing_hard_limit_reached", "billing_not_active", "organization_usage_limit_exceeded",
    "workspace_member_usage_limit_reached",
]

private func isQuota(_ error: [String: Any]) -> Bool {
    [error["code"], error["type"]].contains { ($0 as? String).map(quotaCodes.contains) ?? false }
}

private let unsupportedCodes: Set<String> = [
    "unsupported_parameter", "unsupported_value", "invalid_input_fidelity_model", "unsupported_model", "invalid_complexity",
]

func classifyCodexError(_ error: [String: Any], status: Int? = nil) -> (category: FailureCategory, message: String) {
    let code = error["code"] as? String
    let type = error["type"] as? String
    if status == 401 || status == 403 {
        return (.authentication, status == 401
            ? "The ChatGPT login was rejected. Run /login \(codexImageChatGPTProvider) again."
            : "Codex access was denied. This can be a connection or account restriction; it does not identify the image model.")
    }
    if isQuota(error) {
        return (.quota, "Codex subscription quota is unavailable or exhausted. Check your plan or wait for its reset.")
    }
    if code == "moderation_blocked" {
        return (.moderation, "Codex could not generate this image. Review the prompt and input images before trying again.")
    }
    let gif = "GIF output is not enabled for this request."
    let complexity = ["Complexity 'low' is not supported for this image model.", "Complexity 'medium' is not supported for this image model."]
    if error["detail"] as? String == gif || error["message"] as? String == gif
        || code.map(unsupportedCodes.contains) == true
        || (error["message"] as? String).map(complexity.contains) == true {
        return (.unsupportedFeature, "Codex has not enabled or does not support this image feature for this request. No alternate transport or API fallback was used.")
    }
    if type == "image_generation_user_error" || status == 400 || status == 422 {
        return (.invalidRequest, "Codex could not generate this image. Review the prompt and input images before trying again.")
    }
    return (.backend, "Codex could not complete the image request.")
}

struct HTTPFailure: Sendable {
    var message: String
    var retry: Bool
    var diagnostics: FailureDiagnostics
}

/// Read at most 16 KiB of an error body. The body text is never shown.
func codexHTTPFailure(_ response: ProviderHTTPResponse, secrets: [String]) async -> HTTPFailure {
    let headers = lowercasedHeaders(response.headers)
    let ids = requestIds(headers, secrets: secrets)
    if headers["cf-mitigated"] == "challenge" {
        return HTTPFailure(
            message: "Codex connection was challenged by Cloudflare. This does not establish model or subscription availability.",
            retry: false,
            diagnostics: FailureDiagnostics(category: .backend, status: response.statusCode,
                                            requestId: ids.requestId, imagegenRequestId: ids.imagegenRequestId))
    }
    // A large or unreadable error body is deliberately not exposed.
    let body = (try? await collectBounded(response.body, limit: maxErrorBytes)) ?? Data()
    var error: [String: Any] = [:]
    if let parsed = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
        error = parsed["error"] != nil ? object(parsed["error"]) : parsed
    }
    let classified = classifyCodexError(error, status: response.statusCode)
    let terminal = classified.category == .unsupportedFeature || isQuota(error)
        || error["code"] as? String == "moderation_blocked" || error["type"] as? String == "image_generation_user_error"
    return HTTPFailure(
        message: "Codex image request failed (HTTP \(response.statusCode)). \(classified.message)",
        retry: !terminal && [429, 500, 502, 503, 504].contains(response.statusCode),
        diagnostics: FailureDiagnostics(category: classified.category, status: response.statusCode,
                                        code: sanitizedIdentifier(error["code"], secrets: secrets),
                                        requestId: ids.requestId, imagegenRequestId: ids.imagegenRequestId))
}

struct ResponseSizeError: Error {}

func collectBounded(_ body: AsyncThrowingStream<Data, Error>, limit: Int) async throws -> Data {
    var data = Data()
    for try await chunk in body {
        data.append(chunk)
        if data.count > limit { throw ResponseSizeError() }
    }
    return data
}

/// Pass body chunks through and fail when the total exceeds `limit`.
/// Cancelling `stop` cancels the read, which also stops the underlying download.
func limitedBody(_ body: AsyncThrowingStream<Data, Error>, limit: Int, stop: CancellationToken) -> AsyncThrowingStream<Data, Error> {
    AsyncThrowingStream { continuation in
        let task = Task {
            var total = 0
            do {
                for try await chunk in body {
                    total += chunk.count
                    if total > limit {
                        throw CodexImageError("Codex response exceeded the size limit.")
                    }
                    continuation.yield(chunk)
                }
                continuation.finish()
            } catch let error as CodexImageError {
                continuation.finish(throwing: error)
            } catch {
                continuation.finish(throwing: CodexImageError(
                    "Codex response stream was interrupted. The backend may still finish; no automatic retry was made."))
            }
        }
        let remove = stop.onCancel { task.cancel() }
        continuation.onTermination = { _ in
            remove()
            task.cancel()
        }
    }
}

// MARK: - SSE

private func reportedImage(_ item: [String: Any], secrets: [String]) -> ReportedImage {
    var reported = ReportedImage()
    if let model = item["model"] as? String,
       model.range(of: "^gpt-image-[a-z0-9.-]{1,80}$", options: .regularExpression) != nil,
       !secrets.contains(where: { !$0.isEmpty && model.contains($0) }) {
        reported.model = model
    }
    if let size = item["size"] as? String, size.range(of: "^[1-9][0-9]{0,4}x[1-9][0-9]{0,4}$", options: .regularExpression) != nil {
        reported.size = size
    }
    if let quality = item["quality"] as? String, ["low", "medium", "high", "xhigh", "max", "auto"].contains(quality) {
        reported.quality = quality
    }
    if let background = item["background"] as? String, ["transparent", "opaque", "auto"].contains(background) {
        reported.background = background
    }
    if let format = item["output_format"] as? String, OutputFormat(rawValue: format) != nil {
        reported.outputFormat = format
    }
    return reported
}

/// A finite, non-negative JSON number. Booleans are not numbers. A whole
/// number that `Int` can hold exactly stays an integer; any other value stays a
/// double, so a very large counter cannot trap.
func usageCounter(_ value: Any?) -> Any? {
    guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
    let double = number.doubleValue
    guard double.isFinite, double >= 0 else { return nil }
    if double.rounded(.towardZero) == double, double < 0x1p53 { return Int(double) }
    return double
}

/// Keep numeric, non-negative counters only. Never persist arbitrary response objects.
private func usageCounters(_ value: Any?) -> AnyCodable? {
    let usage = object(value)
    func counters(_ record: [String: Any], _ keys: [String]) -> [String: Any] {
        var result: [String: Any] = [:]
        for key in keys {
            if let value = usageCounter(record[key]) { result[key] = value }
        }
        return result
    }
    var result = counters(usage, ["input_tokens", "output_tokens", "total_tokens"])
    for key in ["input_tokens_details", "output_tokens_details"] {
        let details = counters(object(usage[key]), ["image_tokens", "text_tokens", "cached_tokens", "reasoning_tokens"])
        if !details.isEmpty { result[key] = details }
    }
    return result.isEmpty ? nil : AnyCodable(result)
}

/// Parse the Codex Responses SSE stream. At most one completed
/// `image_generation_call` is accepted.
func parseCodexSse(
    _ response: ProviderHTTPResponse,
    secrets: [String],
    signal: CancellationToken? = nil,
    onProgress: (@Sendable (String) -> Void)? = nil
) async throws -> ParsedCodexResponse {
    // Stop the stream readers on abort and when parsing ends early. Do not let
    // a stalled stream outlive the request.
    let stop = CancellationToken()
    let removeSignal = signal?.onCancel { stop.cancel() }
    defer {
        removeSignal?()
        stop.cancel()
    }
    let headers = lowercasedHeaders(response.headers)
    if let declared = headers["content-length"].flatMap(Int.init), declared > codexMaxResponseBytes {
        throw CodexImageError("Codex response exceeded the size limit.")
    }
    let ids = requestIds(headers, secrets: secrets)
    var parsed = ParsedCodexResponse(requestId: ids.requestId, imagegenRequestId: ids.imagegenRequestId)
    var completed = false
    var textChars = 0
    var textParts: [String] = []
    var lastStage: String?

    func image(_ value: Any?) throws {
        let item = object(value)
        guard item["type"] as? String == "image_generation_call" else { return }
        if parsed.image != nil { throw CodexImageError("Codex returned more than one image. No automatic retry was made.") }
        guard item["status"] as? String == "completed" else { throw CodexImageError("Codex image generation did not complete.") }
        guard let result = item["result"] as? String, !result.isEmpty else {
            throw CodexImageError("Codex image_generation_call did not contain image data.")
        }
        if result.utf8.count > codexMaxBase64ImageChars { throw CodexImageError("Codex image exceeded the 32 MiB size limit.") }
        let revised = sanitizeText(item["revised_prompt"], secrets: secrets)
        parsed.image = CodexImageItem(
            id: sanitizedIdentifier(item["id"], secrets: secrets) ?? "image_generation",
            result: result, revisedPrompt: revised.isEmpty ? nil : revised,
            reported: reportedImage(item, secrets: secrets))
    }

    let events = iterateSseEvents(body: limitedBody(response.body, limit: codexMaxResponseBytes, stop: stop), signal: stop)
    for try await frame in events {
        let data = frame.data.trimmingCharacters(in: .whitespacesAndNewlines)
        if data.isEmpty || data == "[DONE]" { continue }
        guard let bytes = data.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: bytes), let event = json as? [String: Any] else {
            throw CodexImageError("Codex returned an invalid stream event. No automatic retry was made.")
        }
        switch event["type"] as? String {
        case "error", "response.failed":
            let error = object(object(event["response"])["error"] ?? event["error"] ?? event)
            let classified = classifyCodexError(error)
            throw CodexRequestError(classified.message, FailureDiagnostics(
                category: classified.category, code: sanitizedIdentifier(error["code"], secrets: secrets),
                requestId: parsed.requestId, imagegenRequestId: parsed.imagegenRequestId, responseId: parsed.responseId))
        case "response.incomplete":
            throw CodexImageError("Codex response was incomplete. No automatic retry was made.")
        case "response.created":
            parsed.responseId = sanitizedIdentifier(object(event["response"])["id"], secrets: secrets)
        case "response.output_text.delta":
            if let delta = event["delta"] as? String, textChars < codexMaxTextChars {
                let part = String(delta.prefix(codexMaxTextChars - textChars))
                textParts.append(part)
                textChars += part.count
            }
        case "response.output_item.done":
            try image(event["item"])
        case "response.completed":
            let final = object(event["response"])
            parsed.responseId = sanitizedIdentifier(final["id"], secrets: secrets) ?? parsed.responseId
            parsed.usage = usageCounters(final["usage"])
            if parsed.image == nil, let output = final["output"] as? [Any] {
                for item in output { try image(item) }
            }
            completed = true
        case let type? where type.hasPrefix("response.image_generation_call.")
            && ["in_progress", "generating", "completed"].contains(String(type.split(separator: ".").last ?? "")):
            if type != lastStage {
                lastStage = type
                onProgress?(String(type.split(separator: ".").last ?? ""))
            }
        default:
            break
        }
        if completed { break }
    }
    guard completed else {
        throw CodexImageError("Codex stream ended before completion. The backend may still finish; no automatic retry was made.")
    }
    parsed.text = sanitizeText(textParts.joined(), secrets: secrets)
    return parsed
}
