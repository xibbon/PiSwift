import Foundation
import CoreFoundation

/// How MCP tools are made available to the model.
public enum McpExposure: String, Codable, Sendable, CaseIterable {
    case codemode
    case codemodeDeferred = "codemode-deferred"
    case deferred
    case direct
    case hidden
}

public struct McpOAuthConfig: Codable, Sendable, Equatable {
    public var clientId: String?
    public var clientSecret: String?
    public var callbackPort: Int?
    public var callbackUrl: String?
    public var scope: String?

    public init(clientId: String? = nil, clientSecret: String? = nil,
                callbackPort: Int? = nil, callbackUrl: String? = nil, scope: String? = nil) {
        self.clientId = clientId
        self.clientSecret = clientSecret
        self.callbackPort = callbackPort
        self.callbackUrl = callbackUrl
        self.scope = scope
    }
}

/// One upstream `mcpServers` entry. Use `validateMcpServerConfig` before registering it.
public struct McpServerConfig: Codable, Sendable, Equatable {
    public var type: String?
    public var command: String?
    public var args: [String]?
    public var env: [String: String]?
    public var cwd: String?
    public var url: String?
    public var headers: [String: String]?
    public var oauth: McpOAuthConfig?
    public var exposure: McpExposure?
    public var toolExposure: [String: McpExposure]?
    public var enabled: Bool?
    public var timeout: Double?
    /// Pattern order from the JSON object. It is omitted from JSON output.
    public var toolExposureOrder: [String] = []

    private enum CodingKeys: String, CodingKey {
        case type, command, args, env, cwd, url, headers, oauth, exposure, toolExposure, enabled, timeout
    }

    public init(type: String? = nil, command: String? = nil, args: [String]? = nil,
                env: [String: String]? = nil, cwd: String? = nil, url: String? = nil,
                headers: [String: String]? = nil, oauth: McpOAuthConfig? = nil,
                exposure: McpExposure? = nil, toolExposure: [String: McpExposure]? = nil,
                enabled: Bool? = nil, timeout: Double? = nil,
                toolExposureOrder: [String] = []) {
        self.type = type
        self.command = command
        self.args = args
        self.env = env
        self.cwd = cwd
        self.url = url
        self.headers = headers
        self.oauth = oauth
        self.exposure = exposure
        self.toolExposure = toolExposure
        self.enabled = enabled
        self.timeout = timeout
        self.toolExposureOrder = toolExposureOrder
    }

    public var isHTTP: Bool { url != nil && (type == nil || type == "http" || type == "streamable-http") }
    public var isStdio: Bool { command != nil && (type == nil || type == "stdio") }
    public var isEnabled: Bool { enabled != false }
    public var effectiveExposure: McpExposure { exposure ?? .codemode }
    public var timeoutSeconds: Double { timeout ?? 60 }
}

public struct McpServerEntry: Sendable, Equatable {
    public enum Scope: String, Codable, Sendable { case global, project, `extension` }
    public var name: String
    public var config: McpServerConfig
    public var source: String
    public var scope: Scope

    public init(name: String, config: McpServerConfig, source: String, scope: Scope) {
        self.name = name
        self.config = config
        self.source = source
        self.scope = scope
    }
}

public struct LoadedMcpConfig: Sendable {
    public var servers: [McpServerEntry]
    public var autoEnableCodemode: Bool?
    public var errors: [String]

    public init(servers: [McpServerEntry] = [], autoEnableCodemode: Bool? = nil, errors: [String] = []) {
        self.servers = servers
        self.autoEnableCodemode = autoEnableCodemode
        self.errors = errors
    }
}

public enum McpConfigError: Error, LocalizedError, Sendable, Equatable {
    case invalid(String)
    case missingServer(String)

    public var errorDescription: String? {
        switch self {
        case .invalid(let text): text
        case .missingServer(let text): text
        }
    }
}

public func isLoopbackRedirectUri(_ value: String) -> Bool {
    guard let url = URLComponents(string: value), url.scheme == "http",
          let host = url.host?.lowercased(),
          ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host),
          url.query == nil, url.fragment == nil else { return false }
    return true
}

