import Foundation

private enum RawResponsesSlotKind {
    case thinking
    case text
    case function
    case grammar
}

private struct RawResponsesSlot {
    let kind: RawResponsesSlotKind
    let contentIndex: Int
    var partialInput: String
    let inputProperty: String?
    var jsonBuffer: GrammarToolInputJsonBuffer
}

func processRawOpenAIResponsesStream(
    request: URLRequest,
    model: Model,
    httpClient: (any ProviderHTTPClient)?,
    signal: CancellationToken?,
    maxRetries: Int?,
    maxRetryDelayMs: Int?,
    onResponse: ResponseHandler?,
    serviceTier: OpenAIServiceTier?,
    grammarToolInputProperties: [String: String],
    stream: AssistantMessageEventStream,
    output: inout AssistantMessage
) async throws {
    let client = httpClient ?? DefaultProviderHTTPClient()
    let response = try await retryProviderRequest(
        maxRetries: maxRetries,
        maxRetryDelayMs: maxRetryDelayMs,
        signal: signal
    ) {
        let response = try await client.send(request)
        guard (200..<300).contains(response.statusCode) else {
            throw try await providerHTTPError(from: response)
        }
        return response
    }
    onResponse?(ResponseSnapshot(statusCode: response.statusCode, headers: response.headers))

    stream.push(.start(partial: output))
    var slots: [Int: RawResponsesSlot] = [:]

    func outputIndex(_ event: [String: Any]) -> Int { event["output_index"] as? Int ?? 0 }

    func startSlot(index: Int, item: [String: Any]) {
        guard slots[index] == nil, let type = item["type"] as? String else { return }
        let contentIndex = output.content.count
        switch type {
        case "reasoning":
            output.content.append(.thinking(ThinkingContent(thinking: "")))
            slots[index] = RawResponsesSlot(
                kind: .thinking,
                contentIndex: contentIndex,
                partialInput: "",
                inputProperty: nil,
                jsonBuffer: GrammarToolInputJsonBuffer()
            )
            stream.push(.thinkingStart(contentIndex: contentIndex, partial: output))
        case "message":
            output.content.append(.text(TextContent(text: "")))
            slots[index] = RawResponsesSlot(
                kind: .text,
                contentIndex: contentIndex,
                partialInput: "",
                inputProperty: nil,
                jsonBuffer: GrammarToolInputJsonBuffer()
            )
            stream.push(.textStart(contentIndex: contentIndex, partial: output))
        case "function_call":
            let callId = item["call_id"] as? String ?? ""
            let itemId = item["id"] as? String ?? ""
            let arguments = item["arguments"] as? String ?? ""
            let tool = ToolCall(
                id: "\(callId)|\(itemId)",
                name: item["name"] as? String ?? "",
                arguments: parseStreamingJSON(arguments)
            )
            output.content.append(.toolCall(tool))
            slots[index] = RawResponsesSlot(
                kind: .function,
                contentIndex: contentIndex,
                partialInput: arguments,
                inputProperty: nil,
                jsonBuffer: GrammarToolInputJsonBuffer()
            )
            stream.push(.toolCallStart(contentIndex: contentIndex, partial: output))
        case "custom_tool_call":
            let callId = item["call_id"] as? String ?? ""
            let itemId = item["id"] as? String ?? ""
            let name = item["name"] as? String ?? ""
            let input = item["input"] as? String ?? ""
            let property = grammarToolInputProperties[name] ?? "input"
            let tool = ToolCall(
                id: "\(callId)|\(itemId)",
                name: name,
                arguments: [property: AnyCodable(input)]
            )
            output.content.append(.toolCall(tool))
            slots[index] = RawResponsesSlot(
                kind: .grammar,
                contentIndex: contentIndex,
                partialInput: input,
                inputProperty: property,
                jsonBuffer: GrammarToolInputJsonBuffer()
            )
            stream.push(.toolCallStart(contentIndex: contentIndex, partial: output))
        default:
            break
        }
    }

    func appendGrammar(index: Int, nextInput: String, close: Bool) throws {
        guard var slot = slots[index], slot.kind == .grammar,
              let property = slot.inputProperty,
              case .toolCall(var tool) = output.content[slot.contentIndex] else { return }
        if let delta = try appendGrammarToolInputJsonDelta(
            buffer: &slot.jsonBuffer,
            inputProperty: property,
            nextInput: nextInput,
            close: close
        ) {
            stream.push(.toolCallDelta(contentIndex: slot.contentIndex, delta: delta, partial: output))
        }
        slot.partialInput = nextInput
        tool.arguments = [property: AnyCodable(nextInput)]
        output.content[slot.contentIndex] = .toolCall(tool)
        slots[index] = slot
    }

    for try await frame in iterateSseEvents(body: response.body, signal: signal) {
        if signal?.isCancelled == true { throw CancellationError() }
        guard frame.data != "[DONE]", let data = frame.data.data(using: .utf8),
              let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = event["type"] as? String else { continue }
        let index = outputIndex(event)

        switch type {
        case "response.created":
            output.responseId = (event["response"] as? [String: Any])?["id"] as? String
        case "response.output_item.added":
            if let item = event["item"] as? [String: Any] { startSlot(index: index, item: item) }
        case "response.reasoning_summary_text.delta", "response.reasoning_text.delta":
            guard let slot = slots[index], slot.kind == .thinking,
                  let delta = event["delta"] as? String,
                  case .thinking(var thinking) = output.content[slot.contentIndex] else { continue }
            thinking.thinking += delta
            output.content[slot.contentIndex] = .thinking(thinking)
            stream.push(.thinkingDelta(contentIndex: slot.contentIndex, delta: delta, partial: output))
        case "response.reasoning_summary_part.done":
            guard let slot = slots[index], slot.kind == .thinking,
                  case .thinking(var thinking) = output.content[slot.contentIndex] else { continue }
            thinking.thinking += "\n\n"
            output.content[slot.contentIndex] = .thinking(thinking)
            stream.push(.thinkingDelta(contentIndex: slot.contentIndex, delta: "\n\n", partial: output))
        case "response.output_text.delta", "response.refusal.delta":
            guard let slot = slots[index], slot.kind == .text,
                  let delta = event["delta"] as? String,
                  case .text(var text) = output.content[slot.contentIndex] else { continue }
            text.text += delta
            output.content[slot.contentIndex] = .text(text)
            stream.push(.textDelta(contentIndex: slot.contentIndex, delta: delta, partial: output))
        case "response.function_call_arguments.delta":
            guard var slot = slots[index], slot.kind == .function,
                  let delta = event["delta"] as? String,
                  case .toolCall(var tool) = output.content[slot.contentIndex] else { continue }
            slot.partialInput += delta
            tool.arguments = parseStreamingJSON(slot.partialInput)
            output.content[slot.contentIndex] = .toolCall(tool)
            slots[index] = slot
            stream.push(.toolCallDelta(contentIndex: slot.contentIndex, delta: delta, partial: output))
        case "response.function_call_arguments.done":
            guard var slot = slots[index], slot.kind == .function,
                  let arguments = event["arguments"] as? String,
                  case .toolCall(var tool) = output.content[slot.contentIndex] else { continue }
            if let delta = finalToolCallArgumentsDelta(previous: slot.partialInput, final: arguments) {
                stream.push(.toolCallDelta(contentIndex: slot.contentIndex, delta: delta, partial: output))
            }
            slot.partialInput = arguments
            tool.arguments = parseStreamingJSON(arguments)
            output.content[slot.contentIndex] = .toolCall(tool)
            slots[index] = slot
        case "response.custom_tool_call_input.delta":
            guard let slot = slots[index], let delta = event["delta"] as? String else { continue }
            try appendGrammar(index: index, nextInput: slot.partialInput + delta, close: false)
        case "response.custom_tool_call_input.done":
            try appendGrammar(index: index, nextInput: event["input"] as? String ?? "", close: true)
        case "response.output_item.done":
            guard let item = event["item"] as? [String: Any] else { continue }
            startSlot(index: index, item: item)
            guard let slot = slots[index] else { continue }
            switch slot.kind {
            case .thinking:
                if case .thinking(var thinking) = output.content[slot.contentIndex] {
                    if let encoded = try? JSONSerialization.data(withJSONObject: item),
                       let signature = String(data: encoded, encoding: .utf8) {
                        thinking.thinkingSignature = signature
                    }
                    output.content[slot.contentIndex] = .thinking(thinking)
                    stream.push(.thinkingEnd(contentIndex: slot.contentIndex, content: thinking.thinking, partial: output))
                }
            case .text:
                if case .text(var text) = output.content[slot.contentIndex] {
                    text.textSignature = (item["id"] as? String).map { encodeTextSignatureV1(id: $0) }
                    output.content[slot.contentIndex] = .text(text)
                    stream.push(.textEnd(contentIndex: slot.contentIndex, content: text.text, partial: output))
                }
            case .function:
                if case .toolCall(var tool) = output.content[slot.contentIndex] {
                    let arguments = item["arguments"] as? String ?? slot.partialInput
                    tool.arguments = parseStreamingJSON(arguments)
                    output.content[slot.contentIndex] = .toolCall(tool)
                    stream.push(.toolCallEnd(contentIndex: slot.contentIndex, toolCall: tool, partial: output))
                }
            case .grammar:
                try appendGrammar(
                    index: index,
                    nextInput: item["input"] as? String ?? slot.partialInput,
                    close: true
                )
                if case .toolCall(let tool) = output.content[slot.contentIndex] {
                    stream.push(.toolCallEnd(contentIndex: slot.contentIndex, toolCall: tool, partial: output))
                }
            }
            slots.removeValue(forKey: index)
        case "response.completed", "response.incomplete":
            if let response = event["response"] as? [String: Any] {
                output.responseId = response["id"] as? String ?? output.responseId
                applyRawResponsesUsage(response["usage"], model: model, serviceTier: serviceTier, output: &output)
                let status = response["status"] as? String ?? (type == "response.completed" ? "completed" : "incomplete")
                let reason = (response["incomplete_details"] as? [String: Any])?["reason"] as? String
                output.rawStopReason = reason.map { "\(status).\($0)" } ?? status
                let result = mapResponsesStopReason(status, incompleteReason: reason)
                output.stopReason = result.stopReason
                output.errorMessage = result.errorMessage
                if output.stopReason == .stop,
                   output.content.contains(where: { if case .toolCall = $0 { true } else { false } }) {
                    output.stopReason = .toolUse
                }
            }
        case "response.failed":
            throw ValidationError.constrainedSampling("OpenAI Responses request failed")
        case "error":
            throw ValidationError.constrainedSampling(event["message"] as? String ?? "OpenAI Responses request failed")
        default:
            break
        }
    }
}

