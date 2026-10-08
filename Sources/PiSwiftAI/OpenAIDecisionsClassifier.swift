import Foundation

private let decisionsLabel = "OpenAI Decisions"

private func decisionsQuestion(name: String, question: ClassifierQuestion) -> OrderedJSON {
    switch question {
    case .choice(let instructions, let criteria):
        let choices = criteria.entries.map { value, description -> OrderedJSON in
            .object([("value", .string(value))] + (description.isEmpty ? [] : [("description", .string(description))]))
        }
        return .object([("type", .string("choice")), ("name", .string(name)),
                        ("instructions", .string(instructions)), ("choices", .array(choices))])
    case .score(let instructions, let criteria):
        return .object([("type", .string("score")), ("name", .string(name)),
                        ("instructions", .string(instructions)),
                        ("levels", .array(criteria.map { .object([("label", .string($0))]) }))])
    case .bool(let instructions, let yes, let no):
        var meanings: [String] = []
        if !yes.isEmpty { meanings.append("True means: \(yes)") }
        if !no.isEmpty { meanings.append("False means: \(no)") }
        let text = meanings.isEmpty ? instructions : instructions + "\n\n" + meanings.joined(separator: "\n")
        return .object([("type", .string("predicate")), ("name", .string(name)), ("instructions", .string(text))])
    }
}

private func decisionsInput(_ context: ClassifierContext) throws -> OrderedJSON {
    let state = OrderedJSON.fromFoundation(context.state.mapValues(\.value)).serialized(escapeSlashes: false)
    let images = context.images ?? []
    if images.isEmpty { return .string(state) }
    guard images.count <= 128 else {
        throw ClassifierError(message: "OpenAI Decisions accepts at most 128 images, got \(images.count)")
    }
    let parts: [OrderedJSON] = [.object([("type", .string("input_text")), ("text", .string(state))])]
        + images.map { .object([("type", .string("input_image")),
                               ("image_url", .string("data:\($0.mimeType);base64,\($0.data)"))]) }
    return .array([
        .object([("role", .string("user")), ("content", .array(parts))])
    ])
}

private func decisionsProbabilities(_ value: Any?, id: String) throws -> [String: Double] {
    guard let entries = value as? [Any] else {
        throw ClassifierError(message: "OpenAI Decisions returned invalid probabilities for \(id)")
    }
    var probabilities: [String: Double] = [:]
    for entry in entries {
        guard let entry = entry as? [String: Any], let key = entry["value"] as? String else {
            throw ClassifierError(message: "OpenAI Decisions returned invalid probabilities for \(id)")
        }
        probabilities[key] = try requiredNumber(entry["probability"], label: decisionsLabel, field: "probability for \(id).\(key)")
    }
    return probabilities
}

private func decisionsAnswers(_ value: Any?, context: ClassifierContext) throws -> [String: ClassifierAnswer] {
    guard let entries = value as? [Any] else {
        throw ClassifierError(message: "OpenAI Decisions returned an unexpected response")
    }
    var byName: [String: [String: Any]] = [:]
    for entry in entries {
        if let answer = entry as? [String: Any], let name = answer["name"] as? String { byName[name] = answer }
    }
    var answers: [String: ClassifierAnswer] = [:]
    for (id, question) in context.questions.entries {
        guard let answer = byName[id] else {
            throw ClassifierError(message: "OpenAI Decisions did not return an answer for \(id)")
        }
        if answer["type"] as? String == "refusal" {
            throw ClassifierError(message: "OpenAI Decisions refused to answer \(id)")
        }
        switch question {
        case .choice:
            guard answer["type"] as? String == "choice", let choice = answer["choice"] as? String else {
                throw ClassifierError(message: "OpenAI Decisions did not return a choice answer for \(id)")
            }
            answers[id] = .choice(choice: choice,
                probabilities: try decisionsProbabilities(answer["probabilities"], id: id),
                confidence: try requiredNumber(answer["confidence"], label: decisionsLabel, field: "confidence for \(id)"))
        case .score:
            guard answer["type"] as? String == "score" else {
                throw ClassifierError(message: "OpenAI Decisions did not return a score answer for \(id)")
            }
            answers[id] = .score(score: try requiredNumber(answer["score"], label: decisionsLabel, field: "score for \(id)"),
                confidence: try requiredNumber(answer["confidence"], label: decisionsLabel, field: "confidence for \(id)"))
        case .bool:
            guard answer["type"] as? String == "predicate" else {
                throw ClassifierError(message: "OpenAI Decisions did not return a predicate answer for \(id)")
            }
            answers[id] = .bool(probability: try requiredNumber(answer["probability"], label: decisionsLabel, field: "probability for \(id)"))
        }
    }
    return answers
}

/// Classification through OpenAI's Decisions API. This route requires an OpenAI API key.
public func classifyOpenAIDecisions(model: ClassifierModel, context: ClassifierContext,
                                   options: ClassifierOptions? = nil) async -> ClassifierResult {
    var output = ClassifierResult(api: model.api, provider: model.provider, model: model.id)
    do {
        guard model.api == .openAIDecisions else {
            throw ClassifierError(message: "Unsupported classifier API: \(model.api.rawValue)")
        }
        let base = model.baseUrl.replacingOccurrences(of: "/+$", with: "", options: .regularExpression)
        guard let baseURL = URL(string: base + "/"), baseURL.scheme != nil,
              let url = URL(string: "decisions", relativeTo: baseURL)?.absoluteURL else {
            throw ClassifierError(message: "Invalid classifier base URL: \(model.baseUrl)")
        }
        let payload: OrderedJSON = .object([
            ("model", .string(model.id)), ("input", try decisionsInput(context)),
            ("questions", .array(context.questions.entries.map { decisionsQuestion(name: $0.0, question: $0.1) }))
        ])
        let response = try await postClassifierRequest(label: decisionsLabel, url: { url }, model: model,
            payload: payload, options: options ?? ClassifierOptions(), noRetryStatuses: [504],
            escapeSlashes: false, allowFragments: true, useStatusErrorMessage: true)
        guard let body = response.value as? [String: Any] else {
            throw ClassifierError(message: "OpenAI Decisions returned an unexpected response")
        }
        output.usage = parseClassifierUsage(body["usage"], model: model)
        output.answers = try decisionsAnswers(body["answers"], context: context)
    } catch {
        output.answers = [:]
        output.stopReason = options?.signal?.isCancelled == true ? .aborted : .error
        if let error = error as? ClassifierHTTPError {
            output.errorMessage = error.status == 504
                ? "OpenAI Decisions error (504): the request timed out at the gateway. Very large inputs (above roughly 600K tokens) currently exceed its time limit."
                : error.formattedMessage(preserveEmbeddedBody: true)
        } else {
            output.errorMessage = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
        }
    }
    return output
}
