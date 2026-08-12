import Foundation
import PiSwiftAI
import PiSwiftAgent

enum CompactionError: LocalizedError, Sendable {
    case summarizationFailed(String)

    var errorDescription: String? {
        switch self {
        case .summarizationFailed(let message):
            return "Summarization failed: \(message)"
        }
    }
}

public struct CompactionDetails: Sendable {
    public var readFiles: [String]
    public var modifiedFiles: [String]
}

public struct CompactionResult: Sendable {
    public var summary: String
    public var firstKeptEntryId: String
    public var tokensBefore: Int
    public var details: AnyCodable?

    public init(summary: String, firstKeptEntryId: String, tokensBefore: Int, details: AnyCodable? = nil) {
        self.summary = summary
        self.firstKeptEntryId = firstKeptEntryId
        self.tokensBefore = tokensBefore
        self.details = details
    }
}

public struct CompactionSettings: Sendable {
    public var enabled: Bool
    public var reserveTokens: Int
    public var keepRecentTokens: Int

    public init(enabled: Bool, reserveTokens: Int, keepRecentTokens: Int) {
        self.enabled = enabled
        self.reserveTokens = reserveTokens
        self.keepRecentTokens = keepRecentTokens
    }
}

public let DEFAULT_COMPACTION_SETTINGS = CompactionSettings(enabled: true, reserveTokens: 16384, keepRecentTokens: 20000)

public struct CutPointResult: Sendable {
    public var firstKeptEntryIndex: Int
    public var turnStartIndex: Int
    public var isSplitTurn: Bool
}

public struct CompactionPreparation: Sendable {
    public var firstKeptEntryId: String
    public var messagesToSummarize: [AgentMessage]
    public var turnPrefixMessages: [AgentMessage]
    public var isSplitTurn: Bool
    public var tokensBefore: Int
    public var previousSummary: String?
    public var fileOps: FileOperations
    public var settings: CompactionSettings

    public init(
        firstKeptEntryId: String,
        messagesToSummarize: [AgentMessage],
        turnPrefixMessages: [AgentMessage],
        isSplitTurn: Bool,
        tokensBefore: Int,
        previousSummary: String? = nil,
        fileOps: FileOperations,
        settings: CompactionSettings
    ) {
        self.firstKeptEntryId = firstKeptEntryId
        self.messagesToSummarize = messagesToSummarize
        self.turnPrefixMessages = turnPrefixMessages
        self.isSplitTurn = isSplitTurn
        self.tokensBefore = tokensBefore
        self.previousSummary = previousSummary
        self.fileOps = fileOps
        self.settings = settings
    }
}

public func calculateContextTokens(_ usage: Usage) -> Int {
    usage.totalTokens == 0 ? usage.input + usage.output + usage.cacheRead + usage.cacheWrite : usage.totalTokens
}

public func getLastAssistantUsage(_ entries: [SessionEntry]) -> Usage? {
    for entry in entries.reversed() {
        if case .message(let msgEntry) = entry, case .assistant(let assistant) = msgEntry.message {
            switch assistant.stopReason {
            case .stop, .length, .toolUse:
                return assistant.usage
            case .pending, .error, .aborted, .deferred:
                break
            }
        }
    }
    return nil
}

public func shouldCompact(_ contextTokens: Int, _ contextWindow: Int, _ settings: CompactionSettings) -> Bool {
    guard settings.enabled else { return false }
    return contextTokens > contextWindow - settings.reserveTokens
}

