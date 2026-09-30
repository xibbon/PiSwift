import Foundation
import PiSwiftAI
import PiSwiftAgent

public let BUG_REPORT_CUSTOM_ENTRY_TYPE = "pi.bug-report"
private let redacted = "<redacted>"
private let sensitivePattern = try? NSRegularExpression(pattern: "(?:^|[-_])(api[-_]?key|secret|token|password|passwd|credential|authorization|cookie)(?:$|[-_])", options: [.caseInsensitive])

private func isSensitiveKey(_ key: String) -> Bool {
    let split = key.replacingOccurrences(of: "([a-z0-9])([A-Z])", with: "$1_$2", options: .regularExpression)
    return sensitivePattern?.firstMatch(in: split, range: NSRange(split.startIndex..., in: split)) != nil
}

public func redactBugReportURL(_ value: String) -> String {
    if let colon = value.firstIndex(of: ":"), value[value.index(after: colon)...].range(of: "://") != nil,
       !value[..<colon].contains("/") {
        let rest = String(value[value.index(after: colon)...])
        if let nested = URLComponents(string: rest), nested.scheme != nil {
            return String(value[...colon]) + redactBugReportURL(rest)
        }
    }
    guard var url = URLComponents(string: value), url.scheme != nil else { return value }
    var changed = false
    if url.user != nil || url.password != nil { url.user = nil; url.password = nil; changed = true }
    if let items = url.queryItems {
        let updated = items.map { item -> URLQueryItem in
            guard isSensitiveKey(item.name) else { return item }
            changed = true
            return URLQueryItem(name: item.name, value: redacted)
        }
        if changed { url.queryItems = updated }
    }
    return changed ? (url.string ?? value) : value
}

public func redactBugReportValue(_ value: AnyCodable) -> AnyCodable {
    func redact(_ input: Any, key: String = "") -> Any {
        if isSensitiveKey(key), !(input is NSNull) { return redacted }
        if let object = input as? [String: Any] { return object.mapValues { $0 }.map { ($0.key, redact($0.value, key: $0.key)) }.reduce(into: [String: Any]()) { $0[$1.0] = $1.1 } }
        if let array = input as? [Any] { return array.map { redact($0) } }
        if let string = input as? String { return redactBugReportURL(string) }
        return input
    }
    return AnyCodable(redact(value.jsonValue))
}

public struct BugReportExtension: Sendable {
    public var path: String
    public var source: String
    public var scope: String
    public var origin: String
    public var hidden: Bool

    public init(path: String, source: String, scope: String, origin: String, hidden: Bool = false) {
        self.path = path; self.source = source; self.scope = scope; self.origin = origin; self.hidden = hidden
    }
}

public struct BugReportMetadataInput: Sendable {
    public var id: String
    public var version: String
    public var hint: String?
    public var sessionId: String
    public var cwd: String
    public var includeSession: Bool
    public var includeSummary: Bool
    public var messageCount: Int
    public var model: Model?
    /// Provider status and auth facts from the host's model registry. No credentials.
    public var provider: [String: AnyCodable]?
    public var thinkingLevel: String
    public var extensions: [BugReportExtension]
    public var extensionErrors: [[String: String]]
    public var globalSettings: [String: AnyCodable]
    public var projectSettings: [String: AnyCodable]

    public init(id: String = (try? uuidv7()) ?? UUID().uuidString.lowercased(), version: String = VERSION,
                hint: String? = nil, sessionId: String, cwd: String,
                includeSession: Bool, includeSummary: Bool, messageCount: Int, model: Model? = nil,
                provider: [String: AnyCodable]? = nil, thinkingLevel: String,
                extensions: [BugReportExtension] = [], extensionErrors: [[String: String]] = [],
                globalSettings: [String: AnyCodable] = [:], projectSettings: [String: AnyCodable] = [:]) {
        self.id = id; self.version = version; self.hint = hint; self.sessionId = sessionId; self.cwd = cwd
        self.includeSession = includeSession; self.includeSummary = includeSummary; self.messageCount = messageCount
        self.model = model; self.provider = provider; self.thinkingLevel = thinkingLevel
        self.extensions = extensions; self.extensionErrors = extensionErrors
        self.globalSettings = globalSettings; self.projectSettings = projectSettings
    }
}

