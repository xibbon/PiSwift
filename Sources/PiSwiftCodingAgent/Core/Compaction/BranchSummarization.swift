import Foundation
import PiSwiftAI
import PiSwiftAgent

public struct BranchSummaryResult: Sendable {
    public var summary: String?
    public var readFiles: [String]?
    public var modifiedFiles: [String]?
    public var aborted: Bool?
    public var error: String?

    public init(summary: String? = nil, readFiles: [String]? = nil, modifiedFiles: [String]? = nil, aborted: Bool? = nil, error: String? = nil) {
        self.summary = summary
        self.readFiles = readFiles
        self.modifiedFiles = modifiedFiles
        self.aborted = aborted
        self.error = error
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
    public var headers: [String: String]?
    public var signal: CancellationToken?
    public var customInstructions: String?
    /// If true, `customInstructions` replaces the default prompt instead of being appended.
    public var replaceInstructions: Bool?
    public var reserveTokens: Int?

    public init(model: Model, apiKey: String, headers: [String: String]? = nil, signal: CancellationToken?, customInstructions: String?, replaceInstructions: Bool? = nil, reserveTokens: Int?) {
        self.model = model
        self.apiKey = apiKey
        self.headers = headers
        self.signal = signal
        self.customInstructions = customInstructions
        self.replaceInstructions = replaceInstructions
        self.reserveTokens = reserveTokens
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
    let preparation = prepareBranchEntries(entries, reserve)
    if preparation.messages.isEmpty {
        return BranchSummaryResult(summary: "No conversation to summarize.", readFiles: [], modifiedFiles: [])
    }

    let summaryPrompt = """
Summarize the abandoned branch for future context. Keep it short and focused.

Include:
- Key decisions
- Important constraints
- File changes or reads
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
        let response = try await completeSimple(
            model: options.model,
            context: Context(systemPrompt: SUMMARIZATION_SYSTEM_PROMPT, messages: [message]),
            options: SimpleStreamOptions(maxTokens: Int(Double(reserve) * 0.6), signal: options.signal, apiKey: options.apiKey, headers: options.headers)
        )
        switch response.stopReason {
        case .stop, .length, .toolUse:
            break
        case .pending, .error, .aborted, .deferred:
            return BranchSummaryResult(error: response.errorMessage ?? "Summarization failed")
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
            aborted: options.signal?.isCancelled == true ? true : nil
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