/// The first exact override wins. Pattern overrides follow their order in `mcp.json`.
public func getMcpToolExposure(_ config: McpServerConfig, toolName: String) -> McpExposure {
    guard let overrides = config.toolExposure else { return config.effectiveExposure }
    if let exact = overrides[toolName] { return exact }
    let ordered = config.toolExposureOrder + overrides.keys.filter { !config.toolExposureOrder.contains($0) }.sorted()
    for pattern in ordered where pattern.contains("*") {
        let source = pattern.split(separator: "*", omittingEmptySubsequences: false)
            .map { NSRegularExpression.escapedPattern(for: String($0)) }.joined(separator: ".*")
        if toolName.range(of: "^\(source)$", options: .regularExpression) != nil {
            return overrides[pattern] ?? config.effectiveExposure
        }
    }
    return config.effectiveExposure
}

private let mcpExposureDescription = McpExposure.allCases.map { "\"\($0.rawValue)\"" }.joined(separator: ", ")

private func mcpIsBool(_ value: Any) -> Bool {
    guard let number = value as? NSNumber else { return false }
    return CFGetTypeID(number) == CFBooleanGetTypeID()
}

private func mcpIsNumber(_ value: Any) -> Bool {
    guard let number = value as? NSNumber else { return false }
    return CFGetTypeID(number) != CFBooleanGetTypeID()
}

private func mcpStringMap(_ value: Any) -> Bool {
    guard let map = value as? [String: Any] else { return false }
    return map.values.allSatisfy { $0 is String }
}

/// Returns the upstream validation message, or `nil` for a valid server.
public func validateMcpServerConfig(name: String, config: McpServerConfig) -> String? {
    guard let data = try? JSONEncoder().encode(config),
          let value = try? JSONSerialization.jsonObject(with: data) else {
        return "server \"\(name)\" must be an object"
    }
    return validateMcpServerConfig(name: name, value: value)
}

/// Validate raw JSON before decoding so wrong JSON types are reported accurately.
public func validateMcpServerConfig(name: String, value: Any) -> String? {
    let validName = name.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil
    guard validName else { return "invalid server name \"\(name)\" (use letters, digits, \"_\" and \"-\")" }
    guard let object = value as? [String: Any] else { return "server \"\(name)\" must be an object" }
    let prefix = "server \"\(name)\": "
    if let exposure = object["exposure"] {
        guard let raw = exposure as? String, McpExposure(rawValue: raw) != nil else {
            return prefix + "exposure must be one of \(mcpExposureDescription)"
        }
    }
    if let overrides = object["toolExposure"] {
        guard let map = overrides as? [String: Any] else { return prefix + "toolExposure must map tool names to exposures" }
        for (tool, value) in map {
            guard let raw = value as? String, McpExposure(rawValue: raw) != nil else {
                return prefix + "toolExposure \"\(tool)\" must be one of \(mcpExposureDescription)"
            }
        }
    }
    if let enabled = object["enabled"], !mcpIsBool(enabled) { return prefix + "enabled must be a boolean" }
    if let timeout = object["timeout"], (!mcpIsNumber(timeout) || (timeout as? NSNumber)?.doubleValue ?? 0 <= 0) {
        return prefix + "timeout must be a positive number of seconds"
    }
    let type = object["type"] as? String
    if type == "sse" { return prefix + "legacy SSE transport is not supported; use the streamable HTTP URL" }
    if let url = object["url"] as? String, type == nil || type == "http" || type == "streamable-http" {
        guard let parsed = URL(string: url), ["http", "https"].contains(parsed.scheme?.lowercased() ?? ""), parsed.host != nil else {
            return prefix + "url must be an http or https URL"
        }
        if let headers = object["headers"], !mcpStringMap(headers) { return prefix + "headers must map names to strings" }
        if let oauth = object["oauth"] {
            guard let oauth = oauth as? [String: Any] else { return prefix + "oauth must be an object" }
            for key in ["clientId", "clientSecret", "scope"] {
                if let value = oauth[key], !(value is String) { return prefix + "oauth.\(key) must be a string" }
            }
            if let port = oauth["callbackPort"] {
                guard mcpIsNumber(port), let number = port as? NSNumber,
                      number.doubleValue.rounded() == number.doubleValue, (1...65535).contains(number.intValue) else {
                    return prefix + "oauth.callbackPort must be a port number"
                }
            }
            if let redirect = oauth["callbackUrl"] {
                guard let redirect = redirect as? String, isLoopbackRedirectUri(redirect) else {
                    return prefix + "oauth.callbackUrl must be an http URI on localhost, 127.0.0.1, or [::1] without query or fragment"
                }
                let uriPort = URLComponents(string: redirect)?.port
                if let uriPort, let configured = (oauth["callbackPort"] as? NSNumber)?.intValue, uriPort != configured {
                    return prefix + "oauth.callbackUrl and oauth.callbackPort name different ports"
                }
            }
        }
        return nil
    }
    if object["command"] is String, type == nil || type == "stdio" {
        if let args = object["args"], !(args is [String]) { return prefix + "args must be an array of strings" }
        if let env = object["env"], !mcpStringMap(env) { return prefix + "env must map names to strings" }
        if let cwd = object["cwd"], !(cwd is String) { return prefix + "cwd must be a string" }
        #if os(iOS)
        return prefix + "stdio transport is unavailable on iOS"
        #else
        return nil
        #endif
    }
    return prefix + "needs either \"command\" (stdio) or \"url\" (streamable HTTP)"
}

