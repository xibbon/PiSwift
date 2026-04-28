import Foundation
import PiSwiftAI
import PiSwiftAgent

/// Strip all control characters (C0/C1) from text for safe display.
private func stripControlCharacters(_ text: String) -> String {
    text.unicodeScalars.filter { scalar in
        // Keep printable characters, spaces, and common whitespace (tab, newline)
        scalar.value >= 0x20 || scalar.value == 0x09 || scalar.value == 0x0A || scalar.value == 0x0D
    }.map { String($0) }.joined()
}

enum SessionManagerError: LocalizedError, Sendable {
    case entryNotFound(String)

    var errorDescription: String? {
        switch self {
        case .entryNotFound(let id):
            return "Entry \(id) not found"
        }
    }
}

public let CURRENT_SESSION_VERSION = 3

public struct SessionHeader: Sendable {
    public var type: String = "session"
    public var version: Int?
    public var id: String
    public var timestamp: String
    public var cwd: String
    public var parentSession: String?

    public init(type: String = "session", version: Int? = nil, id: String, timestamp: String, cwd: String, parentSession: String? = nil) {
        self.type = type
        self.version = version
        self.id = id
        self.timestamp = timestamp
        self.cwd = cwd
        self.parentSession = parentSession
    }
}

public struct NewSessionOptions: Sendable {
    public var parentSession: String?
    public var id: String?

    public init(parentSession: String? = nil, id: String? = nil) {
        self.parentSession = parentSession
        self.id = id
    }
}

public protocol SessionEntryBase: Sendable {
    var id: String { get set }
    var parentId: String? { get set }
    var timestamp: String { get set }
}

public struct SessionMessageEntry: SessionEntryBase, Sendable {
    public var type: String = "message"
    public var id: String
    public var parentId: String?
    public var timestamp: String
    public var message: AgentMessage

    public init(type: String = "message", id: String, parentId: String? = nil, timestamp: String, message: AgentMessage) {
        self.type = type
        self.id = id
        self.parentId = parentId
        self.timestamp = timestamp
        self.message = message
    }
}

public struct ThinkingLevelChangeEntry: SessionEntryBase, Sendable {
    public var type: String = "thinking_level_change"
    public var id: String
    public var parentId: String?
    public var timestamp: String
    public var thinkingLevel: String

    public init(type: String = "thinking_level_change", id: String, parentId: String? = nil, timestamp: String, thinkingLevel: String) {
        self.type = type
        self.id = id
        self.parentId = parentId
        self.timestamp = timestamp
        self.thinkingLevel = thinkingLevel
    }
}

public struct ModelChangeEntry: SessionEntryBase, Sendable {
    public var type: String = "model_change"
    public var id: String
    public var parentId: String?
    public var timestamp: String
    public var provider: String
    public var modelId: String

    public init(type: String = "model_change", id: String, parentId: String? = nil, timestamp: String, provider: String, modelId: String) {
        self.type = type
        self.id = id
        self.parentId = parentId
        self.timestamp = timestamp
        self.provider = provider
        self.modelId = modelId
    }
}

public struct CompactionEntry: SessionEntryBase, Sendable {
    public var type: String = "compaction"
    public var id: String
    public var parentId: String?
    public var timestamp: String
    public var summary: String
    public var firstKeptEntryId: String
    public var tokensBefore: Int
    public var details: AnyCodable?
    public var fromHook: Bool?

    public init(
        type: String = "compaction",
        id: String,
        parentId: String? = nil,
        timestamp: String,
        summary: String,
        firstKeptEntryId: String,
        tokensBefore: Int,
        details: AnyCodable? = nil,
        fromHook: Bool? = nil
    ) {
        self.type = type
        self.id = id
        self.parentId = parentId
        self.timestamp = timestamp
        self.summary = summary
        self.firstKeptEntryId = firstKeptEntryId
        self.tokensBefore = tokensBefore
        self.details = details
        self.fromHook = fromHook
    }
}

public struct BranchSummaryEntry: SessionEntryBase, Sendable {
    public var type: String = "branch_summary"
    public var id: String
    public var parentId: String?
    public var timestamp: String
    public var fromId: String
    public var summary: String
    public var details: AnyCodable?
    public var fromHook: Bool?

    public init(
        type: String = "branch_summary",
        id: String,
        parentId: String? = nil,
        timestamp: String,
        fromId: String,
        summary: String,
        details: AnyCodable? = nil,
        fromHook: Bool? = nil
    ) {
        self.type = type
        self.id = id
        self.parentId = parentId
        self.timestamp = timestamp
        self.fromId = fromId
        self.summary = summary
        self.details = details
        self.fromHook = fromHook
    }
}

public struct CustomEntry: SessionEntryBase, Sendable {
    public var type: String = "custom"
    public var id: String
    public var parentId: String?
    public var timestamp: String
    public var customType: String
    public var data: AnyCodable?
}

public struct CustomMessageEntry: SessionEntryBase, Sendable {
    public var type: String = "custom_message"
    public var id: String
    public var parentId: String?
    public var timestamp: String
    public var customType: String
    public var content: HookMessageContent
    public var details: AnyCodable?
    public var display: Bool
}

public struct LabelEntry: SessionEntryBase, Sendable {
    public var type: String = "label"
    public var id: String
    public var parentId: String?
    public var timestamp: String
    public var targetId: String
    public var label: String?
}

public struct SessionInfoEntry: SessionEntryBase, Sendable {
    public var type: String = "session_info"
    public var id: String
    public var parentId: String?
    public var timestamp: String
    public var name: String?
}

public enum SessionEntry: Sendable {
    case message(SessionMessageEntry)
    case thinkingLevel(ThinkingLevelChangeEntry)
    case modelChange(ModelChangeEntry)
    case compaction(CompactionEntry)
    case branchSummary(BranchSummaryEntry)
    case custom(CustomEntry)
    case customMessage(CustomMessageEntry)
    case label(LabelEntry)
    case sessionInfo(SessionInfoEntry)

    public var type: String {
        switch self {
        case .message: return "message"
        case .thinkingLevel: return "thinking_level_change"
        case .modelChange: return "model_change"
        case .compaction: return "compaction"
        case .branchSummary: return "branch_summary"
        case .custom: return "custom"
        case .customMessage: return "custom_message"
        case .label: return "label"
        case .sessionInfo: return "session_info"
        }
    }