public func collectBugReportMetadata(_ input: BugReportMetadataInput, environment: [String: String] = ProcessInfo.processInfo.environment) -> [String: AnyCodable] {
    let terminal: [String: Any] = [
        "term": environment["TERM"] ?? NSNull() as Any, "program": environment["TERM_PROGRAM"] ?? NSNull() as Any,
        "programVersion": environment["TERM_PROGRAM_VERSION"] ?? NSNull() as Any, "colorterm": environment["COLORTERM"] ?? NSNull() as Any,
        "tmux": environment["TMUX"] != nil, "ssh": ["SSH_CONNECTION", "SSH_CLIENT", "SSH_TTY"].contains { environment[$0] != nil },
        "ci": environment["CI"] != nil,
    ]
    var model: [String: Any]?
    if let item = input.model {
        model = ["provider": item.provider, "id": item.id, "name": item.name, "api": item.api.rawValue,
                 "baseUrl": redactBugReportURL(item.baseUrl), "reasoning": item.reasoning,
                 "input": item.input.map(\.rawValue), "contextWindow": item.contextWindow, "maxTokens": item.maxTokens,
                 "headerNames": (item.headers?.keys.sorted() ?? []),
                 "samplingParams": item.samplingParams.map { redactBugReportValue(AnyCodable($0.mapValues(\.jsonValue))).jsonValue } ?? NSNull()]
        if let compat = item.compat, let encoded = try? JSONEncoder().encode(compat), let object = try? JSONSerialization.jsonObject(with: encoded) {
            model?["compat"] = redactBugReportValue(AnyCodable(object)).jsonValue
        } else { model?["compat"] = NSNull() }
        if let map = item.thinkingLevelMap, let encoded = try? JSONEncoder().encode(map), let object = try? JSONSerialization.jsonObject(with: encoded) {
            model?["thinkingLevelMap"] = object
        } else { model?["thinkingLevelMap"] = NSNull() }
    }
    var global = input.globalSettings
    var project = input.projectSettings
    global.removeValue(forKey: "trackingId")
    project.removeValue(forKey: "trackingId")
    global.removeValue(forKey: "deviceId")
    project.removeValue(forKey: "deviceId")
    var session: [String: Any] = ["id": input.sessionId, "included": input.includeSession,
                                  "summaryIncluded": input.includeSummary, "messageCount": input.messageCount]
    if input.includeSession { session["cwd"] = input.cwd }
    let metadata: [String: Any] = [
        "schemaVersion": 1, "id": input.id, "createdAt": ISO8601DateFormatter().string(from: Date()),
        "hint": input.hint?.trimmingCharacters(in: .whitespacesAndNewlines) ?? NSNull() as Any,
        "environment": ["version": input.version, "userAgent": "PiSwift/\(input.version)", "runtime": "swift/\(swiftVersionForBugReport)",
                        "platform": ProcessInfo.processInfo.operatingSystemVersionString,
                        "arch": architectureForBugReport, "osRelease": ProcessInfo.processInfo.operatingSystemVersionString,
                        "shell": environment["SHELL"].map { URL(fileURLWithPath: $0).lastPathComponent } ?? NSNull() as Any,
                        "terminal": terminal, "piEnvironmentVariables": environment.keys.filter { $0.hasPrefix("PI_") }.sorted()] as [String: Any],
        "session": session,
        "model": model ?? NSNull() as Any, "provider": input.provider?.mapValues(\.jsonValue) ?? NSNull() as Any,
        "thinkingLevel": input.thinkingLevel,
        "extensions": input.extensions.map { ["path": $0.path, "source": redactBugReportURL($0.source), "scope": $0.scope, "origin": $0.origin, "hidden": $0.hidden] as [String: Any] },
        "extensionErrors": input.extensionErrors, "settings": ["global": global.mapValues(\.jsonValue), "project": project.mapValues(\.jsonValue)],
    ]
    return metadata.mapValues { redactBugReportValue(AnyCodable($0)) }
}

private let swiftVersionForBugReport = "6"
private let architectureForBugReport: String = {
    #if arch(arm64)
    "arm64"
    #elseif arch(x86_64)
    "x86_64"
    #else
    "unknown"
    #endif
}()

public func collectBugReportDiagnostics(_ session: SessionManager, crashes: [CrashRecord] = []) -> [String: AnyCodable] {
    let entries = session.getEntries()
    var assistantCount = 0
    var assistant: [[String: Any]] = []
    for entry in entries {
        guard case .message(let item) = entry, case .assistant(let message) = item.message else { continue }
        assistantCount += 1
        let diagnostics = message.diagnostics ?? []
        guard !diagnostics.isEmpty || message.stopReason == .error || message.stopReason == .aborted || message.errorMessage != nil else { continue }
        var record: [String: Any] = ["entryId": item.id, "timestamp": item.timestamp,
                                     "provider": message.provider, "model": message.model,
                                     "api": message.api.rawValue, "stopReason": message.stopReason.rawValue,
                                     "diagnostics": diagnostics.map { ["type": $0.type, "timestamp": $0.timestamp,
                                                                          "details": $0.details.mapValues(\.jsonValue)] as [String: Any] }]
        if let reason = message.rawStopReason { record["rawStopReason"] = reason }
        if let error = message.errorMessage { record["errorMessage"] = error }
        assistant.append(record)
    }
    let crashValues = crashes.map { record -> [String: Any] in
        ["timestamp": record.timestamp, "version": record.version, "kind": record.kind.rawValue,
         "message": record.message, "stack": record.stack ?? NSNull() as Any, "sessionFile": record.sessionFile ?? NSNull() as Any, "cwd": record.cwd]
    }
    return ["schemaVersion": AnyCodable(1), "sessionId": AnyCodable(session.getSessionId()),
            "entryCount": AnyCodable(entries.count), "assistantMessageCount": AnyCodable(assistantCount),
            "assistant": AnyCodable(assistant), "crashes": AnyCodable(crashValues)]
}

