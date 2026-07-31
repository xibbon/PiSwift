import Foundation

/// Persistence for adapter-owned tool metadata. It never reads or writes MCP
/// configuration files.
public protocol McpMetadataStore: Sendable {
    func load() async -> MetadataCache?
    func save(_ cache: MetadataCache) async
}

/// A deterministic store for tests and hosts that manage persistence elsewhere.
public actor InMemoryMcpMetadataStore: McpMetadataStore {
    private var cache: MetadataCache?

    public init(cache: MetadataCache? = nil) {
        self.cache = cache
    }

    public func load() -> MetadataCache? { cache }

    public func save(_ cache: MetadataCache) {
        self.cache = cache
    }
}

/// The default metadata store. Its file is in the app cache directory, not in
/// an MCP configuration directory or the user's home configuration.
public actor FileMcpMetadataStore: McpMetadataStore {
    private let url: URL

    public init(url: URL? = nil) {
        if let url {
            self.url = url
        } else if let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first {
            self.url = caches.appendingPathComponent("PiSwift/mcp-metadata.json")
        } else {
            self.url = FileManager.default.temporaryDirectory.appendingPathComponent("PiSwift-mcp-metadata.json")
        }
    }

    public func load() -> MetadataCache? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(MetadataCache.self, from: data)
    }

    public func save(_ cache: MetadataCache) {
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(cache).write(to: url, options: .atomic)
        } catch {
            // Cache persistence must not prevent an MCP call from succeeding.
        }
    }
}
