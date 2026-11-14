import Foundation
import PiSwiftAI

// Port of `requestImage`, `buildRequestBody` and the retry helpers in
// pi-codex-image-gen `extensions/index.ts`.

let codexPackageName = "pi-codex-image-gen"
private let openAIBetaHeader = "responses=experimental"
let codexMaxRetries = 3
private let baseDelayMs = 1000
let codexMaxRetryDelayMs = 30_000

// MARK: - Cancellation scope

/// Combines the tool signal, the extension lifetime and one deadline. The
/// reason tells the caller whether the call was aborted or timed out.
final class AbortScope: Sendable {
    enum Reason: Sendable { case aborted, timedOut }

    let token = CancellationToken()
    private let reason = LockedState<Reason?>(nil)
    private let cleanup = LockedState<[@Sendable () -> Void]>([])

    init(parents: [CancellationToken?], timeout: TimeInterval) {
        var removers: [@Sendable () -> Void] = []
        for parent in parents.compactMap({ $0 }) {
            removers.append(parent.onCancel { [weak self] in self?.abort(.aborted) })
        }
        let timer = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            if !Task.isCancelled { self?.abort(.timedOut) }
        }
        removers.append { timer.cancel() }
        cleanup.withLock { $0 = removers }
    }

    func abort(_ value: Reason) {
        let first = reason.withLock { current -> Bool in
            guard current == nil else { return false }
            current = value
            return true
        }
        if first { token.cancel() }
    }

    var abortReason: Reason? { reason.withLock { $0 } }
    var isAborted: Bool { token.isCancelled }

    func throwIfAborted() throws {
        if token.isCancelled { throw CancellationError() }
    }

    /// Run `operation` in a child task and cancel it when the scope aborts.
    func run<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        try throwIfAborted()
        let task = Task { try await operation() }
        let remove = token.onCancel { task.cancel() }
        defer { remove() }
        do {
            let value = try await task.value
            try throwIfAborted()
            return value
        } catch {
            if token.isCancelled { throw CancellationError() }
            throw error
        }
    }

    func sleep(milliseconds: Int) async throws {
        try await run { try await Task.sleep(nanoseconds: UInt64(milliseconds) * 1_000_000) }
    }

    func dispose() {
        let removers = cleanup.withLock { value -> [@Sendable () -> Void] in
            defer { value = [] }
            return value
        }
        removers.forEach { $0() }
    }
}

// MARK: - Retry helpers

/// Server-requested delay in milliseconds, capped at 30 seconds.
func parseRetryAfter(_ value: String?, now: Date = Date()) -> Int? {
    guard let trimmed = value?.trimmingCharacters(in: .whitespaces), !trimmed.isEmpty else { return nil }
    if trimmed.range(of: "^[0-9]+(\\.[0-9]+)?$", options: .regularExpression) != nil, let seconds = Double(trimmed) {
        let ms = seconds * 1000
        return ms.isFinite ? Int(min(ms, Double(codexMaxRetryDelayMs))) : nil
    }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(identifier: "GMT")
    formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
    guard let date = formatter.date(from: trimmed), date > now else { return nil }
    return min(Int(date.timeIntervalSince(now) * 1000), codexMaxRetryDelayMs)
}

func retryDelayMs(attempt: Int, retryAfter: String?, random: () -> Double = { Double.random(in: 0..<1) },
                  now: Date = Date()) -> Int {
    if let server = parseRetryAfter(retryAfter, now: now) {
        return Int(min(Double(server) * (1 + random() * 0.1), Double(codexMaxRetryDelayMs)).rounded(.down))
    }
    let exponential = min(Double(baseDelayMs) * pow(2, Double(attempt - 1)), Double(codexMaxRetryDelayMs))
    return Int((exponential * (0.9 + random() * 0.2)).rounded(.down))
}

// MARK: - Request

struct InputImage: Sendable, Equatable {
    var data: String
    var mimeType: String
}

let codexImageInstructions = "You are generating bitmap image assets. For this request, call the image_generation tool exactly once. Do not answer with only text unless image generation is unavailable."

func buildCodexRequestBody(prompt: String, background: String?, model: String, outputFormat: OutputFormat,
                           sessionId: String, inputImages: [InputImage]) -> [String: Any] {
    var content: [[String: Any]] = [["type": "input_text", "text": prompt]]
    for image in inputImages {
        content.append(["type": "input_image", "image_url": "data:\(image.mimeType);base64,\(image.data)"])
    }
    var tool: [String: Any] = ["type": "image_generation", "output_format": outputFormat.rawValue]
    if let background { tool["background"] = background }
    return [
        "model": model,
        "store": false,
        "stream": true,
        "prompt_cache_key": sessionId,
        "instructions": codexImageInstructions,
        "input": [["role": "user", "content": content]],
        "tools": [tool],
        "tool_choice": "auto",
        "parallel_tool_calls": false,
        "text": ["verbosity": "low"],
    ]
}

func buildCodexHeaders(auth: CodexImageAuth) -> [String: String] {
    var headers: [String: String] = [:]
    // Model and provider headers first; the protected values below replace them.
    for (key, value) in auth.extraHeaders { headers[key.lowercased()] = value }
    headers["authorization"] = "Bearer \(auth.token)"
    headers["chatgpt-account-id"] = auth.accountId
    headers["originator"] = "pi"
    headers["user-agent"] = codexPackageName
    headers["openai-beta"] = openAIBetaHeader
    headers["accept"] = "text/event-stream"
    headers["content-type"] = "application/json"
    headers["x-client-request-id"] = UUID().uuidString.lowercased()
    return headers
}

/// Send the request with bounded retries for transient HTTP failures only.
func requestCodexImage(
    payload: Data,
    auth: CodexImageAuth,
    client: any ProviderHTTPClient,
    scope: AbortScope,
    random: @escaping @Sendable () -> Double = { Double.random(in: 0..<1) },
    onProgress: (@Sendable (String) -> Void)? = nil
) async throws -> ParsedCodexResponse {
    let secrets = [auth.token, auth.accountId]
    var request = URLRequest(url: auth.responsesURL)
    request.httpMethod = "POST"
    request.httpBody = payload
    request.timeoutInterval = codexRequestTimeout
    for (key, value) in buildCodexHeaders(auth: auth) { request.setValue(value, forHTTPHeaderField: key) }

    for attempt in 1...(codexMaxRetries + 1) {
        try scope.throwIfAborted()
        let response: ProviderHTTPResponse
        do {
            let sendable = request
            response = try await scope.run { try await client.send(sendable, timeoutPolicy: .responseHeadersOnly) }
        } catch {
            try scope.throwIfAborted()
            throw CodexImageError("Codex connection failed. No automatic retry was made; check connectivity before trying again.")
        }
        guard (200..<300).contains(response.statusCode) else {
            let failure = await codexHTTPFailure(response, secrets: secrets)
            if attempt <= codexMaxRetries && failure.retry {
                let retryAfter = lowercasedHeaders(response.headers)["retry-after"]
                try await scope.sleep(milliseconds: retryDelayMs(attempt: attempt, retryAfter: retryAfter, random: random))
                continue
            }
            throw CodexRequestError(failure.message, failure.diagnostics)
        }
        let signal = scope.token
        return try await scope.run {
            try await parseCodexSse(response, secrets: secrets, signal: signal, onProgress: onProgress)
        }
    }
    throw CodexImageError("Codex image generation request failed after all retries.")
}