public func loadMcpConfig(agentDir: URL, cwd: URL, projectTrusted: Bool) -> LoadedMcpConfig {
    var result = LoadedMcpConfig()
    let global = agentDir.appendingPathComponent("mcp.json")
    readMcpConfigFile(global, scope: .global, into: &result)
    if projectTrusted {
        readMcpConfigFile(cwd.appendingPathComponent(".pi/mcp.json"), scope: .project, into: &result)
    }
    return result
}

private func readMcpConfigFile(_ path: URL, scope: McpServerEntry.Scope, into result: inout LoadedMcpConfig) {
    guard FileManager.default.fileExists(atPath: path.path) else { return }
    let root: [String: Any]
    let text: String
    do {
        text = try String(contentsOf: path, encoding: .utf8)
        guard let object = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              object["mcpServers"] == nil || object["mcpServers"] is [String: Any] else {
            result.errors.append("\(path.path): expected an object with an \"mcpServers\" object")
            return
        }
        root = object
    } catch {
        result.errors.append("\(path.path): \(error.localizedDescription)")
        return
    }
    if let auto = root["autoEnableCodemode"] {
        if mcpIsBool(auto) { result.autoEnableCodemode = (auto as? NSNumber)?.boolValue }
        else { result.errors.append("\(path.path): autoEnableCodemode must be a boolean") }
    }
    let servers = (root["mcpServers"] as? [String: Any]) ?? [:]
    for name in servers.keys.sorted() {
        guard let value = servers[name] else { continue }
        if let error = validateMcpServerConfig(name: name, value: value) {
            result.errors.append("\(path.path): \(error)")
            continue
        }
        do {
            let data = try JSONSerialization.data(withJSONObject: value)
            var config = try JSONDecoder().decode(McpServerConfig.self, from: data)
            config.toolExposureOrder = mcpToolExposureOrder(text: text, serverName: name)
            let entry = McpServerEntry(name: name, config: config, source: path.path, scope: scope)
            if let index = result.servers.firstIndex(where: { $0.name == name }) { result.servers[index] = entry }
            else { result.servers.append(entry) }
        } catch {
            result.errors.append("\(path.path): server \"\(name)\": \(error.localizedDescription)")
        }
    }
}

// Read object-key order from the original JSON text. JSONDecoder does not preserve it.
private func mcpToolExposureOrder(text: String, serverName: String) -> [String] {
    guard let allServers = mcpObjectBody(text, key: "mcpServers"),
          let server = mcpObjectBody(String(allServers), key: serverName),
          let exposure = mcpObjectBody(String(server), key: "toolExposure") else { return [] }
    let expression = try? NSRegularExpression(pattern: "\"((?:\\\\.|[^\"\\\\])*)\"\\s*:")
    let source = String(exposure)
    let range = NSRange(source.startIndex..<source.endIndex, in: source)
    return expression?.matches(in: source, range: range).compactMap { match in
        guard let keyRange = Range(match.range(at: 1), in: source) else { return nil }
        let encoded = "\"\(source[keyRange])\""
        return (try? JSONSerialization.jsonObject(with: Data(encoded.utf8), options: .fragmentsAllowed)) as? String
    } ?? []
}

private func mcpObjectBody(_ text: String, key: String) -> Substring? {
    guard let range = mcpObjectRange(text, key: key) else { return nil }
    return text[text.index(after: range.lowerBound)..<text.index(before: range.upperBound)]
}

private func mcpObjectRange(_ text: String, key: String,
                            within searchRange: Range<String.Index>? = nil) -> Range<String.Index>? {
    let pattern = "\"\(NSRegularExpression.escapedPattern(for: key))\"\\s*:\\s*\\{"
    guard let opening = text.range(of: pattern, options: .regularExpression,
                                   range: searchRange ?? text.startIndex..<text.endIndex) else { return nil }
    let bodyStart = text.index(before: opening.upperBound)
    var depth = 1
    var quoted = false
    var escaped = false
    var cursor = opening.upperBound
    while cursor < text.endIndex {
        let character = text[cursor]
        if quoted {
            if escaped { escaped = false }
            else if character == "\\" { escaped = true }
            else if character == "\"" { quoted = false }
        } else if character == "\"" {
            quoted = true
        } else if character == "{" {
            depth += 1
        } else if character == "}" {
            depth -= 1
            if depth == 0 { return bodyStart..<text.index(after: cursor) }
        }
        cursor = text.index(after: cursor)
    }
    return nil
}

