import Foundation
import CoreFoundation

enum SystemOneTransport: Sendable {
    case typesafe
    case cloudflare

    var api: ClassifierApi {
        switch self { case .typesafe: .typesafeSystemOne; case .cloudflare: .cloudflareWorkersAISystemOne }
    }
    var label: String {
        switch self { case .typesafe: "System One API"; case .cloudflare: "Cloudflare Workers AI" }
    }
    var path: String {
        switch self { case .typesafe: "systemone"; case .cloudflare: "run" }
    }
}

private struct SystemOneError: LocalizedError, Sendable {
    let message: String
    var errorDescription: String? { message }
}

private struct SystemOneTimeoutError: LocalizedError, ProviderError, Sendable {
    let timeoutMs: Int
    var providerStatusCode: Int? { nil }
    var providerHeaders: [String: String]? { nil }
    var errorDescription: String? { "Request timed out after \(timeoutMs)ms" }
}

private struct SystemOneHTTPError: LocalizedError, ProviderError, Sendable {
    let status: Int
    let headers: [String: String]
    let body: String
    let label: String
    var providerStatusCode: Int? { status }
    var providerHeaders: [String: String]? { headers }
    var errorDescription: String? {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "\(label) error (\(status)): \(label) returned \(status)" }
        let excerpt = String(trimmed.prefix(4000))
        return "\(label) error (\(status)): \(excerpt)"
    }
}

private func systemOneWireRequest(_ context: ClassifierContext) -> OrderedJSON {
    let state = OrderedJSON.fromFoundation(context.state.mapValues(\.value))
    let questions = context.questions.entries.map { id, question -> (String, OrderedJSON) in
        let value: OrderedJSON
        switch question {
        case .choice(let instructions, let criteria):
            value = .object([
                ("type", .string("choice")), ("instructions", .string(instructions)),
                ("criteria", .object(criteria.entries.map { ($0.0, .string($0.1)) }))
            ])
        case .score(let instructions, let criteria):
            value = .object([
                ("type", .string("score")), ("instructions", .string(instructions)),
                ("criteria", .array(criteria.map(OrderedJSON.string)))
            ])
        case .bool(let instructions, let yes, let no):
            value = .object([
                ("type", .string("noul")), ("instructions", .string(instructions)),
                ("criteria", .object([("true", .string(yes)), ("false", .string(no))]))
            ])
        }
        return (id, value)
    }
    return .object([("state", state), ("questions", .object(questions))])
}

private func systemOnePayload(model: ClassifierModel, context: ClassifierContext,
                              transport: SystemOneTransport) -> OrderedJSON {
    let request = systemOneWireRequest(context)
    switch transport {
    case .typesafe:
        return .object([("model", .string(model.id))] + (request.objectEntries ?? []))
    case .cloudflare:
        return .object([("model", .string(model.id)), ("input", request)])
    }
}

private func systemOneURL(model: ClassifierModel, transport: SystemOneTransport) throws -> URL {
    let base = model.baseUrl.replacingOccurrences(of: "/+$", with: "", options: .regularExpression)
    guard let url = URL(string: base + "/" + transport.path), url.scheme != nil else {
        throw SystemOneError(message: "Invalid classifier base URL: \(model.baseUrl)")
    }
    return url
}

private func requiredNumber(_ value: Any?, label: String, field: String) throws -> Double {
    guard let number = value as? NSNumber,
          CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite else {
        throw SystemOneError(message: "\(label) returned an invalid \(field)")
    }
    return number.doubleValue
}

private func parseSystemOneAnswers(_ value: Any?, context: ClassifierContext,
                                   label: String) throws -> [String: ClassifierAnswer] {
    guard let wire = value as? [String: Any] else {
        throw SystemOneError(message: "\(label) returned an unexpected response")
    }
    var answers: [String: ClassifierAnswer] = [:]
    for (id, question) in context.questions.entries {
        guard let answer = wire[id] as? [String: Any] else {
            throw SystemOneError(message: "\(label) did not return an answer for \(id)")
        }
        switch question {
        case .choice:
            guard answer["type"] as? String == "choice", let choice = answer["choice"] as? String else {
                throw SystemOneError(message: "\(label) did not return a choice answer for \(id)")
            }
            guard let raw = answer["probabilities"] as? [String: Any] else {
                throw SystemOneError(message: "\(label) returned invalid probabilities for \(id)")
            }
            var probabilities: [String: Double] = [:]
            for (key, value) in raw {
                probabilities[key] = try requiredNumber(value, label: label, field: "probability for \(id).\(key)")
            }
            answers[id] = .choice(choice: choice, probabilities: probabilities,
                                  confidence: try requiredNumber(answer["confidence"], label: label, field: "confidence for \(id)"))
        case .score:
            guard answer["type"] as? String == "score" else {
                throw SystemOneError(message: "\(label) did not return a score answer for \(id)")
            }
            answers[id] = .score(score: try requiredNumber(answer["score"], label: label, field: "score for \(id)"),
                                 confidence: try requiredNumber(answer["confidence"], label: label, field: "confidence for \(id)"))
        case .bool:
            guard answer["type"] as? String == "noul" else {
                throw SystemOneError(message: "\(label) did not return a bool answer for \(id)")
            }
            answers[id] = .bool(probability: try requiredNumber(answer["noul"], label: label, field: "probability for \(id)"))
        }
    }
    return answers
}