public func estimateTokens(_ message: AgentMessage) -> Int {
    var chars = 0
    switch message {
    case .user(let user):
        switch user.content {
        case .text(let text):
            chars += text.count
        case .blocks(let blocks):
            for block in blocks {
                if case .text(let text) = block {
                    chars += text.text.count
                }
            }
        }
    case .assistant(let assistant):
        for block in assistant.content {
            switch block {
            case .text(let text):
                chars += text.text.count
            case .thinking(let thinking):
                chars += thinking.thinking.count
            case .toolCall(let call):
                let argsText = call.arguments.map { "\($0.key)=\($0.value.value)" }.joined(separator: ",")
                chars += call.name.count + argsText.count
            case .image:
                chars += 4800
            }
        }
    case .toolResult(let result):
        for block in result.content {
            if case .text(let text) = block {
                chars += text.text.count
            }
            if case .image = block {
                chars += 4800
            }
        }
    case .custom(let custom):
        switch custom.role {
        case "hookMessage":
            if let payload = custom.payload?.value as? [String: Any],
               let content = payload["content"] as? String {
                chars += content.count
            }
        case "bashExecution":
            if let payload = custom.payload?.value as? [String: Any] {
                chars += (payload["command"] as? String)?.count ?? 0
                chars += (payload["output"] as? String)?.count ?? 0
            }
        case "branchSummary", "compactionSummary":
            if let payload = custom.payload?.value as? [String: Any] {
                chars += (payload["summary"] as? String)?.count ?? 0
            }
        default:
            break
        }
    }
    return Int(ceil(Double(chars) / 4.0))
}

public func findTurnStartIndex(_ entries: [SessionEntry], _ entryIndex: Int, _ startIndex: Int) -> Int {
    guard entryIndex >= 0 else { return -1 }
    for i in stride(from: entryIndex, through: startIndex, by: -1) {
        let entry = entries[i]
        if entry.type == "branch_summary" || entry.type == "custom_message" {
            return i
        }
        if case .message(let msg) = entry {
            switch msg.message {
            case .user:
                return i
            case .custom(let custom) where custom.role == "bashExecution":
                return i
            default:
                break
            }
        }
    }
    return -1
}

private func isTurnStartEntry(_ entry: SessionEntry) -> Bool {
    switch entry {
    case .branchSummary, .customMessage:
        return true
    case .message(let messageEntry):
        switch messageEntry.message {
        case .user:
            return true
        case .custom(let custom):
            return custom.role == "bashExecution"
        default:
            return false
        }
    default:
        return false
    }
}

public func findCutPoint(_ entries: [SessionEntry], _ startIndex: Int, _ endIndex: Int, _ keepRecentTokens: Int) -> CutPointResult {
    let cutPoints = findValidCutPoints(entries, startIndex, endIndex)
    if cutPoints.isEmpty {
        return CutPointResult(firstKeptEntryIndex: startIndex, turnStartIndex: -1, isSplitTurn: false)
    }

    var accumulatedTokens = 0
    var cutIndex = cutPoints.first ?? startIndex

    for i in stride(from: endIndex - 1, through: startIndex, by: -1) {
        let entry = entries[i]
        guard let message = messageFromEntry(entry) else { continue }
        accumulatedTokens += estimateTokens(message)
        if accumulatedTokens >= keepRecentTokens {
            if let nextCut = cutPoints.first(where: { $0 >= i }) {
                cutIndex = nextCut
            }
            break
        }
    }

    while cutIndex > startIndex {
        let prev = entries[cutIndex - 1]
        if prev.type == "compaction" { break }
        if messageFromEntry(prev) != nil { break }
        cutIndex -= 1
    }

    let cutEntry = entries[cutIndex]
    let startsTurn = isTurnStartEntry(cutEntry)
    let turnStartIndex = startsTurn ? -1 : findTurnStartIndex(entries, cutIndex, startIndex)
    return CutPointResult(firstKeptEntryIndex: cutIndex, turnStartIndex: turnStartIndex, isSplitTurn: !startsTurn && turnStartIndex != -1)
}