    public var id: String {
        get {
            switch self {
            case .message(let entry): return entry.id
            case .thinkingLevel(let entry): return entry.id
            case .modelChange(let entry): return entry.id
            case .compaction(let entry): return entry.id
            case .branchSummary(let entry): return entry.id
            case .custom(let entry): return entry.id
            case .customMessage(let entry): return entry.id
            case .label(let entry): return entry.id
            case .sessionInfo(let entry): return entry.id
            }
        }
        set {
            switch self {
            case .message(var entry):
                entry.id = newValue
                self = .message(entry)
            case .thinkingLevel(var entry):
                entry.id = newValue
                self = .thinkingLevel(entry)
            case .modelChange(var entry):
                entry.id = newValue
                self = .modelChange(entry)
            case .compaction(var entry):
                entry.id = newValue
                self = .compaction(entry)
            case .branchSummary(var entry):
                entry.id = newValue
                self = .branchSummary(entry)
            case .custom(var entry):
                entry.id = newValue
                self = .custom(entry)
            case .customMessage(var entry):
                entry.id = newValue
                self = .customMessage(entry)
            case .label(var entry):
                entry.id = newValue
                self = .label(entry)
            case .sessionInfo(var entry):
                entry.id = newValue
                self = .sessionInfo(entry)
            }
        }
    }

    public var parentId: String? {
        get {
            switch self {
            case .message(let entry): return entry.parentId
            case .thinkingLevel(let entry): return entry.parentId
            case .modelChange(let entry): return entry.parentId
            case .compaction(let entry): return entry.parentId
            case .branchSummary(let entry): return entry.parentId
            case .custom(let entry): return entry.parentId
            case .customMessage(let entry): return entry.parentId
            case .label(let entry): return entry.parentId
            case .sessionInfo(let entry): return entry.parentId
            }
        }
        set {
            switch self {
            case .message(var entry):
                entry.parentId = newValue
                self = .message(entry)
            case .thinkingLevel(var entry):
                entry.parentId = newValue
                self = .thinkingLevel(entry)
            case .modelChange(var entry):
                entry.parentId = newValue
                self = .modelChange(entry)
            case .compaction(var entry):
                entry.parentId = newValue
                self = .compaction(entry)
            case .branchSummary(var entry):
                entry.parentId = newValue
                self = .branchSummary(entry)
            case .custom(var entry):
                entry.parentId = newValue
                self = .custom(entry)
            case .customMessage(var entry):
                entry.parentId = newValue
                self = .customMessage(entry)
            case .label(var entry):
                entry.parentId = newValue
                self = .label(entry)
            case .sessionInfo(var entry):
                entry.parentId = newValue
                self = .sessionInfo(entry)
            }
        }
    }

    public var timestamp: String {
        switch self {
        case .message(let entry): return entry.timestamp
        case .thinkingLevel(let entry): return entry.timestamp
        case .modelChange(let entry): return entry.timestamp
        case .compaction(let entry): return entry.timestamp
        case .branchSummary(let entry): return entry.timestamp
        case .custom(let entry): return entry.timestamp
        case .customMessage(let entry): return entry.timestamp
        case .label(let entry): return entry.timestamp
        case .sessionInfo(let entry): return entry.timestamp
        }
    }
}

public enum FileEntry: Sendable {
    case session(SessionHeader)
    case entry(SessionEntry)

    public var type: String {
        switch self {
        case .session: return "session"
        case .entry(let entry): return entry.type
        }
    }
}

public struct SessionTreeNode: Sendable {
    public var entry: SessionEntry
    public var children: [SessionTreeNode]
    public var label: String?
}

public struct SessionContext: Sendable {
    public var messages: [AgentMessage]
    public var thinkingLevel: String
    public var model: (provider: String, modelId: String)?
}

public struct SessionInfo: Sendable {
    public var path: String
    public var id: String
    public var cwd: String
    public var name: String?
    public var created: Date
    public var modified: Date
    public var messageCount: Int
    public var firstMessage: String
    public var allMessagesText: String
}

public func parseSessionEntries(_ content: String) -> [FileEntry] {
    let lines = content.split(separator: "\n", omittingEmptySubsequences: false)
    var entries: [FileEntry] = []

    for line in lines {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { continue }
        guard let data = trimmed.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else { continue }

        if type == "session" {
            if let header = decodeSessionHeader(json) {
                entries.append(.session(header))
            }
        } else if let entry = decodeSessionEntry(json) {
            entries.append(.entry(entry))
        }
    }

    if let first = entries.first {
        if case .session = first {
            return entries
        }
    }
    return []
}

@discardableResult
public func migrateSessionEntries(_ entries: inout [FileEntry]) -> Bool {
    guard let headerIndex = entries.firstIndex(where: { if case .session = $0 { return true } else { return false } }) else {
        return false
    }
    guard case .session(var header) = entries[headerIndex] else { return false }
    let version = header.version ?? 1
    if version >= CURRENT_SESSION_VERSION {
        return false
    }

    // v1 → v2: add id/parentId tree structure
    if version < 2 {
        var ids: Set<String> = Set()
        var prevId: String? = nil

        for i in 0..<entries.count {
            switch entries[i] {
            case .session:
                continue
            case .entry(var entry):
                if entry.id.isEmpty {
                    entry.id = generateId(existing: ids)
                }
                entry.parentId = prevId
                prevId = entry.id
                entries[i] = .entry(entry)
                ids.insert(entry.id)
            }
        }
    }

    // v2 → v3: rename hookMessage role to custom
    // Note: This is handled during decoding - hookMessage is decoded as custom role

    // Update header version
    header.version = CURRENT_SESSION_VERSION
    entries[headerIndex] = .session(header)
    return true
}

