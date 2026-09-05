import Foundation
import PiSwiftAI
import PiSwiftAgent

public struct BranchSummaryResult: Sendable {
    public var summary: String?
    public var readFiles: [String]?
    public var modifiedFiles: [String]?
    public var aborted: Bool?
    public var error: String?
    public var usage: Usage?

    public init(summary: String? = nil, readFiles: [String]? = nil, modifiedFiles: [String]? = nil, aborted: Bool? = nil, error: String? = nil, usage: Usage? = nil) {
        self.summary = summary
        self.readFiles = readFiles
        self.modifiedFiles = modifiedFiles
        self.aborted = aborted
        self.error = error
        self.usage = usage
    }
}

public struct BranchSummaryDetails: Sendable {
    public var readFiles: [String]
    public var modifiedFiles: [String]

    public init(readFiles: [String], modifiedFiles: [String]) {
        self.readFiles = readFiles
        self.modifiedFiles = modifiedFiles
    }
}

public struct BranchPreparation: Sendable {
    public var messages: [AgentMessage]
    public var fileOps: FileOperations
    public var totalTokens: Int

    public init(messages: [AgentMessage], fileOps: FileOperations, totalTokens: Int) {
        self.messages = messages
        self.fileOps = fileOps
        self.totalTokens = totalTokens
    }
}

public struct CollectEntriesResult: Sendable {
    public var entries: [SessionEntry]
    public var commonAncestorId: String?

    public init(entries: [SessionEntry], commonAncestorId: String?) {
        self.entries = entries
        self.commonAncestorId = commonAncestorId
    }
}

public struct GenerateBranchSummaryOptions: Sendable {
    public var model: Model
    public var apiKey: String
    public var headers: ProviderHeaders?
    public var signal: CancellationToken?
    public var customInstructions: String?
    /// If true, `customInstructions` replaces the default prompt instead of being appended.
    public var replaceInstructions: Bool?
    /// Tokens reserved when selecting branch history (default 16384).
    public var reserveTokens: Int?
    public var streamFn: StreamFn?
    public var retry: RetryPolicy?
    public var callbacks: RetryCallbacks?

    public init(model: Model, apiKey: String, headers: ProviderHeaders? = nil, signal: CancellationToken?, customInstructions: String?, replaceInstructions: Bool? = nil, reserveTokens: Int?, streamFn: StreamFn? = nil, retry: RetryPolicy? = nil, callbacks: RetryCallbacks? = nil) {
        self.model = model
        self.apiKey = apiKey
        self.headers = headers
        self.signal = signal
        self.customInstructions = customInstructions
        self.replaceInstructions = replaceInstructions
        self.reserveTokens = reserveTokens
        self.streamFn = streamFn
        self.retry = retry
        self.callbacks = callbacks
    }
}

public func collectEntriesForBranchSummary(
    _ session: SessionManager,
    _ oldLeafId: String?,
    _ targetId: String
) -> CollectEntriesResult {
    guard let oldLeafId else {
        return CollectEntriesResult(entries: [], commonAncestorId: nil)
    }

    let oldPathIds = Set(session.getBranch(oldLeafId).map { $0.id })
    let targetPath = session.getBranch(targetId)
    var commonAncestorId: String? = nil

    for entry in targetPath.reversed() {
        if oldPathIds.contains(entry.id) {
            commonAncestorId = entry.id
            break
        }
    }

    var entries: [SessionEntry] = []
    var current: String? = oldLeafId
    while let currentId = current, currentId != commonAncestorId {
        guard let entry = session.getEntry(currentId) else { break }
        entries.append(entry)
        current = entry.parentId
    }

    return CollectEntriesResult(entries: entries.reversed(), commonAncestorId: commonAncestorId)
}

public func prepareBranchEntries(_ entries: [SessionEntry], _ tokenBudget: Int = 0) -> BranchPreparation {
    var messages: [AgentMessage] = []
    var fileOps = createFileOps()
    var totalTokens = 0

    for entry in entries {
        if case .branchSummary(let summary) = entry, summary.fromHook != true, let details = summary.details?.value as? [String: Any] {
            if let readFiles = details["readFiles"] as? [String] {
                for file in readFiles { fileOps.read.insert(file) }
            }
            if let modified = details["modifiedFiles"] as? [String] {
                for file in modified { fileOps.edited.insert(file) }
            }
        }
    }

    for entry in entries.reversed() {
        guard let message = messageFromEntryForBranch(entry) else { continue }
        extractFileOpsFromMessage(message, &fileOps)
        let tokens = estimateTokens(message)
        if tokenBudget > 0 && totalTokens + tokens > tokenBudget {
            continue
        }
        messages.insert(message, at: 0)
        totalTokens += tokens
    }

    return BranchPreparation(messages: messages, fileOps: fileOps, totalTokens: totalTokens)
}