private func mcpRestoreToolExposureOrder(_ output: String, original: String, indent: Int) -> String {
    guard !original.isEmpty else { return output }
    var result = output
    guard let servers = (try? JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])?["mcpServers"] as? [String: [String: Any]] else { return output }
    for name in servers.keys.sorted() {
        let order = mcpToolExposureOrder(text: original, serverName: name)
        guard !order.isEmpty, let overrides = servers[name]?["toolExposure"] as? [String: String],
              let allServersRange = mcpObjectRange(result, key: "mcpServers"),
              let serverRange = mcpObjectRange(result, key: name, within: allServersRange),
              let exposureRange = mcpObjectRange(result, key: "toolExposure", within: serverRange) else { continue }
        let keys = order.filter { overrides[$0] != nil } + overrides.keys.filter { !order.contains($0) }.sorted()
        let closing = result.index(before: exposureRange.upperBound)
        let prefix = result[..<closing]
        let closingIndent = String(prefix).components(separatedBy: "\n").last ?? ""
        let keyIndent = closingIndent + String(repeating: " ", count: indent)
        let lines = keys.compactMap { key -> String? in
            guard let exposure = overrides[key],
                  let keyData = try? JSONEncoder().encode(key),
                  let valueData = try? JSONEncoder().encode(exposure) else { return nil }
            return keyIndent + String(decoding: keyData, as: UTF8.self) + " : " + String(decoding: valueData, as: UTF8.self)
        }
        result.replaceSubrange(exposureRange, with: "{\n" + lines.joined(separator: ",\n") + "\n" + closingIndent + "}")
    }
    return result
}

public struct McpServerConfigPatch: Sendable {
    public var enabled: Bool?
    public var exposure: McpExposure?
    public init(enabled: Bool? = nil, exposure: McpExposure? = nil) {
        self.enabled = enabled
        self.exposure = exposure
    }
}

public func updateMcpServerConfig(path: URL, name: String, patch: McpServerConfigPatch) throws {
    try editMcpServers(path: path) { servers, _ in
        guard var server = servers[name] as? [String: Any] else { throw McpConfigError.missingServer("\(path.path) does not define MCP server \"\(name)\"") }
        if let enabled = patch.enabled {
            if enabled { server.removeValue(forKey: "enabled") } else { server["enabled"] = false }
        }
        if let exposure = patch.exposure {
            if exposure == .codemode { server.removeValue(forKey: "exposure") }
            else { server["exposure"] = exposure.rawValue }
        }
        servers[name] = server
        return true
    }
}

@discardableResult
public func addMcpServerConfig(path: URL, name: String, config: McpServerConfig) throws -> Bool {
    if let error = validateMcpServerConfig(name: name, config: config) { throw McpConfigError.invalid(error) }
    let data = try JSONEncoder().encode(config)
    let value = try JSONSerialization.jsonObject(with: data)
    var replaced = false
    try editMcpServers(path: path) { servers, _ in
        replaced = servers[name] != nil
        servers[name] = value
        return true
    }
    return replaced
}

@discardableResult
public func removeMcpServerConfig(path: URL, name: String) throws -> Bool {
    guard FileManager.default.fileExists(atPath: path.path) else { return false }
    var removed = false
    try editMcpServers(path: path) { servers, _ in
        removed = servers.removeValue(forKey: name) != nil
        return removed
    }
    return removed
}