public func buildSessionContext(_ entries: [SessionEntry], _ leafId: String? = nil, _ byId: [String: SessionEntry]? = nil) -> SessionContext {
    let idMap = byId ?? Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })

    if leafId == nil && entries.isEmpty {
        return SessionContext(messages: [], thinkingLevel: "off", model: nil)
    }

    if leafId == nil, let last = entries.last {
        return buildSessionContext(entries, last.id, idMap)
    }

    guard let leafId else {
        return SessionContext(messages: [], thinkingLevel: "off", model: nil)
    }

    if leafId == "null" {
        return SessionContext(messages: [], thinkingLevel: "off", model: nil)
    }

    guard let leaf = idMap[leafId] else {
        return SessionContext(messages: [], thinkingLevel: "off", model: nil)
    }

    var path: [SessionEntry] = []
    var current: SessionEntry? = leaf
    while let entry = current {
        path.insert(entry, at: 0)
        if let parentId = entry.parentId {
            current = idMap[parentId]
        } else {
            current = nil
        }
    }

    var thinkingLevel = "off"
    var model: (provider: String, modelId: String)? = nil
    var compaction: CompactionEntry?

    for entry in path {
        switch entry {
        case .thinkingLevel(let change):
            thinkingLevel = change.thinkingLevel
        case .modelChange(let change):
            model = (provider: change.provider, modelId: change.modelId)
        case .message(let message):
            if case .assistant(let assistant) = message.message {
                model = (provider: assistant.provider, modelId: assistant.model)
            }
        case .compaction(let compactionEntry):
            compaction = compactionEntry
        default:
            break
        }
    }

    var messages: [AgentMessage] = []

    func appendMessage(from entry: SessionEntry) {
        switch entry {
        case .message(let message):
            messages.append(message.message)
        case .customMessage(let custom):
            let hookMessage = HookMessage(customType: custom.customType, content: custom.content, display: custom.display, details: custom.details, timestamp: parseTimestamp(custom.timestamp))
            messages.append(makeHookAgentMessage(hookMessage))
        case .branchSummary(let summary):
            let msg = BranchSummaryMessage(summary: summary.summary, fromId: summary.fromId, timestamp: parseTimestamp(summary.timestamp))
            messages.append(makeBranchSummaryAgentMessage(msg))
        default:
            break
        }
    }

    if let compaction {
        let compactionMsg = CompactionSummaryMessage(summary: compaction.summary, tokensBefore: compaction.tokensBefore, timestamp: parseTimestamp(compaction.timestamp))
        messages.append(makeCompactionSummaryAgentMessage(compactionMsg))

        let compactionIdx = path.firstIndex(where: { if case .compaction(let entry) = $0 { return entry.id == compaction.id } else { return false } }) ?? -1
        var foundFirstKept = false
        if compactionIdx >= 0 {
            for i in 0..<compactionIdx {
                let entry = path[i]
                if entry.id == compaction.firstKeptEntryId {
                    foundFirstKept = true
                }
                if foundFirstKept {
                    appendMessage(from: entry)
                }
            }
            for i in (compactionIdx + 1)..<path.count {
                appendMessage(from: path[i])
            }
        }
    } else {
        for entry in path {
            appendMessage(from: entry)
        }
    }

    return SessionContext(messages: messages, thinkingLevel: thinkingLevel, model: model)
}

public func loadEntriesFromFile(_ filePath: String) -> [FileEntry] {
    guard FileManager.default.fileExists(atPath: filePath),
          let content = try? String(contentsOfFile: filePath, encoding: .utf8) else {
        return []
    }
    let entries = parseSessionEntries(content)
    guard let first = entries.first, case .session = first else {
        return []
    }
    return entries
}

/// Efficiently checks if a file has a valid session header by reading only the first 512 bytes
public func isValidSessionFile(_ filePath: String) -> Bool {
    guard let handle = FileHandle(forReadingAtPath: filePath) else {
        return false
    }
    defer { try? handle.close() }

    guard let data = try? handle.read(upToCount: 512),
          let content = String(data: data, encoding: .utf8) else {
        return false
    }

    let firstLine = content.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
    guard !firstLine.isEmpty,
          let jsonData = firstLine.data(using: .utf8),
          let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
          let type = json["type"] as? String,
          type == "session",
          json["id"] is String else {
        return false
    }

    return true
}

public func findMostRecentSession(_ dir: String) -> String? {
    guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return nil }
    let jsonlFiles = files.filter { $0.hasSuffix(".jsonl") }
    var newest: (path: String, date: Date)? = nil

    for file in jsonlFiles {
        let path = URL(fileURLWithPath: dir).appendingPathComponent(file).path
        guard isValidSessionFile(path) else { continue }
        if let attrs = try? FileManager.default.attributesOfItem(atPath: path),
           let mtime = attrs[.modificationDate] as? Date {
            if newest == nil || mtime > newest!.date {
                newest = (path, mtime)
            }
        }
    }

    return newest?.path
}

private func isMessageWithContent(_ message: AgentMessage) -> Bool {
    switch message {
    case .user, .assistant:
        return true
    default:
        return false
    }
}

private func extractTextContent(_ message: AgentMessage) -> String {
    switch message {
    case .user(let user):
        return extractUserContentText(user.content)
    case .assistant(let assistant):
        return assistant.content.compactMap { block -> String? in
            if case .text(let text) = block { return text.text }
            return nil
        }.joined(separator: " ")
    default:
        return ""
    }
}

private func extractUserContentText(_ content: UserContent) -> String {
    switch content {
    case .text(let text):
        return text
    case .blocks(let blocks):
        return blocks.compactMap { block -> String? in
            if case .text(let text) = block { return text.text }
            return nil
        }.joined(separator: " ")
    }
}

private func buildSessionInfo(_ filePath: String) -> SessionInfo? {
    let entries = loadEntriesFromFile(filePath)
    guard let first = entries.first, case .session(let header) = first else {
        return nil
    }

    let stats = (try? FileManager.default.attributesOfItem(atPath: filePath)) ?? [:]
    let modified = stats[.modificationDate] as? Date ?? Date()
    let created = ISO8601DateFormatter().date(from: header.timestamp) ?? modified

    var messageCount = 0
    var firstMessage = ""
    var allMessages: [String] = []
    var name: String?

    for entry in entries {
        guard case .entry(let sessionEntry) = entry else { continue }
        if case .sessionInfo(let info) = sessionEntry, let infoName = info.name?.trimmingCharacters(in: .whitespacesAndNewlines), !infoName.isEmpty {
            name = infoName
        }
        guard case .message(let messageEntry) = sessionEntry else { continue }
        messageCount += 1
        let message = messageEntry.message
        guard isMessageWithContent(message) else { continue }
        guard message.role == "user" || message.role == "assistant" else { continue }
        let textContent = extractTextContent(message)
        guard !textContent.isEmpty else { continue }
        allMessages.append(textContent)
        if firstMessage.isEmpty, message.role == "user" {
            firstMessage = textContent
        }
    }

    let cwd = header.cwd
    let resolvedFirstMessage = firstMessage.isEmpty ? "(no messages)" : firstMessage

    return SessionInfo(
        path: filePath,
        id: header.id,
        cwd: cwd,
        name: name,
        created: created,
        modified: modified,
        messageCount: messageCount,
        firstMessage: resolvedFirstMessage,
        allMessagesText: allMessages.joined(separator: " ")
    )
}

public typealias SessionListProgress = @Sendable (_ loaded: Int, _ total: Int) -> Void

public final class SessionManager: Sendable {
    private struct State: Sendable {
        var cwd: String
        var sessionDir: String
        var sessionFile: String?
        var header: SessionHeader?
        var entries: [SessionEntry]
        var byId: [String: SessionEntry]
        var labelsById: [String: String]
        var leafId: String?
        var sessionId: String
    }

    private let state: LockedState<State>
    private let persist: Bool

    private var cwd: String {
        get { state.withLock { $0.cwd } }
        set { state.withLock { $0.cwd = newValue } }
    }

    private var sessionDir: String {
        get { state.withLock { $0.sessionDir } }
        set { state.withLock { $0.sessionDir = newValue } }
    }

    private var sessionFile: String? {
        get { state.withLock { $0.sessionFile } }
        set { state.withLock { $0.sessionFile = newValue } }
    }