public func prepareCompaction(_ pathEntries: [SessionEntry], _ settings: CompactionSettings) -> CompactionPreparation? {
    if let last = pathEntries.last, last.type == "compaction" {
        return nil
    }

    var prevCompactionIndex = -1
    for i in stride(from: pathEntries.count - 1, through: 0, by: -1) {
        if pathEntries[i].type == "compaction" {
            prevCompactionIndex = i
            break
        }
    }
    let boundaryStart = prevCompactionIndex + 1
    let boundaryEnd = pathEntries.count

    let lastUsage = getLastAssistantUsage(pathEntries)
    let tokensBefore = lastUsage.map { calculateContextTokens($0) } ?? 0

    let cutPoint = findCutPoint(pathEntries, boundaryStart, boundaryEnd, settings.keepRecentTokens)
    let firstKeptEntry = pathEntries[cutPoint.firstKeptEntryIndex]
    let firstKeptEntryId = firstKeptEntry.id

    let historyEnd = cutPoint.isSplitTurn ? cutPoint.turnStartIndex : cutPoint.firstKeptEntryIndex

    var messagesToSummarize: [AgentMessage] = []
    if historyEnd >= boundaryStart {
        for i in boundaryStart..<historyEnd {
            if let msg = messageFromEntry(pathEntries[i]) {
                messagesToSummarize.append(msg)
            }
        }
    }

    var turnPrefixMessages: [AgentMessage] = []
    if cutPoint.isSplitTurn {
        for i in cutPoint.turnStartIndex..<cutPoint.firstKeptEntryIndex {
            if let msg = messageFromEntry(pathEntries[i]) {
                turnPrefixMessages.append(msg)
            }
        }
    }

    var previousSummary: String?
    if prevCompactionIndex >= 0, case .compaction(let compaction) = pathEntries[prevCompactionIndex] {
        previousSummary = compaction.summary
    }

    var fileOps = extractFileOperations(messagesToSummarize, pathEntries, prevCompactionIndex)
    if cutPoint.isSplitTurn {
        for msg in turnPrefixMessages {
            extractFileOpsFromMessage(msg, &fileOps)
        }
    }

    return CompactionPreparation(
        firstKeptEntryId: firstKeptEntryId,
        messagesToSummarize: messagesToSummarize,
        turnPrefixMessages: turnPrefixMessages,
        isSplitTurn: cutPoint.isSplitTurn,
        tokensBefore: tokensBefore,
        previousSummary: previousSummary,
        fileOps: fileOps,
        settings: settings
    )
}

public func compact(
    _ preparation: CompactionPreparation,
    _ model: Model,
    _ apiKey: String,
    headers: ProviderHeaders? = nil,
    customInstructions: String? = nil,
    signal: CancellationToken? = nil
) async throws -> CompactionResult {
    let messagesToSummarize = preparation.messagesToSummarize
    let turnPrefixMessages = preparation.turnPrefixMessages

    let summary: String
    if preparation.isSplitTurn && !turnPrefixMessages.isEmpty {
        summary = try await serializeSplitTurnSummaries(
            history: {
                if messagesToSummarize.isEmpty {
                    return "No prior history."
                }
                return try await generateSummary(
                    currentMessages: messagesToSummarize,
                    model: model,
                    reserveTokens: preparation.settings.reserveTokens,
                    apiKey: apiKey,
                    headers: headers,
                    signal: signal,
                    customInstructions: customInstructions,
                    previousSummary: preparation.previousSummary
                )
            },
            turnPrefix: {
                try await generateTurnPrefixSummary(
                    messages: turnPrefixMessages,
                    model: model,
                    reserveTokens: preparation.settings.reserveTokens,
                    apiKey: apiKey,
                    headers: headers,
                    signal: signal
                )
            }
        )
    } else {
        summary = try await generateSummary(
            currentMessages: messagesToSummarize,
            model: model,
            reserveTokens: preparation.settings.reserveTokens,
            apiKey: apiKey,
            headers: headers,
            signal: signal,
            customInstructions: customInstructions,
            previousSummary: preparation.previousSummary
        )
    }

    let lists = computeFileLists(preparation.fileOps)
    let combinedSummary = summary + formatFileOperations(readFiles: lists.readFiles, modifiedFiles: lists.modifiedFiles)
    let details = AnyCodable([
        "readFiles": lists.readFiles,
        "modifiedFiles": lists.modifiedFiles,
    ])

    return CompactionResult(summary: combinedSummary, firstKeptEntryId: preparation.firstKeptEntryId, tokensBefore: preparation.tokensBefore, details: details)
}

/// Runs split-turn summarization requests in provider-safe sequence.
func serializeSplitTurnSummaries(
    history: () async throws -> String,
    turnPrefix: () async throws -> String
) async rethrows -> String {
    let historyResult = try await history()
    let turnPrefixResult = try await turnPrefix()
    return "\(historyResult)\n\n---\n\n**Turn Context (split turn):**\n\n\(turnPrefixResult)"
}

