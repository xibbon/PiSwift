import Foundation
import ArgumentParser
import PiSwiftAI

@main
struct PiAICLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "pi-ai",
        abstract: "PiSwiftAI command line interface",
        subcommands: [Complete.self, Stream.self, Models.self],
        defaultSubcommand: Complete.self
    )

    struct CommonOptions: ParsableArguments {
        @Option(help: "Provider id (openai, openai-codex, or anthropic)")
        var provider: String = "openai"

        @Option(help: "Model id")
        var model: String = "gpt-4o-mini"

        @Option(help: "System prompt")
        var system: String?

        @Option(help: "API key override")
        var apiKey: String?

        @Option(help: "Temperature")
        var temperature: Double?

        @Option(name: .customLong("max-tokens"), help: "Max tokens")
        var maxTokens: Int?

        @Option(help: "Reasoning effort (minimal, low, medium, high, xhigh)")
        var reasoning: String?

        @Argument(help: "Prompt text (reads stdin if omitted)")
        var prompt: String?
    }

    struct Complete: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Run a non-streaming completion")

        @OptionGroup var options: CommonOptions

        mutating func run() async throws {
            let prompt = readPrompt(from: options.prompt)
            let model = try resolveModel(provider: options.provider, modelId: options.model)
            let context = Context(systemPrompt: options.system, messages: [.user(UserMessage(content: .text(prompt)))])
            let streamOptions = StreamOptions(
                temperature: options.temperature,
                maxTokens: options.maxTokens,
                apiKey: options.apiKey
            )
            let response = try await complete(model: model, context: context, options: streamOptions)
            let text = responseText(from: response)
            if !text.isEmpty {
                print(text)
            }
        }
    }

    struct Stream: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Stream a completion")

        @OptionGroup var options: CommonOptions

        mutating func run() async throws {
            let prompt = readPrompt(from: options.prompt)
            let model = try resolveModel(provider: options.provider, modelId: options.model)
            let context = Context(systemPrompt: options.system, messages: [.user(UserMessage(content: .text(prompt)))])
            let reasoning = parseReasoning(options.reasoning)
            let streamOptions = SimpleStreamOptions(
                temperature: options.temperature,
                maxTokens: options.maxTokens,
                apiKey: options.apiKey,
                reasoning: reasoning
            )

            let eventStream = try streamSimple(model: model, context: context, options: streamOptions)
            for await event in eventStream {
                switch event {
                case .textDelta(_, let delta, _):
                    print(delta, terminator: "")
                    fflush(stdout)
                case .done:
                    print("")
                case .error(_, let error):
                    let text = responseText(from: error)
                    if !text.isEmpty {
                        print(text)
                    }
                default:
                    break
                }
            }
        }
    }

    struct Models: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List available models")

        @Option(help: "Provider id")
        var provider: String?

        func run() throws {
            if let provider {
                if let known = KnownProvider(rawValue: provider) {
                    let models = getModels(provider: known)
                    for model in models {
                        print("\(model.id)\t\(model.name)")
                    }
                } else {
                    throw ValidationError("Unknown provider: \(provider)")
                }
            } else {
                for provider in getProviders() {
                    print(provider.rawValue)
                }
            }
        }
    }
}

private func readPrompt(from argument: String?) -> String {
    if let argument, !argument.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        return argument
    }

    let data = FileHandle.standardInput.readDataToEndOfFile()
    if !data.isEmpty {
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    return ""
}

private func resolveModel(provider: String, modelId: String) throws -> Model {
    if let model = getModel(provider: provider, modelId: modelId) {
        return model
    }
    if let known = KnownProvider(rawValue: provider) {
        let available = getModels(provider: known).map(\.id).sorted().joined(separator: ", ")
        throw ValidationError("Unknown model '\(modelId)' for provider '\(provider)'. Available models: \(available)")
    }
    throw ValidationError("Unknown provider '\(provider)'")
}

private func parseReasoning(_ value: String?) -> ReasoningEffort? {
    guard let value else { return nil }
    return ReasoningEffort(rawValue: value)
}

private func responseText(from message: AssistantMessage) -> String {
    message.content.compactMap { block in
        if case .text(let text) = block { return text.text }
        return nil
    }.joined()
}