    private var header: SessionHeader? {
        get { state.withLock { $0.header } }
        set { state.withLock { $0.header = newValue } }
    }

    private var entries: [SessionEntry] {
        get { state.withLock { $0.entries } }
        set { state.withLock { $0.entries = newValue } }
    }

    private var byId: [String: SessionEntry] {
        get { state.withLock { $0.byId } }
        set { state.withLock { $0.byId = newValue } }
    }

    private var labelsById: [String: String] {
        get { state.withLock { $0.labelsById } }
        set { state.withLock { $0.labelsById = newValue } }
    }

    private var leafId: String? {
        get { state.withLock { $0.leafId } }
        set { state.withLock { $0.leafId = newValue } }
    }

    private var sessionId: String {
        get { state.withLock { $0.sessionId } }
        set { state.withLock { $0.sessionId = newValue } }
    }

    private init(_ cwd: String, _ sessionDir: String, _ sessionFile: String?, _ persist: Bool) {
        self.persist = persist
        self.state = LockedState(State(
            cwd: cwd,
            sessionDir: sessionDir,
            sessionFile: sessionFile,
            header: nil,
            entries: [],
            byId: [:],
            labelsById: [:],
            leafId: nil,
            sessionId: UUID().uuidString
        ))
        if let sessionFile {
            loadFromFile(sessionFile)
        }
    }

    public static func create(_ cwd: String, _ sessionDir: String? = nil) -> SessionManager {
        let dir = sessionDir ?? defaultSessionDir(cwd: cwd)
        return SessionManager(cwd, dir, nil, true)
    }

    public static func open(_ path: String, _ sessionDir: String? = nil) -> SessionManager {
        let entries = loadEntriesFromFile(path)
        let header = entries.compactMap { entry -> SessionHeader? in
            if case .session(let header) = entry { return header }
            return nil
        }.first
        let cwd = header?.cwd ?? FileManager.default.currentDirectoryPath
        let dir = sessionDir ?? URL(fileURLWithPath: path).deletingLastPathComponent().path

        // If file exists but is corrupted (empty or no valid header), recover it
        if FileManager.default.fileExists(atPath: path) && entries.isEmpty {
            let sm = SessionManager(cwd, dir, nil, true)
            _ = sm.newSession()
            sm.sessionFile = path
            sm.rewriteFile()
            return sm
        }

        return SessionManager(cwd, dir, path, true)
    }

    public static func continueRecent(_ cwd: String, _ sessionDir: String? = nil) -> SessionManager {
        let dir = sessionDir ?? defaultSessionDir(cwd: cwd)
        if let mostRecent = findMostRecentSession(dir) {
            return SessionManager(cwd, dir, mostRecent, true)
        }
        return SessionManager(cwd, dir, nil, true)
    }

    public static func inMemory(_ cwd: String = FileManager.default.currentDirectoryPath) -> SessionManager {
        SessionManager(cwd, "", nil, false)
    }

    public static func list(
        _ cwd: String,
        _ sessionDir: String? = nil,
        _ onProgress: SessionListProgress? = nil
    ) async -> [SessionInfo] {
        let dir = sessionDir ?? defaultSessionDir(cwd: cwd)
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir) else {
            return []
        }
        let jsonlFiles = files.filter { $0.hasSuffix(".jsonl") }.map { URL(fileURLWithPath: dir).appendingPathComponent($0).path }
        let total = jsonlFiles.count
        var loaded = 0
        var result: [SessionInfo] = []

        for path in jsonlFiles {
            if let info = buildSessionInfo(path) {
                result.append(info)
            }
            loaded += 1
            onProgress?(loaded, total)
        }

