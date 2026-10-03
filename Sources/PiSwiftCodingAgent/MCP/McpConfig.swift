import Foundation
import CoreFoundation
import PiSwiftAI

/// How MCP tools are made available to the model.
public enum McpExposure: String, Codable, Sendable, CaseIterable {
    case codemode
    case deferred
    case direct
    case hidden

    /// Compatibility spelling. Config files also accept this alias.
    public static var codemodeDeferred: Self { .codemode }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        guard let exposure = Self(rawValue: value == "codemode-deferred" ? "codemode" : value) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid MCP exposure")
        }
        self = exposure
    }
}

/// Namespace shared by the server's tools and credential key.
public func mcpNamespace(_ server: String) -> String {
    "mcp__" + server.replacingOccurrences(of: "-", with: "_")
}

public struct McpServerAuthConfig: Codable, Sendable, Equatable {
    public var provider: String
    public init(provider: String) { self.provider = provider }
}

public enum McpOAuthClientRegistration: String, Codable, Sendable {
    case dcr, cimd
}

public struct McpOAuthConfig: Codable, Sendable, Equatable {
    public var clientId: String?
    public var clientSecret: String?
    public var callbackPort: Int?
    public var callbackUrl: String?
    public var scope: String?
    public var clientName: String?
    public var clientRegistration: McpOAuthClientRegistration?
    public var authServerMetadataUrl: String?

