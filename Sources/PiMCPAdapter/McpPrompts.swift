import Foundation
import PiSwiftCodingAgent

struct ParsedPromptArguments: Sendable {
    var positional: [String]
    var named: [String: String]
}

enum ResolvedPromptArguments: Sendable {
    case success([String: String])
    case failure(String)
}

func parsePromptArguments(_ input: String) -> ParsedPromptArguments {
    var tokens: [String] = []
    var current = ""
    var quote: Character?
    var escaped = false
    for character in input {
        if escaped {
            current.append(character)
            escaped = false
        } else if character == "\\" && quote != "'" {
            escaped = true
        } else if quote != nil {
            current.append(character)
            if character == quote { quote = nil }
        } else if character == "\"" || character == "'" {
            quote = character
            current.append(character)
        } else if character.isWhitespace {
            if !current.isEmpty {
                tokens.append(current)
                current = ""
            }
        } else {
            current.append(character)
        }
    }
    if !current.isEmpty { tokens.append(current) }

    var positional: [String] = []
    var named: [String: String] = [:]
    for token in tokens {
        if let index = unquotedEquals(in: token), index > token.startIndex {
            let key = String(token[..<index]).trimmingCharacters(in: .whitespaces)
            if !key.isEmpty {
                named[key] = stripPromptQuotes(String(token[token.index(after: index)...]).trimmingCharacters(in: .whitespaces))
                continue
            }
        }
        positional.append(stripPromptQuotes(token))
    }
    return ParsedPromptArguments(positional: positional, named: named)
}

func resolvePromptArguments(_ parsed: ParsedPromptArguments, metadata: PromptMetadata) -> ResolvedPromptArguments {
    var values: [String: String] = [:]
    for (index, argument) in metadata.arguments.enumerated() {
        let value = parsed.named[argument.name] ?? parsed.positional[safe: index]
        if let value, !value.isEmpty { values[argument.name] = value }
        if argument.required == true && values[argument.name] == nil {
            let usage = metadata.arguments.map { $0.required == true ? "<\($0.name)>" : "[\($0.name)]" }.joined(separator: " ")
            return .failure("Missing required argument: \(argument.name). Usage: /\(metadata.commandName) \(usage)")
        }
    }
    for (key, value) in parsed.named where values[key] == nil {
        values[key] = value
    }
    return .success(values)
}

func formatPromptResult(_ result: McpPromptResult) -> String {
    result.messages.compactMap { message -> String? in
        let text = transformMcpContent(message.content).compactMap { block -> String? in
            if case .text(let value) = block { return value.text }
            if case .image(let image) = block { return "[image \(image.mimeType)]" }
            return nil
        }.joined(separator: "\n")
        guard !text.isEmpty else { return nil }
        return result.messages.count == 1 && message.role == "user" ? text : "[\(message.role)] \(text)"
    }.joined(separator: "\n\n")
}

func registerPromptCommand(
    _ pi: HookAPI,
    metadata: PromptMetadata,
    getState: @escaping @Sendable () async -> McpExtensionState?
) {
    pi.registerCommand(metadata.commandName, description: "MCP: \(metadata.description)") { arguments, context in
        guard let state = await getState() else {
            await context.ui.notify("MCP not initialized", .warning)
            return
        }
        guard let definition = state.config.mcpServers[metadata.serverName], definition.disabled != true else {
            await context.ui.notify("MCP server \"\(metadata.serverName)\" is not available", .warning)
            return
        }
        let active = state.promptMetadata.withLock { metadataByServer in
            metadataByServer[metadata.serverName]?.first { $0.originalName == metadata.originalName }
        } ?? metadata
        let resolved: [String: String]
        switch resolvePromptArguments(parsePromptArguments(arguments), metadata: active) {
        case .success(let values):
            resolved = values
        case .failure(let message):
            await context.ui.notify(message, .warning)
            return
        }
        do {
            if !(await state.manager.isConnected(name: active.serverName)) {
                _ = try await state.manager.connect(name: active.serverName, definition: definition)
                if definition.lifecycle == "lazy-keep-alive" {
                    await state.lifecycle.markKeepAlive(name: active.serverName, definition: definition)
                }
            }
            guard let connection = await state.manager.getConnection(name: active.serverName) else {
                throw McpError.connectionFailed("Not connected to \(active.serverName)")
            }
            let prompt = try await connection.client.getPrompt(name: active.originalName, arguments: resolved)
            let text = formatPromptResult(prompt)
            guard !text.isEmpty else {
                await context.ui.notify("MCP prompt \"\(active.originalName)\" returned no text content", .warning)
                return
            }
            pi.sendUserMessage(text, options: HookSendMessageOptions(triggerTurn: true, deliverAs: .steer))
        } catch {
            await context.ui.notify("MCP prompt \"\(active.originalName)\" failed: \(error)", .error)
        }
    }
}

private func unquotedEquals(in value: String) -> String.Index? {
    var quote: Character?
    for index in value.indices {
        let character = value[index]
        if quote != nil {
            if character == quote { quote = nil }
        } else if character == "\"" || character == "'" {
            quote = character
        } else if character == "=" {
            return index
        }
    }
    return nil
}

private func stripPromptQuotes(_ value: String) -> String {
    guard value.count >= 2, let first = value.first, let last = value.last,
          (first == "\"" || first == "'") && first == last else { return value }
    return String(value.dropFirst().dropLast())
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