        result.sort { $0.modified > $1.modified }
        return result
    }

    public static func listAll(_ onProgress: SessionListProgress? = nil) async -> [SessionInfo] {
        let sessionsDir = getSessionsDir()
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: URL(fileURLWithPath: sessionsDir),
            includingPropertiesForKeys: [.isDirectoryKey],
            options: []
        ) else {
            return []
        }

        var files: [String] = []
        for entry in entries {
            let isDir = (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            guard isDir else { continue }
            if let dirFiles = try? FileManager.default.contentsOfDirectory(atPath: entry.path) {
                for file in dirFiles where file.hasSuffix(".jsonl") {
                    files.append(URL(fileURLWithPath: entry.path).appendingPathComponent(file).path)
                }
            }
        }

        let total = files.count
        var loaded = 0
        var result: [SessionInfo] = []

        for path in files {
            if let info = buildSessionInfo(path) {
                result.append(info)
            }
            loaded += 1
            onProgress?(loaded, total)
        }

        result.sort { $0.modified > $1.modified }
        return result
    }

    public func getCwd() -> String { cwd }
    public func getSessionDir() -> String { sessionDir }
    public func getSessionId() -> String { sessionId }
    public func getSessionFile() -> String? { sessionFile }
    public func getLeafId() -> String? { leafId }

    public func getLeafEntry() -> SessionEntry? {
        guard let leafId else { return nil }
        return byId[leafId]
    }

    public func getEntry(_ id: String) -> SessionEntry? {
        byId[id]
    }

    public func getLabel(_ targetId: String) -> String? {
        labelsById[targetId]
    }

    public func getHeader() -> SessionHeader? {
        header
    }

    public func getEntries() -> [SessionEntry] {
        entries
    }

    public func setSessionFile(_ path: String) {
        sessionDir = URL(fileURLWithPath: path).deletingLastPathComponent().path
        loadFromFile(path)
        if let header {
            cwd = header.cwd
        }
    }

    public func getBranch(_ leafId: String? = nil) -> [SessionEntry] {
        guard let targetId = leafId ?? self.leafId else { return [] }
        guard let leaf = byId[targetId] else { return [] }
        var path: [SessionEntry] = []
        var current: SessionEntry? = leaf
        while let entry = current {
            path.insert(entry, at: 0)
            if let parentId = entry.parentId {
                current = byId[parentId]
            } else {
                current = nil
            }
        }
        return path
    }

    public func getTree() -> [SessionTreeNode] {
        let entries = getEntries()
        let entryMap = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })
        var childrenByParent: [String: [SessionEntry]] = [:]
        var roots: [SessionEntry] = []

        for entry in entries {
            if let parentId = entry.parentId, parentId != entry.id, entryMap[parentId] != nil {
                childrenByParent[parentId, default: []].append(entry)
            } else {
                roots.append(entry)
            }
        }

        func buildNode(_ entry: SessionEntry) -> SessionTreeNode {
            let children = childrenByParent[entry.id] ?? []
            let sortedChildren = children.sorted {
                parseTimestamp($0.timestamp) < parseTimestamp($1.timestamp)
            }
            let childNodes = sortedChildren.map { buildNode($0) }
            return SessionTreeNode(entry: entry, children: childNodes, label: labelsById[entry.id])
        }

        return roots.map { buildNode($0) }
    }

    public func getChildren(_ parentId: String) -> [SessionEntry] {
        entries.filter { $0.parentId == parentId }
    }

    public func buildSessionContext() -> SessionContext {
        if leafId == nil {
            return PiSwiftCodingAgent.buildSessionContext(entries, "null", byId)
        }
        return PiSwiftCodingAgent.buildSessionContext(entries, leafId, byId)
    }

    @discardableResult
    public func newSession(_ options: NewSessionOptions? = nil) -> String? {
        let newSessionId = options?.id ?? UUID().uuidString
        let timestamp = isoNow()
        sessionId = newSessionId
        header = SessionHeader(
            type: "session",
            version: CURRENT_SESSION_VERSION,
            id: newSessionId,
            timestamp: timestamp,
            cwd: cwd,
            parentSession: options?.parentSession
        )
        entries = []
        byId = [:]
        labelsById = [:]
        leafId = nil

        if persist {
            let dir = defaultSessionDir(cwd: cwd, sessionDir: sessionDir.isEmpty ? nil : sessionDir)
            let fileTimestamp = timestamp.replacingOccurrences(of: ":", with: "-").replacingOccurrences(of: ".", with: "-")
            sessionFile = URL(fileURLWithPath: dir).appendingPathComponent("\(fileTimestamp)_\(newSessionId).jsonl").path
            if let header {
                appendLine(sessionFile!, encodeSessionHeader(header))
            }
            return sessionFile
        }

        sessionFile = nil
        return nil
    }

    public func startSession(_ initialState: AgentState) {
        if header != nil { return }
        let sessionId = UUID().uuidString
        let timestamp = isoNow()
        header = SessionHeader(type: "session", version: CURRENT_SESSION_VERSION, id: sessionId, timestamp: timestamp, cwd: cwd, parentSession: nil)
        self.sessionId = sessionId
        if persist {
            ensureSessionFile()
            if let sessionFile {
                appendLine(sessionFile, encodeSessionHeader(header!))
            }
        }
    }

    public func shouldInitializeSession(_ messages: [AgentMessage]) -> Bool {
        header == nil && !messages.isEmpty
    }

    @discardableResult
    public func appendMessage(_ message: AgentMessage) -> String {
        let entry = SessionMessageEntry(id: generateId(existing: Set(byId.keys)), parentId: leafId, timestamp: isoNow(), message: message)
        appendEntry(.message(entry))
        return entry.id
    }

    @discardableResult
    public func appendThinkingLevelChange(_ level: String) -> String {
        let entry = ThinkingLevelChangeEntry(id: generateId(existing: Set(byId.keys)), parentId: leafId, timestamp: isoNow(), thinkingLevel: level)
        appendEntry(.thinkingLevel(entry))
        return entry.id
    }

    @discardableResult
    public func appendModelChange(_ provider: String, _ modelId: String) -> String {
        let entry = ModelChangeEntry(id: generateId(existing: Set(byId.keys)), parentId: leafId, timestamp: isoNow(), provider: provider, modelId: modelId)
        appendEntry(.modelChange(entry))
        return entry.id
    }

    @discardableResult
    public func appendCompaction(_ summary: String, _ firstKeptEntryId: String, _ tokensBefore: Int, details: AnyCodable? = nil, fromHook: Bool? = nil) -> String {
        let entry = CompactionEntry(
            id: generateId(existing: Set(byId.keys)),
            parentId: leafId,
            timestamp: isoNow(),
            summary: summary,
            firstKeptEntryId: firstKeptEntryId,
            tokensBefore: tokensBefore,
            details: details,
            fromHook: fromHook
        )
        appendEntry(.compaction(entry))
        return entry.id
    }

    @discardableResult
    public func appendBranchSummary(_ fromId: String, _ summary: String, details: AnyCodable? = nil, fromHook: Bool? = nil) -> String {
        let entry = BranchSummaryEntry(id: generateId(existing: Set(byId.keys)), parentId: leafId, timestamp: isoNow(), fromId: fromId, summary: summary, details: details, fromHook: fromHook)
        appendEntry(.branchSummary(entry))
        return entry.id
    }

    @discardableResult
    public func appendCustomEntry(_ customType: String, _ data: [String: Any]) -> String {
        let entry = CustomEntry(id: generateId(existing: Set(byId.keys)), parentId: leafId, timestamp: isoNow(), customType: customType, data: AnyCodable(data))
        appendEntry(.custom(entry))
        return entry.id
    }

    @discardableResult
    public func appendCustomMessage(_ customType: String, _ content: HookMessageContent, _ display: Bool, details: AnyCodable? = nil) -> String {
        let entry = CustomMessageEntry(id: generateId(existing: Set(byId.keys)), parentId: leafId, timestamp: isoNow(), customType: customType, content: content, details: details, display: display)
        appendEntry(.customMessage(entry))
        return entry.id
    }

    @discardableResult
    public func appendSessionInfo(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let entry = SessionInfoEntry(id: generateId(existing: Set(byId.keys)), parentId: leafId, timestamp: isoNow(), name: trimmed.isEmpty ? nil : trimmed)
        appendEntry(.sessionInfo(entry))
        return entry.id
    }

    public func getSessionName() -> String? {
        let entries = getEntries()
        for entry in entries.reversed() {
            if case .sessionInfo(let info) = entry, let name = info.name, !name.isEmpty {
                return name
            }
        }
        return nil
    }

    @discardableResult
    public func appendLabelChange(_ targetId: String, _ label: String?) throws -> String {
        guard byId[targetId] != nil else {
            throw SessionManagerError.entryNotFound(targetId)
        }
        let entry = LabelEntry(id: generateId(existing: Set(byId.keys)), parentId: leafId, timestamp: isoNow(), targetId: targetId, label: label)
        appendEntry(.label(entry))
        labelsById[targetId] = label
        return entry.id
    }

    public func branch(_ branchFromId: String) {
        guard byId[branchFromId] != nil else {
            fatalError("Entry \(branchFromId) not found")
        }
        leafId = branchFromId
    }

    public func resetLeaf() {
        leafId = nil
    }

    public func branchWithSummary(_ branchFromId: String?, _ summary: String, details: AnyCodable? = nil, fromHook: Bool? = nil) -> String {
        if let branchFromId, byId[branchFromId] == nil {
            fatalError("Entry \(branchFromId) not found")
        }
        leafId = branchFromId
        let entry = BranchSummaryEntry(id: generateId(existing: Set(byId.keys)), parentId: branchFromId, timestamp: isoNow(), fromId: branchFromId ?? "root", summary: summary, details: details, fromHook: fromHook)
        appendEntry(.branchSummary(entry))
        return entry.id
    }

    public func createBranchedSession(_ leafId: String) -> String? {
        let path = getBranch(leafId)
        if path.isEmpty {
            fatalError("Entry \(leafId) not found")
        }

        let pathWithoutLabels = path.filter { $0.type != "label" }
        let labelsToWrite = labelsById.filter { id, _ in pathWithoutLabels.contains(where: { $0.id == id }) }

        if persist {
            let newSessionId = UUID().uuidString
            let timestamp = isoNow()
            let fileTimestamp = timestamp.replacingOccurrences(of: ":", with: "-").replacingOccurrences(of: ".", with: "-")
            let newSessionFile = URL(fileURLWithPath: sessionDir).appendingPathComponent("\(fileTimestamp)_\(newSessionId).jsonl").path

            let header = SessionHeader(type: "session", version: CURRENT_SESSION_VERSION, id: newSessionId, timestamp: timestamp, cwd: cwd, parentSession: sessionFile)
            // Guard against duplicate header if the target file already exists
            if !FileManager.default.fileExists(atPath: newSessionFile) {
                appendLine(newSessionFile, encodeSessionHeader(header))
            }
            for entry in pathWithoutLabels {
                appendLine(newSessionFile, encodeSessionEntry(entry))
            }

            var parentId = pathWithoutLabels.last?.id
            for (targetId, label) in labelsToWrite {
                let labelEntry = LabelEntry(id: generateId(existing: Set(byId.keys)), parentId: parentId, timestamp: isoNow(), targetId: targetId, label: label)
                appendLine(newSessionFile, encodeSessionEntry(.label(labelEntry)))
                parentId = labelEntry.id
            }

            loadFromFile(newSessionFile)
            return newSessionFile
        }

        var newEntries: [SessionEntry] = pathWithoutLabels
        var parentId = pathWithoutLabels.last?.id
        for (targetId, label) in labelsToWrite {
            let labelEntry = LabelEntry(id: generateId(existing: Set(byId.keys)), parentId: parentId, timestamp: isoNow(), targetId: targetId, label: label)
            newEntries.append(.label(labelEntry))
            parentId = labelEntry.id
        }
        entries = newEntries
        rebuildIndex()
        return nil
    }

    private func appendEntry(_ entry: SessionEntry) {
        ensureSessionFile()
        entries.append(entry)
        byId[entry.id] = entry
        leafId = entry.id
        if entry.type == "label", case .label(let labelEntry) = entry {
            labelsById[labelEntry.targetId] = labelEntry.label
        }
        if persist, let sessionFile {
            // Defer writing the session file until we have at least one assistant message.
            // This prevents creating empty/useless session files for abandoned prompts.
            let isAssistant: Bool
            if case .message(let msg) = entry, case .assistant = msg.message {
                isAssistant = true
            } else {
                isAssistant = false
            }
            if isAssistant && !FileManager.default.fileExists(atPath: sessionFile) {
                // First assistant message: flush the header and all buffered entries
                if let header {
                    appendLine(sessionFile, encodeSessionHeader(header))
                }
                for buffered in entries {
                    appendLine(sessionFile, encodeSessionEntry(buffered))
                }
            } else if FileManager.default.fileExists(atPath: sessionFile) {
                appendLine(sessionFile, encodeSessionEntry(entry))
            }
            // Otherwise (no file yet and not an assistant message): skip writing
        }
    }

    /// Returns true when the entries contain at least one assistant message.
    private func hasAssistantMessage() -> Bool {
        entries.contains { entry in
            if case .message(let msg) = entry, case .assistant = msg.message {
                return true
            }
            return false
        }
    }

    private func ensureSessionFile() {
        guard persist else { return }
        if sessionFile == nil {
            let dir = defaultSessionDir(cwd: cwd, sessionDir: sessionDir.isEmpty ? nil : sessionDir)
            let sessionId = UUID().uuidString
            let timestamp = isoNow()
            let fileTimestamp = timestamp.replacingOccurrences(of: ":", with: "-").replacingOccurrences(of: ".", with: "-")
            let newSessionFile = URL(fileURLWithPath: dir).appendingPathComponent("\(fileTimestamp)_\(sessionId).jsonl").path
            sessionFile = newSessionFile
            header = SessionHeader(type: "session", version: CURRENT_SESSION_VERSION, id: sessionId, timestamp: timestamp, cwd: cwd, parentSession: nil)
            // Don't write to disk yet — deferred until the first assistant message arrives.
        }
    }

    private func rewriteFile() {
        guard persist, let sessionFile else { return }
        var lines: [String] = []
        if let header {
            lines.append(encodeSessionHeader(header))
        }
        for entry in entries {
            lines.append(encodeSessionEntry(entry))
        }
        let content = lines.joined(separator: "\n") + "\n"
        try? content.write(toFile: sessionFile, atomically: true, encoding: .utf8)
    }

    private func loadFromFile(_ path: String) {
        var entries = loadEntriesFromFile(path)
        let migrated = migrateSessionEntries(&entries)
        self.entries = entries.compactMap { entry -> SessionEntry? in
            if case .entry(let entry) = entry { return entry }
            return nil
        }
        if let headerEntry = entries.first, case .session(let header) = headerEntry {
            self.header = header
            self.sessionId = header.id
        }
        self.sessionFile = path
        rebuildIndex()
        if migrated {
            rewriteFile()
        }
    }

    private func rebuildIndex() {
        byId = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })
        labelsById = [:]
        for entry in entries {
            if case .label(let label) = entry {
                labelsById[label.targetId] = label.label
            }
        }
        leafId = entries.last?.id
    }
}