func finishRawResponsesOutput(
    output: AssistantMessage,
    signal: CancellationToken?,
    providerName: String
) throws {
    if signal?.isCancelled == true { throw CancellationError() }
    if output.stopReason == .pending {
        throw ValidationError.constrainedSampling("\(providerName) stream ended without a stop reason")
    }
    if output.stopReason == .aborted { throw CancellationError() }
    if output.stopReason == .error {
        throw ValidationError.constrainedSampling(output.errorMessage ?? "Provider returned an error stop reason")
    }
}

private func applyRawResponsesUsage(
    _ value: Any?,
    model: Model,
    serviceTier: OpenAIServiceTier?,
    output: inout AssistantMessage
) {
    guard let usage = value as? [String: Any] else { return }
    let inputDetails = usage["input_tokens_details"] as? [String: Any]
    let outputDetails = usage["output_tokens_details"] as? [String: Any]
    let cached = inputDetails?["cached_tokens"] as? Int ?? 0
    let cacheWrite = inputDetails?["cache_write_tokens"] as? Int ?? 0
    let input = usage["input_tokens"] as? Int ?? 0
    let generated = usage["output_tokens"] as? Int ?? 0
    output.usage = Usage(
        input: max(0, input - cached - cacheWrite),
        output: generated,
        cacheRead: cached,
        cacheWrite: cacheWrite,
        reasoning: outputDetails?["reasoning_tokens"] as? Int,
        totalTokens: usage["total_tokens"] as? Int ?? input + generated
    )
    calculateCost(model: model, usage: &output.usage)
    applyServiceTierPricing(&output.usage, serviceTier: serviceTier, model: model)
}