public func generateBranchSummary(_ entries: [SessionEntry], _ options: GenerateBranchSummaryOptions) async -> BranchSummaryResult {
    let reserve = options.reserveTokens ?? 16384
    let contextWindow = options.model.contextWindow > 0 ? options.model.contextWindow : 128000
    let preparation = prepareBranchEntries(entries, contextWindow - reserve)
    if preparation.messages.isEmpty {
        return BranchSummaryResult(summary: "No content to summarize", readFiles: [], modifiedFiles: [])
    }

    let summaryPrompt = """
Create a structured summary of this conversation branch for context when returning later.

Use this EXACT format:

## Goal
[What was the user trying to accomplish in this branch?]

## Constraints & Preferences
- [Any constraints, preferences, or requirements mentioned]
- [Or "(none)" if none were mentioned]

## Progress
### Done
- [x] [Completed tasks/changes]

### In Progress
- [ ] [Work that was started but not finished]

### Blocked
- [Issues preventing progress, if any]

## Key Decisions
- **[Decision]**: [Brief rationale]

## Next Steps
1. [What should happen next to continue this work]

Keep each section concise. Preserve exact file paths, function names, and error messages.
"""

    let llmMessages = convertToLlm(preparation.messages)
    let conversationText = serializeConversation(llmMessages)
    let instructions: String
    if let custom = options.customInstructions, !custom.isEmpty {
        if options.replaceInstructions == true {
            instructions = custom
        } else {
            instructions = "\(summaryPrompt)\n\nAdditional focus: \(custom)"
        }
    } else {
        instructions = summaryPrompt
    }
    let prompt = "<conversation>\n\(conversationText)\n</conversation>\n\n\(instructions)"

    let message = Message.user(UserMessage(content: .blocks([.text(TextContent(text: prompt))])))
    do {
        let response = try await completeSummarization(
            model: options.model,
            context: Context(systemPrompt: SUMMARIZATION_SYSTEM_PROMPT, messages: [message]),
            options: SimpleStreamOptions(maxTokens: min(4096, options.model.maxTokens > 0 ? options.model.maxTokens : Int.max), signal: options.signal, apiKey: options.apiKey, headers: options.headers),
            streamFn: options.streamFn, retry: options.retry, callbacks: options.callbacks
        )
        if response.stopReason == .aborted { return BranchSummaryResult(aborted: true) }
        if let failure = getSummarizationFailure(response, label: "Branch summarization") {
            return BranchSummaryResult(error: failure)
        }
        if response.content.contains(where: { if case .toolCall = $0 { return true }; return false }) {
            return BranchSummaryResult(error: "Branch summarization attempted to call a tool")
        }

        let text = response.content.compactMap { block -> String? in
            if case .text(let text) = block { return text.text }
            return nil
        }.joined(separator: "\n")

        let lists = computeFileLists(preparation.fileOps)
        return BranchSummaryResult(
            summary: text,
            readFiles: lists.readFiles,
            modifiedFiles: lists.modifiedFiles,
            aborted: options.signal?.isCancelled == true ? true : nil,
            usage: response.usage
        )
    } catch {
        if options.signal?.isCancelled == true {
            return BranchSummaryResult(aborted: true)
        }
        return BranchSummaryResult(error: error.localizedDescription)
    }
}

private func messageFromEntryForBranch(_ entry: SessionEntry) -> AgentMessage? {
    switch entry {
    case .message(let msg):
        if case .toolResult = msg.message { return nil }
        return msg.message
    case .customMessage(let custom):
        let hook = HookMessage(customType: custom.customType, content: custom.content, display: custom.display, details: custom.details, timestamp: parseTimestamp(custom.timestamp))
        return makeHookAgentMessage(hook)
    case .branchSummary(let summary):
        let msg = BranchSummaryMessage(summary: summary.summary, fromId: summary.fromId, timestamp: parseTimestamp(summary.timestamp))
        return makeBranchSummaryAgentMessage(msg)
    case .compaction(let compaction):
        let msg = CompactionSummaryMessage(summary: compaction.summary, tokensBefore: compaction.tokensBefore, timestamp: parseTimestamp(compaction.timestamp))
        return makeCompactionSummaryAgentMessage(msg)
    default:
        return nil
    }
}

private func parseTimestamp(_ value: String) -> Int64 {
    let ts = ISO8601DateFormatter().date(from: value)?.timeIntervalSince1970 ?? Date().timeIntervalSince1970
    return Int64(ts * 1000)
}