private func isoNow() -> String {
    ISO8601DateFormatter().string(from: Date())
}

private func parseTimestamp(_ value: String) -> Int64 {
    let ts = ISO8601DateFormatter().date(from: value)?.timeIntervalSince1970 ?? Date().timeIntervalSince1970
    return Int64(ts * 1000)
}

private func generateId(existing: Set<String>) -> String {
    for _ in 0..<100 {
        let id = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8))
        if !existing.contains(id) {
            return id
        }
    }
    return UUID().uuidString
}

public func getDefaultSessionDir(cwd: String, sessionDir: String? = nil, agentDir: String? = nil) -> String {
    if let sessionDir, !sessionDir.isEmpty {
        // v0.68.1: expand `~` in `sessionDir` so portable settings.json values
        // (e.g., `"sessionDir": "~/sessions"`) work without a shell wrapper.
        let expanded = (sessionDir as NSString).expandingTildeInPath
        try? FileManager.default.createDirectory(atPath: expanded, withIntermediateDirectories: true)
        return expanded
    }
    let resolvedAgentDir = agentDir ?? getAgentDir()
    let safePath = "--" + cwd.replacingOccurrences(of: "\\", with: "-").replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-") + "--"
    let dir = URL(fileURLWithPath: resolvedAgentDir).appendingPathComponent("sessions").appendingPathComponent(safePath).path
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    return dir
}