private func parseSystemOneUsage(_ value: Any?, model: ClassifierModel) -> Usage? {
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

private func systemOneOutput(_ body: Any, transport: SystemOneTransport) throws -> [String: Any] {
    guard let root = body as? [String: Any] else {
        throw SystemOneError(message: "\(transport.label) returned an unexpected response")
    }
    if transport == .typesafe { return root }
    if let success = root["success"] as? Bool, success == false {
        let errors = root["errors"] as? [[String: Any]] ?? []
        let messages = errors.compactMap { $0["message"] as? String }
        throw SystemOneError(message: messages.isEmpty ? "Cloudflare Workers AI request failed"
                             : "Cloudflare Workers AI error: \(messages.joined(separator: "; "))")
    }
    guard let run = root["result"] as? [String: Any] else {
        throw SystemOneError(message: "Cloudflare Workers AI returned an unexpected response")
    }
    if run["answers"] != nil { return run }
    guard run["state"] as? String == "Completed" else {
        let state = (run["state"] as? String) ?? "undefined"
        throw SystemOneError(message: "Cloudflare Workers AI run did not complete (state: \(state))")
    }
    guard let result = run["result"] as? [String: Any] else {
        throw SystemOneError(message: "Cloudflare Workers AI returned an unexpected response")
    }
    return result
}

private func sendSystemOne(_ request: URLRequest, options: ClassifierOptions,
                           label: String) async throws -> (Data, ProviderHTTPResponse) {
    let client = options.httpClient ?? DefaultProviderHTTPClient(env: options.env)
    return try await retryProviderRequest(maxRetries: options.maxRetries ?? 2,
                                          maxRetryDelayMs: options.maxRetryDelayMs,
                                          signal: options.signal) {
        let operation: @Sendable () async throws -> (Data, ProviderHTTPResponse) = {
            let response = try await client.send(request)
            let data = try await collectProviderHTTPBody(response.body)
            guard (200..<300).contains(response.statusCode) else {
                throw SystemOneHTTPError(status: response.statusCode, headers: response.headers,
                                         body: String(data: data, encoding: .utf8) ?? "", label: label)
            }
            return (data, response)
        }
        guard let timeoutMs = options.timeoutMs else { return try await operation() }
        return try await withThrowingTaskGroup(of: (Data, ProviderHTTPResponse).self) { group in
            group.addTask(operation: operation)
            group.addTask {
                try await Task.sleep(for: .milliseconds(timeoutMs))
                throw SystemOneTimeoutError(timeoutMs: timeoutMs)
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }
}

func classifySystemOne(model: ClassifierModel, context: ClassifierContext,
                       options: ClassifierOptions?, transport: SystemOneTransport) async -> ClassifierResult {
    var output = ClassifierResult(api: model.api, provider: model.provider, model: model.id)
    do {
        guard model.api == transport.api else {
            throw SystemOneError(message: "Unsupported classifier API: \(model.api.rawValue)")
        }
        let options = options ?? ClassifierOptions()
        guard let apiKey = options.apiKey, !apiKey.isEmpty else {
            throw SystemOneError(message: "No API key for provider: \(model.provider)")
        }
        let resolved = resolveCloudflareModel(model, env: providerEnvironment(options.env))
        var payload = systemOnePayload(model: resolved, context: context, transport: transport)
        if let transformed = try await options.onPayload?(payload, resolved) { payload = transformed }
        var request = URLRequest(url: try systemOneURL(model: resolved, transport: transport))
        request.httpMethod = "POST"
        request.httpBody = Data(payload.serialized().utf8)
        if let timeoutMs = options.timeoutMs { request.timeoutInterval = Double(timeoutMs) / 1000 }
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        applyProviderHeaders(mergeProviderHeaders(resolved.headers, options.headers), to: &request)
        let (data, response) = try await sendSystemOne(request, options: options, label: transport.label)
        let body = try JSONSerialization.jsonObject(with: data)
        try await options.onResponse?(ResponseSnapshot(statusCode: response.statusCode, headers: response.headers), resolved)
        let result = try systemOneOutput(body, transport: transport)
        output.usage = parseSystemOneUsage(result["usage"], model: resolved)
        output.answers = try parseSystemOneAnswers(result["answers"], context: context, label: transport.label)
    } catch {
        output.stopReason = options?.signal?.isCancelled == true ? .aborted : .error
        output.errorMessage = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
    }
    return output
}

public func classifyTypeSafeSystemOne(model: ClassifierModel, context: ClassifierContext,
                                      options: ClassifierOptions? = nil) async -> ClassifierResult {
    await classifySystemOne(model: model, context: context, options: options, transport: .typesafe)
}

public func classifyCloudflareWorkersAISystemOne(model: ClassifierModel, context: ClassifierContext,
                                                  options: ClassifierOptions? = nil) async -> ClassifierResult {
    await classifySystemOne(model: model, context: context, options: options, transport: .cloudflare)
}