public struct BugReportBundle: Sendable {
    public var metadata: [String: AnyCodable]
    public var diagnostics: [String: AnyCodable]
    public var sessionJsonl: String?
    public var summary: String?

    public init(metadata: [String: AnyCodable], diagnostics: [String: AnyCodable], sessionJsonl: String? = nil, summary: String? = nil) {
        self.metadata = metadata; self.diagnostics = diagnostics; self.sessionJsonl = sessionJsonl; self.summary = summary
    }
}

/// The host supplies a model-written summary only after the user elects to omit
/// the transcript. Export-only trailing entries use C1's serializer callback.
public func makeBugReportBundle(
    metadata: [String: AnyCodable], session: SessionManager, crashes: [CrashRecord] = [],
    includeSession: Bool, summary: String? = nil,
    createTrailingEntries: ((_ parentId: String?, _ timestamp: String) throws -> [[String: AnyCodable]])? = nil
) throws -> BugReportBundle {
    BugReportBundle(metadata: metadata, diagnostics: collectBugReportDiagnostics(session, crashes: crashes),
                    sessionJsonl: includeSession ? try serializeSessionBranch(session, createTrailingEntries: createTrailingEntries) : nil,
                    summary: summary)
}

public actor BugReportHintTracker {
    private var suggestedSessions: Set<String> = []

    public init() {}

    /// Call after an assistant error or exhausted retry. A retryable failure gets
    /// no hint until the retry budget is exhausted; cancellation gets none.
    public func shouldSuggest(sessionId: String, message: AssistantMessage, retryExhausted: Bool = false) -> Bool {
        guard message.stopReason == .error, !suggestedSessions.contains(sessionId) else { return false }
        let error = message.errorMessage?.lowercased() ?? ""
        guard !error.contains("abort"), !error.contains("cancel") else { return false }
        guard retryExhausted || !isRetryableAssistantError(message) else { return false }
        suggestedSessions.insert(sessionId)
        return true
    }
}

public struct BugReportFile: Sendable {
    public var name: String
    public var contentType: String
    public var data: String
}

public func bugReportFiles(_ bundle: BugReportBundle) throws -> [BugReportFile] {
    func json(_ value: [String: AnyCodable]) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return String(decoding: try encoder.encode(value), as: UTF8.self) + "\n"
    }
    var files = [BugReportFile(name: "report.json", contentType: "application/json", data: try json(bundle.metadata)),
                 BugReportFile(name: "diagnostics.json", contentType: "application/json", data: try json(bundle.diagnostics))]
    if let transcript = bundle.sessionJsonl { files.append(BugReportFile(name: "session.jsonl", contentType: "application/x-ndjson", data: transcript)) }
    if let summary = bundle.summary { files.append(BugReportFile(name: "summary.md", contentType: "text/markdown", data: summary.hasSuffix("\n") ? summary : summary + "\n")) }
    return files
}

public func writeBugReportArchive(_ bundle: BugReportBundle, to path: String) throws {
    try writeZipArchive(bugReportFiles(bundle).map { ZipEntry(name: $0.name, text: $0.data) }, to: path)
}

public func bugReportArchiveFileName(id: String) -> String { "pi-bug-report-\(id).zip" }

public func appendBugReportSessionEntry(_ session: SessionManager, id: String, hint: String?, includeSession: Bool,
                                        includeSummary: Bool, delivery: String = "zip", path: String? = nil) {
    var data: [String: Any] = ["id": id, "createdAt": ISO8601DateFormatter().string(from: Date()),
                               "hint": hint ?? NSNull() as Any, "sessionIncluded": includeSession,
                               "summaryIncluded": includeSummary, "delivery": delivery]
    if let path { data["path"] = path }
    _ = session.appendCustomEntry(BUG_REPORT_CUSTOM_ENTRY_TYPE, data)
}

/// Upload is a host concern. Radius has no implementation in the mobile library.
public protocol BugReportUploader: Sendable {
    func upload(_ bundle: BugReportBundle) async throws -> String
}