private func defaultSessionDir(cwd: String, sessionDir: String? = nil) -> String {
    getDefaultSessionDir(cwd: cwd, sessionDir: sessionDir)
}

private func appendLine(_ path: String, _ line: String) {
    let data = (line + "\n").data(using: .utf8) ?? Data()
    if FileManager.default.fileExists(atPath: path) {
        if let handle = try? FileHandle(forWritingTo: URL(fileURLWithPath: path)) {
            handle.seekToEndOfFile()
            try? handle.write(contentsOf: data)
            try? handle.close()
            return
        }
    }
    try? data.write(to: URL(fileURLWithPath: path))
}

private func encodeSessionHeader(_ header: SessionHeader) -> String {
    var dict: [String: Any] = [
        "type": "session",
        "id": header.id,
        "timestamp": header.timestamp,
        "cwd": header.cwd,
    ]
    if let version = header.version { dict["version"] = version }
    if let parentSession = header.parentSession { dict["parentSession"] = parentSession }
    let data = try? JSONSerialization.data(withJSONObject: dict, options: [])
    return String(data: data ?? Data(), encoding: .utf8) ?? ""
}

private func encodeSessionEntry(_ entry: SessionEntry) -> String {
    let dict = sessionEntryToDict(entry)
    let data = try? JSONSerialization.data(withJSONObject: dict, options: [])
    return String(data: data ?? Data(), encoding: .utf8) ?? ""
}

private func decodeSessionHeader(_ dict: [String: Any]) -> SessionHeader? {
    guard let id = dict["id"] as? String,
          let timestamp = dict["timestamp"] as? String else {
        return nil
    }
    let cwd = dict["cwd"] as? String ?? ""
    let version = dict["version"] as? Int
    let parentSession = dict["parentSession"] as? String
    return SessionHeader(type: "session", version: version, id: id, timestamp: timestamp, cwd: cwd, parentSession: parentSession)
}

private func decodeSessionEntry(_ dict: [String: Any]) -> SessionEntry? {
    guard let type = dict["type"] as? String else { return nil }
    let id = dict["id"] as? String ?? ""
    let parentId = dict["parentId"] as? String
    let timestamp = dict["timestamp"] as? String ?? isoNow()

    switch type {
    case "message":
        guard let messageDict = dict["message"] as? [String: Any],
              let message = decodeAgentMessage(messageDict) else { return nil }
        let entry = SessionMessageEntry(id: id, parentId: parentId, timestamp: timestamp, message: message)
        return .message(entry)
    case "thinking_level_change":
        let level = dict["thinkingLevel"] as? String ?? "off"
        return .thinkingLevel(ThinkingLevelChangeEntry(id: id, parentId: parentId, timestamp: timestamp, thinkingLevel: level))
    case "model_change":
        let provider = dict["provider"] as? String ?? ""
        let modelId = dict["modelId"] as? String ?? ""
        return .modelChange(ModelChangeEntry(id: id, parentId: parentId, timestamp: timestamp, provider: provider, modelId: modelId))
    case "compaction":
        let summary = dict["summary"] as? String ?? ""
        let firstKeptEntryId = dict["firstKeptEntryId"] as? String ?? ""
        let tokensBefore = dict["tokensBefore"] as? Int ?? 0
        let details = dict["details"].map { AnyCodable($0) }
        let fromHook = dict["fromHook"] as? Bool
        return .compaction(CompactionEntry(id: id, parentId: parentId, timestamp: timestamp, summary: summary, firstKeptEntryId: firstKeptEntryId, tokensBefore: tokensBefore, details: details, fromHook: fromHook))
    case "branch_summary":
        let summary = dict["summary"] as? String ?? ""
        let fromId = dict["fromId"] as? String ?? ""
        let details = dict["details"].map { AnyCodable($0) }
        let fromHook = dict["fromHook"] as? Bool
        return .branchSummary(BranchSummaryEntry(id: id, parentId: parentId, timestamp: timestamp, fromId: fromId, summary: summary, details: details, fromHook: fromHook))
    case "custom":
        let customType = dict["customType"] as? String ?? ""
        let data = dict["data"].map { AnyCodable($0) }
        return .custom(CustomEntry(id: id, parentId: parentId, timestamp: timestamp, customType: customType, data: data))
    case "custom_message":
        let customType = dict["customType"] as? String ?? ""
        let display = dict["display"] as? Bool ?? true
        let details = dict["details"].map { AnyCodable($0) }
        let contentValue = dict["content"]
        let content: HookMessageContent
        if let text = contentValue as? String {
            content = .text(text)
        } else if let blocks = contentValue as? [Any] {
            let contentBlocks = blocks.compactMap { block -> ContentBlock? in
                guard let dict = block as? [String: Any] else { return nil }
                return contentBlockFromDict(dict)
            }
            content = .blocks(contentBlocks)
        } else {
            content = .text("")
        }
        return .customMessage(CustomMessageEntry(id: id, parentId: parentId, timestamp: timestamp, customType: customType, content: content, details: details, display: display))
    case "label":
        let targetId = dict["targetId"] as? String ?? ""
        let label = dict["label"] as? String
        return .label(LabelEntry(id: id, parentId: parentId, timestamp: timestamp, targetId: targetId, label: label))
    case "session_info":
        let name = (dict["name"] as? String).map { stripControlCharacters($0) }
        return .sessionInfo(SessionInfoEntry(id: id, parentId: parentId, timestamp: timestamp, name: name))
    default:
        return nil
    }
}

