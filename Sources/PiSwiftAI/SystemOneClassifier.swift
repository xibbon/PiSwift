import Foundation

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

    func detectedCompat(model: ClassifierModel) -> (imageInput: SystemOneImageInput, sendImageOptInHeader: Bool) {
        switch self {
        case .typesafe:
            return model.provider == "openrouter" || model.baseUrl.contains("openrouter.ai")
                ? (.stateImageURLs, false) : (.assets, true)
        case .cloudflare:
            return (model.id.hasPrefix("@cf/cloudflare/clef") ? .images : .assets, false)
        }
    }
}

private func systemOneWireRequest(_ context: ClassifierContext, model: ClassifierModel,
                                  transport: SystemOneTransport) throws -> OrderedJSON {
    var state = OrderedJSON.fromFoundation(context.state.mapValues(\.value))
    var imageFields: [(String, OrderedJSON)] = []
    if let images = context.images, !images.isEmpty {
        guard model.input.contains(.image) else {
            throw ClassifierError(message: "\(transport.label) does not support image input for \(model.id)")
        }
        let imageInput = model.compat?.imageInput ?? transport.detectedCompat(model: model).imageInput
        switch imageInput {
        case .assets:
            var assets: [(String, OrderedJSON)] = []
            for (index, image) in images.enumerated() {
                let format: String
                switch image.mimeType {
                case "image/png": format = "png"
                case "image/jpeg": format = "jpeg"
                default:
                    throw ClassifierError(message: "\(transport.label) accepts PNG and JPEG images for \(model.id), got \(image.mimeType)")
                }
                assets.append(("<image-\(index + 1)>", .object([
                    ("type", .string("image")), ("format", .string(format)),
                    ("data_base64", .string(image.data))
                ])))
            }
            state = .array(assets.map { .string($0.0) } + [state])
            imageFields = [("assets", .object(assets))]
        case .images:
            guard images.count <= 4 else {
                throw ClassifierError(message: "\(transport.label) accepts at most 4 images for \(model.id), got \(images.count)")
            }
            let urls = try images.map { image -> OrderedJSON in
                guard ["image/png", "image/jpeg", "image/webp"].contains(image.mimeType) else {
                    throw ClassifierError(message: "\(transport.label) accepts PNG, JPEG, and WebP images for \(model.id), got \(image.mimeType)")
                }
                return .string("data:\(image.mimeType);base64,\(image.data)")
            }
            imageFields = [("images", .array(urls))]
        case .stateImageURLs:
            state = .array(images.map { image in
                .object([
                    ("type", .string("image_url")),
                    ("image_url", .object([("url", .string("data:\(image.mimeType);base64,\(image.data)"))]))
                ])
            } + [state])
        }
    }
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
    return .object([("state", state), ("questions", .object(questions))] + imageFields)
}

private func systemOnePayload(model: ClassifierModel, context: ClassifierContext,
                              transport: SystemOneTransport) throws -> OrderedJSON {
    let request = try systemOneWireRequest(context, model: model, transport: transport)
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
        throw ClassifierError(message: "Invalid classifier base URL: \(model.baseUrl)")
    }
    return url
}

private func parseSystemOneAnswers(_ value: Any?, context: ClassifierContext,
                                   label: String) throws -> [String: ClassifierAnswer] {
    guard let wire = value as? [String: Any] else {
        throw ClassifierError(message: "\(label) returned an unexpected response")
    }
    var answers: [String: ClassifierAnswer] = [:]
    for (id, question) in context.questions.entries {
        guard let answer = wire[id] as? [String: Any] else {
            throw ClassifierError(message: "\(label) did not return an answer for \(id)")
        }
        switch question {
        case .choice:
            guard answer["type"] as? String == "choice", let choice = answer["choice"] as? String else {
                throw ClassifierError(message: "\(label) did not return a choice answer for \(id)")
            }
            guard let raw = answer["probabilities"] as? [String: Any] else {
                throw ClassifierError(message: "\(label) returned invalid probabilities for \(id)")
            }
            var probabilities: [String: Double] = [:]
            for (key, value) in raw {
                probabilities[key] = try requiredNumber(value, label: label, field: "probability for \(id).\(key)")
            }
            answers[id] = .choice(choice: choice, probabilities: probabilities,
                                  confidence: try requiredNumber(answer["confidence"], label: label, field: "confidence for \(id)"))
        case .score:
            guard answer["type"] as? String == "score" else {
                throw ClassifierError(message: "\(label) did not return a score answer for \(id)")
            }
            answers[id] = .score(score: try requiredNumber(answer["score"], label: label, field: "score for \(id)"),
                                 confidence: try requiredNumber(answer["confidence"], label: label, field: "confidence for \(id)"))
        case .bool:
            guard answer["type"] as? String == "noul" else {
                throw ClassifierError(message: "\(label) did not return a bool answer for \(id)")
            }
            answers[id] = .bool(probability: try requiredNumber(answer["noul"], label: label, field: "probability for \(id)"))
        }
    }
    return answers
}

private func systemOneOutput(_ body: Any, transport: SystemOneTransport) throws -> [String: Any] {
    guard let root = body as? [String: Any] else {
        throw ClassifierError(message: "\(transport.label) returned an unexpected response")
    }
    if transport == .typesafe { return root }
    if let success = root["success"] as? Bool, success == false {
        let errors = root["errors"] as? [[String: Any]] ?? []
        let messages = errors.compactMap { $0["message"] as? String }
        throw ClassifierError(message: messages.isEmpty ? "Cloudflare Workers AI request failed"
                             : "Cloudflare Workers AI error: \(messages.joined(separator: "; "))")
    }
    guard let run = root["result"] as? [String: Any] else {
        throw ClassifierError(message: "Cloudflare Workers AI returned an unexpected response")
    }
    if run["answers"] != nil { return run }
    guard run["state"] as? String == "Completed" else {
        let state = (run["state"] as? String) ?? "undefined"
        throw ClassifierError(message: "Cloudflare Workers AI run did not complete (state: \(state))")
    }
    guard let result = run["result"] as? [String: Any] else {
        throw ClassifierError(message: "Cloudflare Workers AI returned an unexpected response")
    }
    return result
}

func classifySystemOne(model: ClassifierModel, context: ClassifierContext,
                       options: ClassifierOptions?, transport: SystemOneTransport) async -> ClassifierResult {
    var output = ClassifierResult(api: model.api, provider: model.provider, model: model.id)
    do {
        guard model.api == transport.api else {
            throw ClassifierError(message: "Unsupported classifier API: \(model.api.rawValue)")
        }
        let payload = try systemOnePayload(model: model, context: context, transport: transport)
        var options = options ?? ClassifierOptions()
        if let images = context.images, !images.isEmpty,
           model.compat?.sendImageOptInHeader ?? transport.detectedCompat(model: model).sendImageOptInHeader {
            options.headers = mergeProviderHeaders(["TypeSafe-Danger-Zone-Images": "true"], options.headers)
        }
        guard let apiKey = options.apiKey, !apiKey.isEmpty else {
            throw ClassifierError(message: "No API key for provider: \(model.provider)")
        }
        let resolved = resolveCloudflareModel(model, env: providerEnvironment(options.env))
        let body = try await postClassifierRequest(label: transport.label,
            url: { try systemOneURL(model: resolved, transport: transport) }, model: resolved,
            payload: payload, options: options)
        let result = try systemOneOutput(body.value, transport: transport)
        output.usage = parseClassifierUsage(result["usage"], model: resolved)
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