    public init(clientId: String? = nil, clientSecret: String? = nil,
                callbackPort: Int? = nil, callbackUrl: String? = nil, scope: String? = nil,
                clientName: String? = nil, clientRegistration: McpOAuthClientRegistration? = nil, authServerMetadataUrl: String? = nil) {
        self.clientId = clientId
        self.clientSecret = clientSecret
        self.callbackPort = callbackPort
        self.callbackUrl = callbackUrl
        self.scope = scope
        self.clientName = clientName
        self.clientRegistration = clientRegistration
        self.authServerMetadataUrl = authServerMetadataUrl
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
    public var auth: McpServerAuthConfig?
    public var description: String?
    public var exposure: McpExposure?
    public var toolExposure: [String: McpExposure]?
    public var enabled: Bool?
    public var timeout: Double?
    /// Pattern order from the JSON object. It is omitted from JSON output.
    public var toolExposureOrder: [String] = []

    private enum CodingKeys: String, CodingKey {
        case type, command, args, env, cwd, url, headers, oauth, auth, description, exposure, toolExposure, enabled, timeout
    }

    public init(type: String? = nil, command: String? = nil, args: [String]? = nil,
                env: [String: String]? = nil, cwd: String? = nil, url: String? = nil,
                headers: [String: String]? = nil, oauth: McpOAuthConfig? = nil,
                auth: McpServerAuthConfig? = nil, description: String? = nil,
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
        self.auth = auth
        self.description = description
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
    public var override: String?

    public init(name: String, config: McpServerConfig, source: String, scope: Scope, override: String? = nil) {
        self.name = name
        self.config = config
        self.source = source
        self.scope = scope
        self.override = override
    }
}

public struct LoadedMcpConfig: Sendable {
    public var servers: [McpServerEntry]
    public var autoEnableCodemode: Bool?
    public var errors: [String]
    public var projectConfig: String?

    public init(servers: [McpServerEntry] = [], autoEnableCodemode: Bool? = nil, errors: [String] = [], projectConfig: String? = nil) {
        self.servers = servers
        self.autoEnableCodemode = autoEnableCodemode
        self.errors = errors
        self.projectConfig = projectConfig
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
        guard let raw = exposure as? String, (raw == "codemode-deferred" || McpExposure(rawValue: raw) != nil) else {
            return prefix + "exposure must be one of \(mcpExposureDescription)"
        }
    }
    if let overrides = object["toolExposure"] {
        guard let map = overrides as? [String: Any] else { return prefix + "toolExposure must map tool names to exposures" }
        for (tool, value) in map {
            guard let raw = value as? String, (raw == "codemode-deferred" || McpExposure(rawValue: raw) != nil) else {
                return prefix + "toolExposure \"\(tool)\" must be one of \(mcpExposureDescription)"
            }
        }
    }
    if let enabled = object["enabled"], !mcpIsBool(enabled) { return prefix + "enabled must be a boolean" }
    if let description = object["description"], !(description is String) { return prefix + "description must be a string" }
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
            for key in ["clientId", "clientSecret"] {
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
            if let scope = oauth["scope"], !(scope is String) { return prefix + "oauth.scope must be a string" }
            if let value = oauth["clientName"],
               !(value is String) || (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true {
                return prefix + "oauth.clientName must be a non-empty string"
            }
            if let registration = oauth["clientRegistration"], (registration as? String) != "dcr" {
                guard (registration as? String) == "cimd" else {
                    return prefix + "oauth.clientRegistration must be \"dcr\" or \"cimd\""
                }
                if oauth["clientId"] != nil || oauth["clientName"] != nil {
                    return prefix + "oauth.clientRegistration \"cimd\" cannot be combined with oauth.clientId or oauth.clientName"
                }
                if let callback = (oauth["callbackUrl"] as? String).flatMap(URLComponents.init(string:)),
                   ["::1", "[::1]"].contains(callback.host ?? "") || callback.path != "/callback" {
                    return prefix + "oauth.clientRegistration \"cimd\" requires oauth.callbackUrl on localhost or 127.0.0.1 with path /callback"
                }
            }
            if let value = oauth["authServerMetadataUrl"] {
                guard let text = value as? String, mcpIsSecureOrLoopbackURL(text) else {
                    return prefix + "oauth.authServerMetadataUrl must be an https URL, or http on localhost, 127.0.0.1, or [::1]"
                }
            }
        }
        if let value = object["auth"] {
            guard let auth = value as? [String: Any], let provider = auth["provider"] as? String, !provider.isEmpty else {
                return prefix + "auth.provider must be a provider name"
            }
            guard mcpIsSecureOrLoopbackURL(url) else {
                return prefix + "auth requires an https URL, or http on localhost, 127.0.0.1, or [::1]"
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
    return "server \"\(name)\" needs either \"command\" (stdio) or \"url\" (streamable HTTP)"
}

private func mcpIsSecureOrLoopbackURL(_ text: String) -> Bool {
    guard let url = URLComponents(string: text), let host = url.host?.lowercased(), !host.isEmpty else { return false }
    return url.scheme?.lowercased() == "https" ||
        (url.scheme?.lowercased() == "http" && ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host))
}

public func loadMcpConfig(agentDir: URL, cwd: URL, projectTrusted: Bool) -> LoadedMcpConfig {
    var result = LoadedMcpConfig()
    let global = agentDir.appendingPathComponent("mcp.json")
    readMcpConfigFile(global, scope: .global, into: &result)
    if projectTrusted {
        let project = cwd.appendingPathComponent(".pi/mcp.json")
        result.projectConfig = project.path
        readMcpConfigFile(project, scope: .project, into: &result)
    }
    return result
}

private func mcpParseJSON(_ text: String) throws -> OrderedJSON {
    do { return try OrderedJSON.parse(text, allowDuplicateKeys: true) }
    catch {
        // Keep Foundation's existing malformed-JSON diagnostic for host callers.
        _ = try JSONSerialization.jsonObject(with: Data(text.utf8), options: .fragmentsAllowed)
        throw error
    }
}

private func readMcpConfigFile(_ path: URL, scope: McpServerEntry.Scope, into result: inout LoadedMcpConfig) {
    guard FileManager.default.fileExists(atPath: path.path) else { return }
    let root: OrderedJSON
    do {
        root = try mcpParseJSON(String(contentsOf: path, encoding: .utf8))
        guard root.objectEntries != nil,
              root["mcpServers"] == nil || root["mcpServers"]?.objectEntries != nil else {
            result.errors.append("\(path.path): expected an object with an \"mcpServers\" object")
            return
        }
    } catch {
        result.errors.append("\(path.path): \(error.localizedDescription)")
        return
    }
    if let auto = root["autoEnableCodemode"] {
        if case .bool(let enabled) = auto { result.autoEnableCodemode = enabled }
        else { result.errors.append("\(path.path): autoEnableCodemode must be a boolean") }
    }
    // A project replacement keeps the global Map position, as in upstream config.ts.
    for (name, value) in mcpObjectEntries(root["mcpServers"]) {
        do {
            let data = Data(value.serialized(escapeSlashes: false).utf8)
            let raw = try JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed)
            if scope == .project, let object = raw as? [String: Any],
               object["command"] == nil, object["url"] == nil, object["type"] == nil {
                guard let index = result.servers.firstIndex(where: { $0.name == name }) else {
                    result.errors.append("\(path.path): server \"\(name)\" needs \"command\" or \"url\", or a global server to override")
                    continue
                }
                guard object.keys.allSatisfy({ ["enabled", "exposure", "toolExposure"].contains($0) }) else {
                    result.errors.append("\(path.path): server \"\(name)\": an override can only set enabled, exposure, toolExposure")
                    continue
                }
                let base = result.servers[index].config
                guard var merged = try JSONSerialization.jsonObject(with: JSONEncoder().encode(base)) as? [String: Any] else {
                    throw McpConfigError.invalid("server \"\(name)\": expected a config object")
                }
                for (key, value) in object { merged[key] = value }
                if let error = validateMcpServerConfig(name: name, value: merged) {
                    result.errors.append("\(path.path): \(error)")
                    continue
                }
                var config = try JSONDecoder().decode(McpServerConfig.self, from: JSONSerialization.data(withJSONObject: merged))
                config.toolExposureOrder = object["toolExposure"] != nil
                    ? mcpObjectEntries(value["toolExposure"]).map { $0.0 } : base.toolExposureOrder
                result.servers[index].config = config
                result.servers[index].override = path.path
                continue
            }
            if let error = validateMcpServerConfig(name: name, value: raw) {
                result.errors.append("\(path.path): \(error)")
                continue
            }
            if let clash = result.servers.first(where: { $0.name != name && mcpNamespace($0.name) == mcpNamespace(name) }) {
                result.errors.append("\(path.path): server \"\(name)\" conflicts with \"\(clash.name)\"")
                continue
            }
            if scope == .project, let raw = raw as? [String: Any], raw["url"] != nil, raw["auth"] != nil {
                result.errors.append("\(path.path): server \"\(name)\": auth is only allowed in the global mcp.json")
                continue
            }
            var config = try JSONDecoder().decode(McpServerConfig.self, from: data)
            config.toolExposureOrder = mcpObjectEntries(value["toolExposure"]).map { $0.0 }
            let entry = McpServerEntry(name: name, config: config, source: path.path, scope: scope)
            if let index = result.servers.firstIndex(where: { $0.name == name }) { result.servers[index] = entry }
            else { result.servers.append(entry) }
        } catch {
            result.errors.append("\(path.path): server \"\(name)\": \(error.localizedDescription)")
        }
    }
}

// Object.entries and JSON.stringify put array-index keys first in numeric order.
// All other keys keep insertion order.
private func mcpObjectEntries(_ object: OrderedJSON?) -> [(String, OrderedJSON)] {
    let entries = object?.objectEntries ?? []
    func arrayIndex(_ name: String) -> UInt32? {
        guard let index = UInt32(name), index != UInt32.max, String(index) == name else { return nil }
        return index
    }
    let indices = entries.compactMap { entry in arrayIndex(entry.0).map { ($0, entry) } }
        .sorted { $0.0 < $1.0 }.map { $0.1 }
    return indices + entries.filter { arrayIndex($0.0) == nil }
}

// JSON.parse reads numbers as Double; JSON.stringify uses decimal notation from
// 1e-6 through values below 1e21, and removes a negative zero and trailing .0.
private func mcpJSONNumber(_ source: String) -> String {
    guard let number = Double(source), number.isFinite else { return "null" }
    if number == 0 { return "0" }
    let negative = number < 0 ? "-" : ""
    let parts = String(abs(number)).lowercased().split(separator: "e")
    let mantissa = String(parts[0])
    let exponent = parts.count == 2 ? Int(parts[1]) ?? 0 : 0
    let decimal = mantissa.split(separator: ".", omittingEmptySubsequences: false)
    let whole = String(decimal[0])
    var digits = whole + (decimal.count == 2 ? String(decimal[1]) : "")
    let decimalPosition = whole.count + exponent
    while digits.count > 1 && digits.last == "0" { digits.removeLast() }
    if abs(number) >= 1e-6 && abs(number) < 1e21 {
        if decimalPosition <= 0 {
            return negative + "0." + String(repeating: "0", count: -decimalPosition) + digits
        }
        if decimalPosition >= digits.count {
            return negative + digits + String(repeating: "0", count: decimalPosition - digits.count)
        }
        let position = digits.index(digits.startIndex, offsetBy: decimalPosition)
        return negative + digits[..<position] + "." + digits[position...]
    }
    // Swift already uses scientific notation at these magnitudes.
    let fraction = digits.count > 1 ? "." + digits.dropFirst() : ""
    return negative + String(digits.prefix(1)) + fraction + "e" + (exponent >= 0 ? "+" : "") + String(exponent)
}

/// Set an object member without changing the position of an existing member.
private func mcpSetMember(_ name: String, _ value: OrderedJSON?, in object: inout OrderedJSON) {
    guard case .object(var entries) = object else { return }
    if let index = entries.firstIndex(where: { $0.0 == name }) {
        if let value { entries[index].1 = value }
        else { entries.remove(at: index) }
    } else if let value { entries.append((name, value)) }
    object = .object(entries)
}

/// Use the spacing and slash rules of upstream JSON.stringify(value, null, indent).
private func mcpJSONText(_ value: OrderedJSON, indent: String = "  ", depth: Int = 0) -> String {
    let prefix = String(repeating: indent, count: depth)
    let childPrefix = prefix + indent
    switch value {
    case .object(let entries) where !entries.isEmpty:
        let lines = mcpObjectEntries(value).map { name, value in
            childPrefix + OrderedJSON.string(name).serialized(escapeSlashes: false) + ": " +
                mcpJSONText(value, indent: indent, depth: depth + 1)
        }
        return "{\n" + lines.joined(separator: ",\n") + "\n" + prefix + "}"
    case .array(let values) where !values.isEmpty:
        let lines = values.map { childPrefix + mcpJSONText($0, indent: indent, depth: depth + 1) }
        return "[\n" + lines.joined(separator: ",\n") + "\n" + prefix + "]"
    case .number(let source):
        return mcpJSONNumber(source)
    default:
        return value.serialized(escapeSlashes: false)
    }
}

/// Typed new entries use the transport fields first, as in upstream's add command.
private func mcpConfigJSON(_ config: McpServerConfig) throws -> OrderedJSON {
    let parsed = try OrderedJSON.parse(String(decoding: JSONEncoder().encode(config), as: UTF8.self))
    let keys = ["type", "command", "args", "env", "cwd", "url", "headers", "oauth", "auth", "description",
                "exposure", "toolExposure", "enabled", "timeout"]
    var entries: [(String, OrderedJSON)] = []
    for key in keys {
        guard var value = parsed[key] else { continue }
        if key == "toolExposure", let overrides = value.objectEntries {
            let order = config.toolExposureOrder + overrides.map { $0.0 }.filter { !config.toolExposureOrder.contains($0) }.sorted()
            value = .object(order.compactMap { name in value[name].map { (name, $0) } })
        } else if key == "oauth" {
            value = .object(["clientId", "clientSecret", "callbackPort", "callbackUrl", "scope", "clientName", "clientRegistration", "authServerMetadataUrl"]
                .compactMap { name in value[name].map { (name, $0) } })
        } else if let members = value.objectEntries {
            // Swift maps have no insertion order. Existing file objects retain their source order.
            value = .object(members.sorted { $0.0 < $1.0 })
        }
        entries.append((key, value))
    }
    return .object(entries)
}

public struct McpServerConfigPatch: Sendable {
    public var enabled: Bool?
    public var exposure: McpExposure?
    public init(enabled: Bool? = nil, exposure: McpExposure? = nil) {
        self.enabled = enabled
        self.exposure = exposure
    }
}

public func updateMcpServerConfig(path: URL, name: String, patch: McpServerConfigPatch, override: Bool = false) throws {
    try editMcpServers(path: path) { servers in
        var server = servers[name] ?? (override ? .object([]) : .null)
        guard server.objectEntries != nil else {
            throw McpConfigError.missingServer("\(path.path) does not define MCP server \"\(name)\"")
        }
        let keepDefaults = server["command"] == nil && server["url"] == nil && server["type"] == nil
        if let enabled = patch.enabled { mcpSetMember("enabled", enabled && !keepDefaults ? nil : .bool(enabled), in: &server) }
        if let exposure = patch.exposure {
            mcpSetMember("exposure", exposure == .codemode && !keepDefaults ? nil : .string(exposure.rawValue), in: &server)
        }
        mcpSetMember(name, server, in: &servers)
        return true
    }
}

@discardableResult
public func addMcpServerConfig(path: URL, name: String, config: McpServerConfig) throws -> Bool {
    if let error = validateMcpServerConfig(name: name, config: config) { throw McpConfigError.invalid(error) }
    let value = try mcpConfigJSON(config)
    var replaced = false
    try editMcpServers(path: path) { servers in
        replaced = servers[name] != nil
        mcpSetMember(name, value, in: &servers)
        return true
    }
    return replaced
}

@discardableResult
public func removeMcpServerConfig(path: URL, name: String) throws -> Bool {
    guard FileManager.default.fileExists(atPath: path.path) else { return false }
    var removed = false
    try editMcpServers(path: path) { servers in
        removed = servers[name] != nil
        mcpSetMember(name, nil, in: &servers)
        return removed
    }
    return removed
}

private func editMcpServers(path: URL, edit: (inout OrderedJSON) throws -> Bool) throws {
    let text = FileManager.default.fileExists(atPath: path.path) ? try String(contentsOf: path, encoding: .utf8) : nil
    var root = try text.map(mcpParseJSON) ?? .object([])
    guard root.objectEntries != nil,
          root["mcpServers"] == nil || root["mcpServers"]?.objectEntries != nil else {
        throw McpConfigError.invalid("\(path.path): expected an object with an \"mcpServers\" object")
    }
    var servers = root["mcpServers"] ?? .object([])
    guard try edit(&servers) else { return }
    mcpSetMember("mcpServers", servers, in: &root)
    let indent: String
    if let text, let match = text.range(of: "(?m)^([ \\t]+)\\S", options: .regularExpression) {
        // JSON.stringify uses at most ten characters of a string indentation argument.
        indent = String(text[match].prefix(while: { $0 == " " || $0 == "\t" }).prefix(10))
    } else { indent = "  " }
    let output = mcpJSONText(root, indent: indent) + "\n"
    try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
    try output.write(to: path, atomically: true, encoding: .utf8)
}

/// Data for `pi mcp list` and the `/mcp` manager.
public struct McpServerListReport: Codable, Sendable, Equatable {
    public var name: String
    public var source: String
    public var override: String?
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
        override = entry.override
        scope = entry.scope
        enabled = entry.config.isEnabled
        exposure = entry.config.effectiveExposure
        transport = entry.config.url ?? ([entry.config.command].compactMap { $0 } + (entry.config.args ?? [])).joined(separator: " ")
        state = "disabled"
        tools = []
    }
}

private extension McpServerListReport {
    var orderedJSON: OrderedJSON {
        var entries: [(String, OrderedJSON)] = [
            ("name", .string(name)), ("scope", .string(scope.rawValue)), ("source", .string(source)),
            ("enabled", .bool(enabled)), ("exposure", .string(exposure.rawValue)),
            ("transport", .string(transport)), ("state", .string(state)),
            ("tools", .array(tools.map(OrderedJSON.string)))
        ]
        if let override { entries.insert(("override", .string(override)), at: 3) }
        if let overrides = toolExposure {
            let names = tools.filter { overrides[$0] != nil } + overrides.keys.filter { !tools.contains($0) }.sorted()
            entries.append(("toolExposure", .object(names.compactMap { name in
                overrides[name].map { (name, .string($0.rawValue)) }
            })))
        }
        if let resources { entries.append(("resources", .number(String(resources)))) }
        if let resourceTemplates { entries.append(("resourceTemplates", .number(String(resourceTemplates)))) }
        if let error { entries.append(("error", .string(error))) }
        return .object(entries)
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
        var entries: [(String, OrderedJSON)] = [
            ("servers", .array(servers.map { $0.orderedJSON })),
            ("errors", .array(errors.map(OrderedJSON.string)))
        ]
        if let note { entries.append(("note", .string(note))) }
        return Data(mcpJSONText(.object(entries)).utf8)
    }
}

public func inspectMcpServers(
    _ loaded: LoadedMcpConfig, cwd: URL, credentials: McpOAuthCredentialStore,
    note: String? = nil, log: McpServerLog? = nil, clientMetadataDocumentURL: URL? = nil,
    createTransport: @escaping McpTransportFactory = createDefaultMcpTransport
) async -> McpListReport {
    let reports = await withTaskGroup(of: (Int, McpServerListReport).self) { group in
        for (index, entry) in loaded.servers.enumerated() {
            group.addTask {
                let report = await inspectMcpServer(entry, cwd: cwd, credentials: credentials,
                    log: log, clientMetadataDocumentURL: clientMetadataDocumentURL, createTransport: createTransport)
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
    log: McpServerLog?, clientMetadataDocumentURL: URL?,
    createTransport: @escaping McpTransportFactory
) async -> McpServerListReport {
    var report = McpServerListReport(entry: entry)
    guard report.enabled else { return report }
    let connection = McpServerConnection(entry: entry, cwd: cwd,
        createTransport: createTransport, credentials: credentials, log: log,
        clientMetadataDocumentURL: clientMetadataDocumentURL)
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
