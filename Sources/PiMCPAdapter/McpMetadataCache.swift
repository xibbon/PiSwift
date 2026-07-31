import Foundation
import CryptoKit
import PiSwiftAI

// MARK: - Cache Types

public struct MetadataCache: Codable, Sendable {
    public var version: Int = 1
    public var servers: [String: ServerCacheEntry]

    public init(version: Int = 1, servers: [String: ServerCacheEntry] = [:]) {
        self.version = version
        self.servers = servers
    }
}

public struct ServerCacheEntry: Codable, Sendable {
    public var configHash: String
    public var tools: [CachedTool]
    public var resources: [CachedResource]
    public var prompts: [CachedPrompt]
    public var cachedAt: Double

    enum CodingKeys: String, CodingKey {
        case configHash, tools, resources, prompts, cachedAt
    }

    public init(
        configHash: String,
        tools: [CachedTool],
        resources: [CachedResource],
        prompts: [CachedPrompt] = [],
        cachedAt: Double
    ) {
        self.configHash = configHash
        self.tools = tools
        self.resources = resources
        self.prompts = prompts
        self.cachedAt = cachedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        configHash = try container.decode(String.self, forKey: .configHash)
        tools = try container.decode([CachedTool].self, forKey: .tools)
        resources = try container.decode([CachedResource].self, forKey: .resources)
        prompts = try container.decodeIfPresent([CachedPrompt].self, forKey: .prompts) ?? []
        cachedAt = try container.decode(Double.self, forKey: .cachedAt)
    }
}

public struct CachedPrompt: Codable, Sendable {
    public var name: String
    public var title: String?
    public var description: String?
    public var arguments: [McpPromptArgument]?

    public init(name: String, title: String? = nil, description: String? = nil, arguments: [McpPromptArgument]? = nil) {
        self.name = name
        self.title = title
        self.description = description
        self.arguments = arguments
    }
}

public struct CachedTool: Codable, Sendable {
    public var name: String
    public var description: String?
    public var inputSchema: AnyCodable?
    public var outputSchema: AnyCodable?

    public init(
        name: String,
        description: String? = nil,
        inputSchema: AnyCodable? = nil,
        outputSchema: AnyCodable? = nil
    ) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
        self.outputSchema = outputSchema
    }
}

public struct CachedResource: Codable, Sendable {
    public var uri: String
    public var name: String
    public var description: String?

    public init(uri: String, name: String, description: String? = nil) {
        self.uri = uri
        self.name = name
        self.description = description
    }
}

// MARK: - Cache File Path

private let cacheFileName = "mcp-cache.json"

func metadataCachePath() -> String {
    let agentDir = (NSHomeDirectory() as NSString).appendingPathComponent(".pi/agent")
    return (agentDir as NSString).appendingPathComponent(cacheFileName)
}

// MARK: - Load / Save

public func loadMetadataCache() -> MetadataCache? {
    let path = metadataCachePath()
    guard let data = FileManager.default.contents(atPath: path) else { return nil }
    do {
        let cache = try JSONDecoder().decode(MetadataCache.self, from: data)
        return cache.version == 1 ? cache : nil
    } catch {
        return nil
    }
}

public func saveMetadataCache(_ cache: MetadataCache) {
    let path = metadataCachePath()
    let dir = (path as NSString).deletingLastPathComponent

    // Ensure directory exists
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

    // Read-merge-write for multi-session safety
    var merged = loadMetadataCache() ?? MetadataCache()
    for (name, entry) in cache.servers {
        merged.servers[name] = entry
    }

    do {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(merged)

        // Atomic write via temp file + rename
        let pid = ProcessInfo.processInfo.processIdentifier
        let tempPath = "\(path).\(pid).tmp"
        try data.write(to: URL(fileURLWithPath: tempPath), options: .atomic)

        // rename (atomic on same filesystem)
        try FileManager.default.moveItem(atPath: tempPath, toPath: path)
    } catch {
        // Try direct write as fallback
        if let data = try? JSONEncoder().encode(merged) {
            try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
        }
    }
}

// MARK: - Config Hashing