private let SUMMARIZATION_PROMPT = """
The messages above are a conversation to summarize. Create a structured context checkpoint summary that another LLM will use to continue the work.

Use this EXACT format:

## Goal
[What is the user trying to accomplish? Can be multiple items if the session covers different tasks.]

## Constraints & Preferences
- [Any constraints, preferences, or requirements mentioned by user]
- [Or "(none)" if none were mentioned]

## Progress
### Done
- [x] [Completed tasks/changes]

### In Progress
- [ ] [Current work]

### Blocked
- [Issues preventing progress, if any]

## Key Decisions
- **[Decision]**: [Brief rationale]

## Next Steps
1. [Ordered list of what should happen next]

## Critical Context
- [Any data, examples, or references needed to continue]
- [Or "(none)" if not applicable]

Keep each section concise. Preserve exact file paths, function names, and error messages.
"""

private let UPDATE_SUMMARIZATION_PROMPT = """
The messages above are NEW conversation messages to incorporate into the existing summary provided in <previous-summary> tags.

Update the existing structured summary with new information. RULES:
- PRESERVE all existing information from the previous summary
- ADD new progress, decisions, and context from the new messages
- UPDATE the Progress section: move items from "In Progress" to "Done" when completed
- UPDATE "Next Steps" based on what was accomplished
- PRESERVE exact file paths, function names, and error messages
- If something is no longer relevant, you may remove it

Use this EXACT format:

## Goal
[Preserve existing goals, add new ones if the task expanded]

## Constraints & Preferences
- [Preserve existing, add new ones discovered]

## Progress
### Done
- [x] [Include previously done items AND newly completed items]

### In Progress
- [ ] [Current work - update based on progress]

### Blocked
- [Current blockers - remove if resolved]

## Key Decisions
- **[Decision]**: [Brief rationale] (preserve all previous, add new)

## Next Steps
1. [Update based on current state]

## Critical Context
- [Preserve important context, add new if needed]

Keep each section concise. Preserve exact file paths, function names, and error messages.
"""

private func generateSummary(
    currentMessages: [AgentMessage],
    model: Model,
    reserveTokens: Int,
    apiKey: String,
    headers: ProviderHeaders?,
    signal: CancellationToken?,
    customInstructions: String?,
    previousSummary: String?
) async throws -> String {
    let maxTokens = Int(Double(reserveTokens) * 0.8)
    var basePrompt = previousSummary == nil ? SUMMARIZATION_PROMPT : UPDATE_SUMMARIZATION_PROMPT
    if let customInstructions, !customInstructions.isEmpty {
        basePrompt += "\n\nAdditional focus: \(customInstructions)"
    }

    let llmMessages = convertToLlm(currentMessages)
    let conversationText = serializeConversation(llmMessages)

    var promptText = "<conversation>\n\(conversationText)\n</conversation>\n\n"
    if let previousSummary {
        promptText += "<previous-summary>\n\(previousSummary)\n</previous-summary>\n\n"
    }
    promptText += basePrompt

    let summarizationMessages: [Message] = [
        .user(UserMessage(content: .blocks([.text(TextContent(text: promptText))])))
    ]

    // Only use reasoning for models that support it; non-reasoning models skip the parameter
    let reasoning: PiSwiftAI.ThinkingLevel? = model.reasoning ? .high : nil
    let response = try await completeSimple(
        model: model,
        context: Context(systemPrompt: SUMMARIZATION_SYSTEM_PROMPT, messages: summarizationMessages),
        options: SimpleStreamOptions(maxTokens: maxTokens, signal: signal, apiKey: apiKey, reasoning: reasoning, headers: headers)
    )

    switch response.stopReason {
    case .stop, .length, .toolUse:
        break
    case .pending, .error, .aborted, .deferred:
        throw CompactionError.summarizationFailed(response.errorMessage ?? "Unknown error")
    }

    let text = response.content.compactMap { block -> String? in
        if case .text(let text) = block { return text.text }
        return nil
    }.joined(separator: "\n")

    return text
}

