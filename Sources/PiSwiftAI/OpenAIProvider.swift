import Foundation

@available(*, deprecated, message: "Use stream(...) or streamSimple(...)")
public func streamOpenAI(
    model: Model,
    context: Context,
    options: OpenAIOptions
) -> AssistantMessageEventStream {
    let streamOptions = StreamOptions(
        temperature: options.temperature,
        maxTokens: options.maxTokens,
        signal: options.signal,
        apiKey: options.apiKey
    )

    do {
        return try stream(model: model, context: context, options: streamOptions)
    } catch {
        let stream = AssistantMessageEventStream()
        Task {
            let message = AssistantMessage(
                content: [],
                api: model.api,
                provider: model.provider,
                model: model.id,
                usage: Usage(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0),
                stopReason: .error,
                errorMessage: retryAwareErrorDescription(error)
            )
            stream.push(.error(reason: .error, error: message))
            stream.end()
        }
        return stream
    }
}