private func editMcpServers(path: URL, edit: (inout [String: Any], inout [String: Any]) throws -> Bool) throws {
    let text = FileManager.default.fileExists(atPath: path.path) ? try String(contentsOf: path, encoding: .utf8) : nil
    let root: [String: Any]
    if let text {
        guard let value = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              value["mcpServers"] == nil || value["mcpServers"] is [String: Any] else {
            throw McpConfigError.invalid("\(path.path): expected an object with an \"mcpServers\" object")
        }
        root = value
    } else { root = [:] }
    var changedRoot = root
    var servers = (root["mcpServers"] as? [String: Any]) ?? [:]
    guard try edit(&servers, &changedRoot) else { return }
    if changedRoot["mcpServers"] != nil || !servers.isEmpty { changedRoot["mcpServers"] = servers }
    let indent: Int
    if let text, let match = text.range(of: "(?m)^([ \\t]+)\\S", options: .regularExpression) {
        indent = text[match].prefix(while: { $0 == " " || $0 == "\t" }).count
    } else { indent = 2 }
    let encoded = try JSONSerialization.data(withJSONObject: changedRoot, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    var output = String(decoding: encoded, as: UTF8.self)
    if indent != 2 {
        output = output.components(separatedBy: "\n").map { line in
            let count = line.prefix(while: { $0 == " " }).count
            return String(repeating: " ", count: count / 2 * indent) + String(line.dropFirst(count))
        }.joined(separator: "\n")
    }
    output = mcpRestoreToolExposureOrder(output, original: text ?? "", indent: indent)
    try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
    try (output + "\n").write(to: path, atomically: true, encoding: .utf8)
}

/// Data for `pi mcp list` and the `/mcp` manager.
public struct McpServerListReport: Codable, Sendable, Equatable {
    public var name: String
    public var source: String
    public var scope: McpServerEntry.Scope
    public var enabled: Bool
    public var exposure: McpExposure
    public var transport: String
    public var state: String
    public var tools: [String]
    public var toolExposure: [String: McpExposure]?
    public var resources: Int?
    public var resourceTemplates: Int?
    public var error: String?

    public init(entry: McpServerEntry) {
        name = entry.name
        source = entry.source
        scope = entry.scope
        enabled = entry.config.isEnabled
        exposure = entry.config.effectiveExposure
        transport = entry.config.url ?? ([entry.config.command].compactMap { $0 } + (entry.config.args ?? [])).joined(separator: " ")
        state = "disabled"
        tools = []
    }
}

public func mcpServerListReport(_ loaded: LoadedMcpConfig) -> [McpServerListReport] {
    loaded.servers.map(McpServerListReport.init(entry:))
}

/// Live report for `pi mcp list`. The CLI can render `servers`, `errors`, and `note` as JSON.
public struct McpListReport: Sendable {
    public var servers: [McpServerListReport]
    public var errors: [String]
    public var note: String?
    public var failed: Bool

    public func jsonData() throws -> Data {
        struct Payload: Encodable {
            var servers: [McpServerListReport]
            var errors: [String]
            var note: String?
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(Payload(servers: servers, errors: errors, note: note))
    }
}

public func inspectMcpServers(
    _ loaded: LoadedMcpConfig, cwd: URL, credentials: McpOAuthCredentialStore,
    note: String? = nil, createTransport: @escaping McpTransportFactory = createDefaultMcpTransport
) async -> McpListReport {
    let reports = await withTaskGroup(of: (Int, McpServerListReport).self) { group in
        for (index, entry) in loaded.servers.enumerated() {
            group.addTask {
                let report = await inspectMcpServer(entry, cwd: cwd, credentials: credentials,
                    createTransport: createTransport)
                return (index, report)
            }
        }
        var indexed: [(Int, McpServerListReport)] = []
        for await item in group { indexed.append(item) }
        return indexed.sorted { $0.0 < $1.0 }.map(\.1)
    }
    return McpListReport(servers: reports, errors: loaded.errors, note: note,
        failed: !loaded.errors.isEmpty || reports.contains { $0.enabled && $0.state != "connected" })
}

private func inspectMcpServer(
    _ entry: McpServerEntry, cwd: URL, credentials: McpOAuthCredentialStore,
    createTransport: @escaping McpTransportFactory
) async -> McpServerListReport {
    var report = McpServerListReport(entry: entry)
    guard report.enabled else { return report }
    let connection = McpServerConnection(entry: entry, cwd: cwd,
        createTransport: createTransport, credentials: credentials)
    try? await connection.connect()
    report.state = await connection.state.rawValue
    let tools = await connection.tools
    report.tools = tools.map(\.name)
    var overrides: [String: McpExposure] = [:]
    for tool in tools {
        let exposure = getMcpToolExposure(entry.config, toolName: tool.name)
        if exposure != report.exposure { overrides[tool.name] = exposure }
    }
    if !overrides.isEmpty { report.toolExposure = overrides }
    if await connection.hasResources {
        report.resources = await connection.resources.count
        report.resourceTemplates = await connection.resourceTemplates.count
    }
    if report.state != McpConnectionState.connected.rawValue { report.error = await connection.error }
    await connection.close()
    return report
}