private let TURN_PREFIX_SUMMARIZATION_PROMPT = """
This is the PREFIX of a turn that was too large to keep. The SUFFIX (recent work) is retained.

Summarize the prefix to provide context for the retained suffix:

## Original Request
[What did the user ask for in this turn?]

## Early Progress
- [Key decisions and work done in the prefix]

## Context for Suffix
- [Information needed to understand the retained recent work]

Be concise. Focus on what's needed to understand the kept suffix.
"""

private func generateTurnPrefixSummary(
    messages: [AgentMessage],
    model: Model,
    reserveTokens: Int,
    apiKey: String,
    headers: ProviderHeaders?,
    signal: CancellationToken?
) async throws -> String {
    let maxTokens = Int(Double(reserveTokens) * 0.5)
    let llmMessages = convertToLlm(messages)
    let conversationText = serializeConversation(llmMessages)
    let promptText = "<conversation>\n\(conversationText)\n</conversation>\n\n\(TURN_PREFIX_SUMMARIZATION_PROMPT)"

    let summarizationMessages: [Message] = [
        .user(UserMessage(content: .blocks([.text(TextContent(text: promptText))])))
    ]

    let response = try await completeSimple(
        model: model,
        context: Context(systemPrompt: SUMMARIZATION_SYSTEM_PROMPT, messages: summarizationMessages),
        options: SimpleStreamOptions(maxTokens: maxTokens, signal: signal, apiKey: apiKey, headers: headers)
    )

    switch response.stopReason {
    case .stop, .length, .toolUse:
        break
    case .pending, .error, .aborted, .deferred:
        throw CompactionError.summarizationFailed(response.errorMessage ?? "Unknown error")
    }

    return response.content.compactMap { block -> String? in
        if case .text(let text) = block { return text.text }
        return nil
    }.joined(separator: "\n")
}

private func messageFromEntry(_ entry: SessionEntry) -> AgentMessage? {
    switch entry {
    case .message(let msg):
        return msg.message
    case .customMessage(let custom):
        let hook = HookMessage(customType: custom.customType, content: custom.content, display: custom.display, details: custom.details, timestamp: parseTimestamp(custom.timestamp))
        return makeHookAgentMessage(hook)
    case .branchSummary(let summary):
        let msg = BranchSummaryMessage(summary: summary.summary, fromId: summary.fromId, timestamp: parseTimestamp(summary.timestamp))
        return makeBranchSummaryAgentMessage(msg)
    default:
        return nil
    }
}

private func extractFileOperations(_ messages: [AgentMessage], _ entries: [SessionEntry], _ prevCompactionIndex: Int) -> FileOperations {
    var fileOps = createFileOps()
    if prevCompactionIndex >= 0, case .compaction(let compaction) = entries[prevCompactionIndex], compaction.fromHook != true, let details = compaction.details?.value as? [String: Any] {
        if let readFiles = details["readFiles"] as? [String] {
            for file in readFiles { fileOps.read.insert(file) }
        }
        if let modifiedFiles = details["modifiedFiles"] as? [String] {
            for file in modifiedFiles { fileOps.edited.insert(file) }
        }
    }

    for message in messages {
        extractFileOpsFromMessage(message, &fileOps)
    }

    return fileOps
}

private func findValidCutPoints(_ entries: [SessionEntry], _ startIndex: Int, _ endIndex: Int) -> [Int] {
    var cutPoints: [Int] = []
    for i in startIndex..<endIndex {
        let entry = entries[i]
        switch entry {
        case .message(let msg):
            switch msg.message {
            case .toolResult:
                break
            default:
                cutPoints.append(i)
            }
        case .branchSummary, .customMessage:
            cutPoints.append(i)
        case .sessionInfo:
            break
        default:
            break
        }
    }
    return cutPoints
}

private func parseTimestamp(_ value: String) -> Int64 {
    let ts = ISO8601DateFormatter().date(from: value)?.timeIntervalSince1970 ?? Date().timeIntervalSince1970
    return Int64(ts * 1000)
}