private func decodeAgentMessage(_ dict: [String: Any]) -> AgentMessage? {
    guard let role = dict["role"] as? String else { return nil }
    switch role {
    case "user":
        let timestamp = (dict["timestamp"] as? Int64) ?? Int64(Date().timeIntervalSince1970 * 1000)
        let contentValue = dict["content"]
        let content: UserContent
        if let text = contentValue as? String {
            content = .text(text)
        } else if let blocks = contentValue as? [Any] {
            let contentBlocks = blocks.compactMap { block -> ContentBlock? in
                guard let dict = block as? [String: Any] else { return nil }
                return contentBlockFromDict(dict)
            }
            content = .blocks(contentBlocks)
        } else {
            content = .text("")
        }
        return .user(UserMessage(content: content, timestamp: timestamp))
    case "assistant":
        let timestamp = (dict["timestamp"] as? Int64) ?? Int64(Date().timeIntervalSince1970 * 1000)
        let api = Api(rawValue: dict["api"] as? String ?? "") ?? .openAIResponses
        let provider = dict["provider"] as? String ?? ""
        let model = dict["model"] as? String ?? ""
        let stopReason = StopReason(rawValue: dict["stopReason"] as? String ?? "stop") ?? .stop
        let errorMessage = dict["errorMessage"] as? String
        let usageDict = dict["usage"] as? [String: Any] ?? [:]
        let usage = decodeUsage(usageDict)
        let contentBlocks = (dict["content"] as? [Any] ?? []).compactMap { block -> ContentBlock? in
            guard let dict = block as? [String: Any] else { return nil }
            return contentBlockFromDict(dict)
        }
        let assistant = AssistantMessage(content: contentBlocks, api: api, provider: provider, model: model, usage: usage, stopReason: stopReason, errorMessage: errorMessage, timestamp: timestamp)
        return .assistant(assistant)
    case "toolResult":
        let timestamp = (dict["timestamp"] as? Int64) ?? Int64(Date().timeIntervalSince1970 * 1000)
        let toolCallId = dict["toolCallId"] as? String ?? ""
        let toolName = dict["toolName"] as? String ?? ""
        let isError = dict["isError"] as? Bool ?? false
        let details = dict["details"].map { AnyCodable($0) }
        let contentBlocks = (dict["content"] as? [Any] ?? []).compactMap { block -> ContentBlock? in
            guard let dict = block as? [String: Any] else { return nil }
            return contentBlockFromDict(dict)
        }
        let toolResult = ToolResultMessage(toolCallId: toolCallId, toolName: toolName, content: contentBlocks, details: details, isError: isError, timestamp: timestamp)
        return .toolResult(toolResult)
    case "bashExecution", "hookMessage", "branchSummary", "compactionSummary":
        let payload = dict
        let timestamp = (dict["timestamp"] as? Int64) ?? Int64(Date().timeIntervalSince1970 * 1000)
        return .custom(AgentCustomMessage(role: role, payload: AnyCodable(payload), timestamp: timestamp))
    default:
        return nil
    }
}

private func decodeUsage(_ dict: [String: Any]) -> Usage {
    let input = dict["input"] as? Int ?? 0
    let output = dict["output"] as? Int ?? 0
    let cacheRead = dict["cacheRead"] as? Int ?? 0
    let cacheWrite = dict["cacheWrite"] as? Int ?? 0
    let totalTokens = dict["totalTokens"] as? Int ?? (input + output + cacheRead + cacheWrite)
    var usage = Usage(input: input, output: output, cacheRead: cacheRead, cacheWrite: cacheWrite, totalTokens: totalTokens)
    if let cost = dict["cost"] as? [String: Any] {
        usage.cost.input = cost["input"] as? Double ?? 0
        usage.cost.output = cost["output"] as? Double ?? 0
        usage.cost.cacheRead = cost["cacheRead"] as? Double ?? 0
        usage.cost.cacheWrite = cost["cacheWrite"] as? Double ?? 0
        usage.cost.total = cost["total"] as? Double ?? 0
    }
    return usage
}

private func sessionEntryToDict(_ entry: SessionEntry) -> [String: Any] {
    var dict: [String: Any] = [
        "type": entry.type,
        "id": entry.id,
        "parentId": entry.parentId as Any,
        "timestamp": entry.timestamp,
    ]

    switch entry {
    case .message(let message):
        dict["message"] = agentMessageToDict(message.message)
    case .thinkingLevel(let entry):
        dict["thinkingLevel"] = entry.thinkingLevel
    case .modelChange(let entry):
        dict["provider"] = entry.provider
        dict["modelId"] = entry.modelId
    case .compaction(let entry):
        dict["summary"] = entry.summary
        dict["firstKeptEntryId"] = entry.firstKeptEntryId
        dict["tokensBefore"] = entry.tokensBefore
        if let details = entry.details?.jsonValue {
            dict["details"] = details
        }
        if let fromHook = entry.fromHook {
            dict["fromHook"] = fromHook
        }
    case .branchSummary(let entry):
        dict["fromId"] = entry.fromId
        dict["summary"] = entry.summary
        if let details = entry.details?.jsonValue {
            dict["details"] = details
        }
        if let fromHook = entry.fromHook {
            dict["fromHook"] = fromHook
        }
    case .custom(let entry):
        dict["customType"] = entry.customType
        if let data = entry.data?.jsonValue {
            dict["data"] = data
        }
    case .customMessage(let entry):
        dict["customType"] = entry.customType
        dict["display"] = entry.display
        switch entry.content {
        case .text(let text):
            dict["content"] = text
        case .blocks(let blocks):
            dict["content"] = blocks.map { contentBlockToDict($0) }
        }
        if let details = entry.details?.jsonValue {
            dict["details"] = details
        }
    case .label(let entry):
        dict["targetId"] = entry.targetId
        dict["label"] = entry.label as Any
    case .sessionInfo(let entry):
        dict["name"] = entry.name as Any
    }

    return dict
}

private func agentMessageToDict(_ message: AgentMessage) -> [String: Any] {
    switch message {
    case .user(let user):
        var dict: [String: Any] = [
            "role": "user",
            "timestamp": user.timestamp,
        ]
        switch user.content {
        case .text(let text):
            dict["content"] = text
        case .blocks(let blocks):
            dict["content"] = blocks.map { contentBlockToDict($0) }
        }
        return dict
    case .assistant(let assistant):
        return [
            "role": "assistant",
            "content": assistant.content.map { contentBlockToDict($0) },
            "api": assistant.api.rawValue,
            "provider": assistant.provider,
            "model": assistant.model,
            "usage": encodeUsage(assistant.usage),
            "stopReason": assistant.stopReason.rawValue,
            "timestamp": assistant.timestamp,
            "errorMessage": assistant.errorMessage as Any,
        ]
    case .toolResult(let result):
        return [
            "role": "toolResult",
            "toolCallId": result.toolCallId,
            "toolName": result.toolName,
            "content": result.content.map { contentBlockToDict($0) },
            "details": result.details?.jsonValue as Any,
            "isError": result.isError,
            "timestamp": result.timestamp,
        ]
    case .custom(let custom):
        var dict: [String: Any] = ["role": custom.role, "timestamp": custom.timestamp]
        if let payload = custom.payload?.jsonValue as? [String: Any] {
            for (key, value) in payload {
                dict[key] = value
            }
        }
        return dict
    }
}

private func encodeUsage(_ usage: Usage) -> [String: Any] {
    [
        "input": usage.input,
        "output": usage.output,
        "cacheRead": usage.cacheRead,
        "cacheWrite": usage.cacheWrite,
        "totalTokens": usage.totalTokens,
        "cost": [
            "input": usage.cost.input,
            "output": usage.cost.output,
            "cacheRead": usage.cost.cacheRead,
            "cacheWrite": usage.cost.cacheWrite,
            "total": usage.cost.total,
        ],
    ]
}
