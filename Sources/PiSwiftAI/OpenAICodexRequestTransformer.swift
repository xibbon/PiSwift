import Foundation

struct OpenAICodexRequestOptions: Sendable {
    var reasoningEffort: ThinkingLevel?
    var reasoningSummary: OpenAICodexReasoningSummary?
    var textVerbosity: OpenAICodexTextVerbosity?
    var include: [String]?
}

func transformCodexRequestBody(
    _ body: inout [String: Any],
    options: OpenAICodexRequestOptions,
    prompt: OpenAICodexSystemPrompt?
) {
    body["store"] = false
    body["stream"] = true

    if var inputItems = body["input"] as? [[String: Any]] {
        inputItems = filterCodexInput(inputItems)
        inputItems = normalizeCodexToolOutputs(inputItems)

        if let prompt, !prompt.developerMessages.isEmpty {
            let developerMessages: [[String: Any]] = prompt.developerMessages.map { text in
                [
                    "type": "message",
                    "role": "developer",
                    "content": [
                        [
                            "type": "input_text",
                            "text": text
                        ]
                    ],
                ]
            }
            inputItems = developerMessages + inputItems
        }

        body["input"] = inputItems
    }

    if let effort = options.reasoningEffort {
        let model = (body["model"] as? String) ?? ""
        let summary = options.reasoningSummary?.rawValue ?? "auto"
        let config: [String: Any] = [
            "effort": clampCodexReasoningEffort(model: model, effort: effort),
            "summary": summary,
        ]
        var reasoning = (body["reasoning"] as? [String: Any]) ?? [:]
        for (key, value) in config {
            reasoning[key] = value
        }
        body["reasoning"] = reasoning
    } else {
        body.removeValue(forKey: "reasoning")
    }

    var text = (body["text"] as? [String: Any]) ?? [:]
    text["verbosity"] = (options.textVerbosity ?? .low).rawValue
    body["text"] = text

    var include = options.include ?? []
    include.append("reasoning.encrypted_content")
    body["include"] = Array(Set(include))

    body.removeValue(forKey: "max_output_tokens")
    body.removeValue(forKey: "max_completion_tokens")
}

private func filterCodexInput(_ input: [[String: Any]]) -> [[String: Any]] {
    input.compactMap { item in
        if let type = item["type"] as? String, type == "item_reference" {
            return nil
        }
        var cleaned = item
        cleaned.removeValue(forKey: "id")
        return cleaned
    }
}

private func normalizeCodexToolOutputs(_ input: [[String: Any]]) -> [[String: Any]] {
    let functionCallIds = Set(input.compactMap { item -> String? in
        guard let type = item["type"] as? String, type == "function_call" else { return nil }
        return item["call_id"] as? String
    })

    return input.map { item in
        guard let type = item["type"] as? String, type == "function_call_output",
              let callId = item["call_id"] as? String,
              !functionCallIds.contains(callId) else {
            return item
        }

        let toolName = (item["name"] as? String) ?? "tool"
        let output = item["output"]
        var text: String
        if let output = output as? String {
            text = output
        } else if let output {
            if let data = try? JSONSerialization.data(withJSONObject: output, options: []),
               let serialized = String(data: data, encoding: .utf8) {
                text = serialized
            } else {
                text = String(describing: output)
            }
        } else {
            text = ""
        }

        if text.count > 16000 {
            text = "\(text.prefix(16000))\n...[truncated]"
        }

        return [
            "type": "message",
            "role": "assistant",
            "content": "[Previous \(toolName) result; call_id=\(callId)]: \(text)",
        ]
    }
}

private func clampCodexReasoningEffort(model: String, effort: ThinkingLevel) -> String {
    let modelId = model.split(separator: "/").last.map(String.init) ?? model
    let raw = effort.rawValue
    if (modelId.hasPrefix("gpt-5.2") || modelId.hasPrefix("gpt-5.3")) && raw == "minimal" {
        return "low"
    }
    if modelId == "gpt-5.1", raw == "xhigh" {
        return "high"
    }
    if modelId == "gpt-5.1-codex-mini" {
        return (raw == "high" || raw == "xhigh") ? "high" : "medium"
    }
    return raw
}