public func computeServerHash(_ definition: ServerEntry) -> String {
    // Hash only identity-affecting fields
    var components: [String: Any] = [:]
    if let c = definition.command { components["command"] = c }
    if let s = definition.socket { components["socket"] = s }
    if let a = definition.args { components["args"] = a }
    if let e = definition.env { components["env"] = e }
    if let c = definition.cwd { components["cwd"] = c }
    if let u = definition.url { components["url"] = u }
    if let h = definition.headers { components["headers"] = h }
    if let a = definition.auth { components["auth"] = a }
    if let b = definition.bearerToken { components["bearerToken"] = b }
    if let b = definition.bearerTokenEnv { components["bearerTokenEnv"] = b }
    if let e = definition.exposeResources { components["exposeResources"] = e }
    if let includeTools = definition.includeTools { components["includeTools"] = includeTools }
    if let excludeTools = definition.excludeTools { components["excludeTools"] = excludeTools }

    // Stable JSON with sorted keys
    guard let data = try? JSONSerialization.data(
        withJSONObject: components,
        options: [.sortedKeys, .fragmentsAllowed]
    ) else {
        return ""
    }

    let digest = SHA256.hash(data: data)
    return digest.map { String(format: "%02x", $0) }.joined()
}

// MARK: - Cache Validity

private let maxCacheAgeSeconds: Double = 7 * 24 * 60 * 60 // 7 days

public func isServerCacheValid(_ entry: ServerCacheEntry, _ definition: ServerEntry) -> Bool {
    guard entry.configHash == computeServerHash(definition) else { return false }
    let age = Date().timeIntervalSince1970 * 1000 - entry.cachedAt
    return age < maxCacheAgeSeconds * 1000
}

// MARK: - Metadata Reconstruction

public func reconstructToolMetadata(
    serverName: String,
    entry: ServerCacheEntry,
    prefix: String,
    exposeResources: Bool?,
    definition: ServerEntry? = nil
) -> [ToolMetadata] {
    var metadata: [ToolMetadata] = []
    var seenNames: Set<String> = []

    for tool in entry.tools {
        if let definition,
           !isToolAllowed(tool.name, serverName: serverName, prefix: prefix, definition: definition) {
            continue
        }
        let prefixed = formatToolName(tool.name, serverName: serverName, prefix: prefix)
        guard seenNames.insert(prefixed).inserted else { continue }
        metadata.append(ToolMetadata(
            name: prefixed,
            originalName: tool.name,
            description: tool.description ?? "(no description)",
            inputSchema: tool.inputSchema
        ))
    }

    if exposeResources != false {
        for resource in entry.resources {
            let toolName = "read_\(resourceNameToToolName(resource.name))"
            if let definition,
               !isToolAllowed(toolName, serverName: serverName, prefix: prefix, definition: definition) {
                continue
            }
            let prefixed = formatToolName(toolName, serverName: serverName, prefix: prefix)
            guard seenNames.insert(prefixed).inserted else { continue }
            metadata.append(ToolMetadata(
                name: prefixed,
                originalName: toolName,
                description: resource.description ?? "Read resource: \(resource.uri)",
                resourceUri: resource.uri
            ))
        }
    }

    return metadata
}

public func reconstructPromptMetadata(serverName: String, entry: ServerCacheEntry, prefix: String) -> [PromptMetadata] {
    entry.prompts.map { prompt in
        PromptMetadata(
            serverName: serverName,
            originalName: prompt.name,
            commandName: formatPromptCommandName(prompt.name, serverName: serverName, prefix: prefix),
            title: prompt.title,
            description: prompt.description ?? prompt.title ?? "MCP prompt from \(serverName)",
            arguments: prompt.arguments ?? []
        )
    }
}

// MARK: - Build Cache Entry from Connection

public func buildCacheEntry(from connection: ServerConnection, definition: ServerEntry) -> ServerCacheEntry {
    ServerCacheEntry(
        configHash: computeServerHash(definition),
        tools: connection.tools.map {
            CachedTool(
                name: $0.name,
                description: $0.description,
                inputSchema: $0.inputSchema,
                outputSchema: $0.outputSchema
            )
        },
        resources: connection.resources.map { CachedResource(uri: $0.uri, name: $0.name, description: $0.description) },
        prompts: connection.prompts.map { CachedPrompt(name: $0.name, title: $0.title, description: $0.description, arguments: $0.arguments) },
        cachedAt: Date().timeIntervalSince1970 * 1000
    )
}
